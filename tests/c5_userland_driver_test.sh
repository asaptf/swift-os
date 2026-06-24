#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# c5_userland_driver_test.sh - C5i: the virtio-input driver runs entirely in
# userland; the kernel no longer owns the device.
#
# Boots the base image with a virtio-input window present (-device
# virtio-keyboard-device) under -smp 4. Asserts:
#   * the kernel SKIPPED its in-kernel polled virtio-input driver (the userland
#     driver service owns the device via the mappable MMIO grant);
#   * the userland driver (/bin/svc-input) negotiated virtio features and brought
#     the event virtqueue ready, in BOTH supervisor generations;
#   * the supervisor killed the driver and a restarted instance recovered, re-
#     mapping and re-initializing the device;
#   * the C5i success marker is emitted.
# Forbids any panic or driver/supervisor failure marker.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

LOG="$(mktemp -t swiftos-c5i.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-c5i-pid.XXXXXX)"
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
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M
  -nographic -no-reboot -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -device virtio-keyboard-device
  -kernel "$KERNEL")

"${qemu_args[@]}" >"$LOG" 2>&1 &
QP=$!

EXPECTS="virtio-kbd: kernel skipped virtioKbdInit (userland driver owns virtio-input)
svc-input: virtio features negotiated gen 1
svc-input: virtio queue ready gen 1
svc-supervisor: service exited; restarting next generation
svc-input: virtio features negotiated gen 2
svc-input: virtio queue ready gen 2
C5i OK: userland virtio-input driver initialized and recovered"

FORBIDS="panic:
svc-input: device_mmap failed
virtio-input: virt_to_phys failed
virtio-input: ring mmap failed
virtio-input: FEATURES_OK rejected
virtio-input: queue unavailable
svc-input: MMIO magic mismatch
svc-input: device info mismatch
svc-supervisor: device claim failed
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
      echo "PASS: C5i userland virtio-input driver owns the device + recovers under -smp $SMP_CPU_COUNT"
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
echo "FAIL: timed out waiting for C5i userland-driver markers under -smp $SMP_CPU_COUNT" >&2
echo "--- serial tail ---" >&2
sed 's/\r//' "$LOG" | tail -160 >&2
exit 1
