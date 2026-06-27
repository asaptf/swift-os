#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# procmax_test.sh - process-table capacity (kMaxProcesses).
#
# Boots the base image and lets the boot probe (/bin/procmaxprobe, run from
# kernel/main.swift) run. The probe forks children in globalCell, each blocked on
# a pipe barrier, until fork() returns -EAGAIN. It asserts more than the historical
# 16-slot cap were live simultaneously (the cap is raised), that the boundary
# returned a clean EAGAIN, and that saturate-and-reap leaks no slot. The probe
# prints "PROCMAX OK: ..." only when every assertion holds. This is a
# non-interactive boot probe — the test just boots and awaits the verdict marker.
# Runs single-core by default; the Makefile target also runs it under -smp 4.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

LOG="$(mktemp -t swiftos-procmax.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-procmax-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

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
  echo "--- serial (procmax capacity region) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/process-table capacity probe/,$p' | tail -40 >&2 || true
  exit 1
}

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -kernel "$KERNEL")
"${qemu_args[@]}" </dev/null >"$LOG" 2>&1 &
QP=$!

# The probe runs before the interactive tty demo, so no input is needed; just
# wait for its verdict.
await "PROCMAX OK:" 120 \
  || fail "process-table capacity probe did not reach its OK verdict"

stop_qemu
QP=""
clean="$(sed 's/\r//' "$LOG")"

# The verdict line must be present, and the per-stage report lines must show the
# probe ran the baseline / saturate / after-reap measurements.
for marker in \
  "procmax probe: baseline" \
  "procmax probe: forked=" \
  "procmax probe: after-reap" \
  "PROCMAX OK:"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; exit 1; }
done

# No assertion-failure or crash markers may appear.
for marker in \
  "PROCMAX FAIL:" \
  "panic:"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; exit 1; }
done

echo "PASS: process-table capacity exceeds the old 16-slot cap with a clean EAGAIN boundary and no leak under -smp $SMP_CPU_COUNT"
exit 0
