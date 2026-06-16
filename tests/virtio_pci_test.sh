#!/usr/bin/env bash
# virtio_pci_test.sh — H2 acceptance: a virtio-pci device is discovered and
# exchanges a queue.
#
# Boots on a GICv3 machine with a virtio-rng attached over PCIe (`virtio-rng-pci`)
# — the transport the Hetzner ARM VM uses — and asserts the kernel:
#   * enumerates PCIe config space through the ECAM window (0x40_1000_0000),
#   * finds the virtio-rng function, assigns its BARs (no firmware on the
#     `-kernel` path), resolves the modern virtio capabilities, and
#   * runs a full virtqueue round trip (descriptor → avail → notify → used),
#     returning entropy bytes — printed as "H2 OK: virtio-pci rng exchanged a
#     queue".
# This is emitted during early driver bring-up, before the base FS / userland,
# so no base image is needed.
#
# Note: QEMU's `virtio-rng-pci` is a *transitional* device (PCI id 0x1af4:0x1005,
# virtio type in the subsystem id), which the driver must recognise alongside
# modern-only ids (0x1040+type). Both expose the modern config structures.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt-gicv3-smp2.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  "$QEMU" -M "virt,gic-version=3,dumpdtb=$DTB" -cpu cortex-a72 -smp 2 \
    -m 256M -nographic >/dev/null 2>&1 || { echo "FAIL: cannot dump GICv3 DTB" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-vpci.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-vpci-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

"$QEMU" -M "virt,gic-version=3" -cpu max -smp 2 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -device virtio-rng-pci \
  -kernel "$KERNEL" </dev/null >"$LOG" 2>&1 &
QP=$!

n=0
while (( n < 200 )); do
  grep -qaF "H2 OK: virtio-pci rng exchanged a queue" "$LOG" 2>/dev/null && break
  grep -qaF "H2 WARN" "$LOG" 2>/dev/null && break
  grep -qaF "panic: unexpected EL1 exception" "$LOG" 2>/dev/null && break
  sleep 0.1; n=$((n + 1))
done

if grep -qaF "H2 OK: virtio-pci rng exchanged a queue" "$LOG"; then
  echo "PASS: virtio-pci device discovered and exchanged a queue"
  grep -aF "H2 OK: virtio-pci" "$LOG" | sed 's/\r//' | head -1
  exit 0
fi

echo "FAIL: virtio-pci queue exchange not observed"
echo "--- log ---"; sed 's/\r//' "$LOG" | tail -40
exit 1
