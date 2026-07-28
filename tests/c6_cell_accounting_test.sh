#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# c6_cell_accounting_test.sh - C6a: per-cell resource accounting domain.
#
# Boots the base image and lets the capProcessInspect boot probe
# (/bin/cellstatprobe, run from kernel/main.swift) run. The probe forks N children
# in globalCell, each blocked on a pipe barrier, and reads SYS_cell_stat around the
# fork/reap. It asserts the aggregate {processes, residentPages, handles} grows by
# exactly N live processes (and that pages + handles grow with them), then that a
# reaped process's charge is reclaimed from the domain. The probe prints
# "C6a OK: ..." only when every assertion holds. This is a non-interactive boot
# probe — the test just boots and awaits the verdict marker.
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

LOG="$(mktemp -t swiftos-c6a.XXXXXX)"
SELFTEST_DTB=""
PIDFILE="$(mktemp -t swiftos-c6a-pid.XXXXXX)"
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
  echo "--- serial (C6a cell accounting region) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/C6a: per-cell resource-accounting probe/,$p' | tail -40 >&2 || true
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

# The probe runs before the interactive tty demo, so no input is needed; just
# wait for its verdict.
await "C6a OK: per-cell accounting tracks live processes and reclaims reaped charge" 120 \
  || fail "per-cell accounting probe did not reach its OK verdict"

stop_qemu
QP=""
clean="$(sed 's/\r//' "$LOG")"

# The verdict line must be present, and the three per-stage report lines must show
# the aggregate (sanity: the probe ran all three measurements).
for marker in \
  "C6a probe: baseline" \
  "C6a probe: with-children" \
  "C6a probe: after-reap" \
  "C6a OK: per-cell accounting tracks live processes and reclaims reaped charge"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; exit 1; }
done

# No assertion-failure or crash markers may appear.
for marker in \
  "C6a FAIL:" \
  "panic:"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; exit 1; }
done

echo "PASS: C6a per-cell resource accounting tracked live processes and reclaimed reaped charge under -smp $SMP_CPU_COUNT"
exit 0
