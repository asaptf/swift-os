#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# c6_cell_lifecycle_test.sh - C6d: cell lifecycle (resource cap + enumerate + teardown).
#
# Boots the base image and lets the capConsole boot probe (/bin/cellcapprobe, run
# from kernel/main.swift) exercise the full C6d lifecycle: create a cell with a hard
# resident-page cap, spawn members until the cap refuses further growth (ENOMEM),
# enumerate the live members by tag (cell_pids), prove cell_destroy is refused while
# members live (EBUSY), then release the members (pipe barrier EOF), reap them, free
# the CellId (cell_destroy), and prove the CellId is reusable + the stale handle is
# rejected. The probe prints "C6d OK" only when every step holds. Non-interactive.
# Runs single-core by default; the Makefile target also runs it under -smp 4.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/bootargs.sh
source "$ROOT/tests/lib/bootargs.sh"
KERNEL="$ROOT/build/kernel.elf"
SMP_CPU_COUNT="${SMP_CPUS:-1}"
if [[ "$SMP_CPU_COUNT" -gt 1 ]]; then
  DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
else
  DTB="${SMP_DTB:-$ROOT/build/virt.dtb}"
fi
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-c6d.XXXXXX)"
SELFTEST_DTB=""
PIDFILE="$(mktemp -t swiftos-c6d-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE" "${SELFTEST_DTB:-}"' EXIT

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (C6d cell lifecycle region) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/C6d: cell lifecycle/,$p' | tail -50 >&2 || true
  exit 1
}

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
SELFTEST_DTB="$(mktemp -t swiftos-selftest.XXXXXX.dtb)"
bake_selftest_dtb "$DTB" "${SELFTEST_DTB:-}" || exit 2
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=${SELFTEST_DTB:-},addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -kernel "$KERNEL")
"${qemu_args[@]}" </dev/null >"$LOG" 2>&1 &
QP=$!

await "C6d OK: page cap enforced, members enumerated, cell torn down and CellId reclaimed" 120 \
  || fail "cell-lifecycle probe did not reach its OK verdict"

stop_qemu
QP=""
clean="$(sed 's/\r//' "$LOG")"

for marker in \
  "C6d probe: created cell=" \
  "cap refused further growth=yes" \
  "C6d probe: cell_pids enumerated " \
  "C6d probe: destroy refused while members live (EBUSY)" \
  "C6d probe: cell destroyed, accounting reclaimed" \
  "C6d probe: CellId reusable (re-created cell=" \
  "C6d probe: stale handle to destroyed cell rejected" \
  "C6d OK: page cap enforced, members enumerated, cell torn down and CellId reclaimed"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; exit 1; }
done

for marker in \
  "C6d FAIL:" \
  "panic:"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; exit 1; }
done

echo "PASS: C6d cell resident-page cap enforced, members enumerated + torn down, CellId reclaimed under -smp $SMP_CPU_COUNT"
exit 0
