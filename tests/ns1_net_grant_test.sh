#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ns1_net_grant_test.sh - NS1: virtio-net MMIO grant reaches userland, alongside the
# live in-kernel net stack.
#
# First step of network serviceization. Boots the base image with a virtio-net
# device (slirp) under -smp 4. The capConsole boot probe (/bin/netmmapprobe) claims
# the mappable virtio-net.0 grant, sys_device_mmap's the transport window, and reads
# the device identity + config MAC through the mapping. Asserts:
#   * the userland probe mapped the NIC and read the MAC + verified DEVID
#     (NS1 OK marker with the QEMU slirp default MAC 52:54:00:12:34:56);
#   * the in-kernel net stack is UNDISTURBED — it still brings the NIC up and gets
#     an ICMP echo reply through slirp (coexistence: the grant is map-only and the
#     probe reads read-only registers).
# Forbids any panic or probe failure marker.

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

LOG="$(mktemp -t swiftos-ns1.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-ns1-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
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
  -netdev user,id=n0 -device virtio-net-device,netdev=n0
  -kernel "$KERNEL")

"${qemu_args[@]}" >"$LOG" 2>&1 &
QP=$!

EXPECTS="net-a: virtio-net up, MAC 52:54:00:12:34:56
NS1 OK: virtio-net MMIO mapped from userland, MAC 52:54:00:12:34:56, DEVID verified
net-a OK: ICMP echo reply from 10.0.2.2
NS1 net mmap probe exited, code 0"

FORBIDS="panic:
netmmapprobe: net grant not usable
netmmapprobe: device_mmap failed
netmmapprobe: MMIO magic mismatch
netmmapprobe: MMIO device-id mismatch
netmmapprobe: no virtio-net device"

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
      echo "PASS: NS1 virtio-net MMIO grant reached userland alongside the live net stack under -smp $SMP_CPU_COUNT"
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
echo "FAIL: timed out waiting for NS1 markers under -smp $SMP_CPU_COUNT" >&2
echo "--- serial tail ---" >&2
sed 's/\r//' "$LOG" | tail -160 >&2
exit 1
