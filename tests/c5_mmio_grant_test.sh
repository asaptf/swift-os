#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# c5_mmio_grant_test.sh - C5h: real MMIO authority reaches the supervised userland
# driver service.
#
# Boots the base image with a virtio-input window present (-device
# virtio-keyboard-device). The LA1 supervisor (/bin/svc-supervisor) claims the now
# mappable virtio-input.0 grant and transfers it over IPC to the restartable driver
# service (/bin/svc-input). The service maps the MMIO window via sys_device_mmap and
# reads the virtio identification registers through the userland mapping, proving the
# metadata-only -> hardware-authority transition end to end. This test asserts the
# C5h marker plus the surrounding LA1 lifecycle, and forbids any failure/panic
# marker. Runs under -smp 4 by default (like the other C5 tests).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/bootargs.sh
source "$ROOT/tests/lib/bootargs.sh"
KERNEL="$ROOT/build/kernel.elf"
SMP_CPU_COUNT="${SMP_CPUS:-4}"
if [[ "$SMP_CPU_COUNT" -gt 1 ]]; then
  DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
else
  DTB="${SMP_DTB:-$ROOT/build/virt.dtb}"
fi
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
TIMEOUT="${TIMEOUT:-120}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]] || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-c5h.XXXXXX)"
SELFTEST_DTB=""
PIDFILE="$(mktemp -t swiftos-c5h-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE" "${SELFTEST_DTB:-}"' EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M
  -nographic -no-reboot -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
SELFTEST_DTB="$(mktemp -t swiftos-selftest.XXXXXX.dtb)"
bake_selftest_dtb "$DTB" "${SELFTEST_DTB:-}" || exit 2
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=${SELFTEST_DTB:-},addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -device virtio-keyboard-device
  -kernel "$KERNEL")

"${qemu_args[@]}" >"$LOG" 2>&1 &
QP=$!

# The marker the userland driver emits once it has mapped the granted MMIO window
# and verified the virtio magic through it. The hex address is the physical window
# base (deterministic), but we match loosely on the prefix + suffix so a different
# transport slot does not break the assertion.
EXPECTS="svc-input: device grant accepted gen 2
C5h OK: MMIO 0x
mapped from userland, MAGIC verified
LA1 OK: persistent supervisor + Swift userland service over name-registry grant"

FORBIDS="panic:
svc-input: device info mismatch
svc-input: device_mmap failed
svc-input: MMIO magic mismatch
svc-input: MMIO device-id mismatch
svc-supervisor: device info mismatch
svc-supervisor: device claim failed
svc-supervisor: device grant send failed
svc-supervisor: device ack mismatch
svc-supervisor: generation failed
LA1 supervisor demo exited, code 1"

all_found() {
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    grep -qF "$line" "$LOG" 2>/dev/null || return 1
  done <<<"$EXPECTS"
  return 0
}

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  if all_found; then
    stop_qemu
    QP=""
    clean="$(sed 's/\r//' "$LOG")"
    ok=1
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      grep -qF "$line" <<<"$clean" && { echo "FAIL: forbidden marker present: $line" >&2; ok=0; }
    done <<<"$FORBIDS"
    if [[ "$ok" -eq 1 ]]; then
      echo "PASS: C5h userland MMIO authority grant verified under -smp $SMP_CPU_COUNT"
      exit 0
    fi
    echo "--- serial tail ---" >&2
    sed 's/\r//' "$LOG" | tail -120 >&2
    exit 1
  fi
  sleep 0.1
done

stop_qemu
QP=""
echo "FAIL: timed out waiting for C5h MMIO-grant markers under -smp $SMP_CPU_COUNT" >&2
echo "--- serial tail ---" >&2
sed 's/\r//' "$LOG" | tail -160 >&2
exit 1
