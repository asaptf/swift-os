#!/usr/bin/env bash
# h5_acpi_test.sh — H5 acceptance: the kernel derives its platform config from
# ACPI, with no device tree.
#
# Boots the GPT disk under UEFI on the Hetzner device model (GICv3, virtio over
# PCIe, ACPI firmware). The loader forwards the ACPI RSDP; the kernel walks
# RSDP→XSDT→MADT/MCFG/SPCR/FADT and derives the GIC (GICD/GICR), the PCIe ECAM,
# the console UART, the CPU topology, and the PSCI conduit — without an FDT. The
# proof is "M9 OK: hardware discovered from ACPI" (not "from device tree"),
# followed by the whole stack coming up on those ACPI-derived values: GICv3
# interrupts, the secondary CPU online via PSCI, a virtio-pci device (ECAM), and
# a DHCP lease over virtio-net-pci.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK_IMG="$ROOT/build/swift-os.img"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }
[[ -f "$DISK_IMG" ]]   || { echo "FAIL: $DISK_IMG missing (run 'make disk' after 'make base-image')" >&2; exit 2; }

LOG="$(mktemp -t swiftos-h5.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-h5-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

# ACPI firmware (no acpi=off), GICv3, boot disk on virtio-scsi-pci, NIC + RNG on
# PCIe — exactly the Hetzner device model. No DTB is injected.
"$QEMU" -M virt,gic-version=3 -cpu max -m 4G -smp 2 -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -bios "$AAVMF_CODE" \
  -drive "file=$DISK_IMG,format=raw,if=none,id=hdd" \
  -device virtio-scsi-pci -device scsi-hd,drive=hdd \
  -device virtio-net-pci,netdev=n0 -netdev user,id=n0 \
  -device virtio-rng-pci \
  </dev/null >"$LOG" 2>&1 &
QP=$!

n=0
while (( n < 1200 )); do
  grep -qF "net-dhcp OK: lease" "$LOG" 2>/dev/null && break
  grep -qF "panic" "$LOG" 2>/dev/null && break
  grep -qF "M9 OK: hardware discovered from device tree" "$LOG" 2>/dev/null && break
  sleep 0.1; n=$((n + 1))
done
stop_qemu; QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
chk() { grep -qF "$1" <<<"$clean" || { echo "FAIL: missing '$1'" >&2; ok=0; }; }
# Platform config came from ACPI, not a device tree.
chk "M9 OK: hardware discovered from ACPI"
grep -qF "M9 OK: hardware discovered from device tree" <<<"$clean" \
  && { echo "FAIL: kernel used the device tree, not ACPI" >&2; ok=0; }
# The exact device map ACPI yielded (GICD/GICR/UART/ECAM).
chk "M9 platform: ACPI gic 0x0000000008000000 redist 0x00000000080A0000 uart 0x0000000009000000 ecam 0x0000004010000000"
# The whole stack came up on the ACPI-derived config:
chk "M2 GIC: GICv3"                        # GIC from MADT → interrupts live
chk "S1 OK: secondary CPUs online"         # CPU topology (MADT) + PSCI (FADT)
chk "H2 OK: virtio-pci"                    # ECAM (MCFG) → PCI enumeration
chk "net-dhcp OK: lease"                   # NIC over PCI → DHCP

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: kernel derived GIC/ECAM/UART/CPU/PSCI from ACPI and booted the stack (no FDT)"
  grep -aF "M9 platform: ACPI" <<<"$clean" | head -1
  exit 0
fi
echo "--- serial ---" >&2; grep -aiE 'M9|ACPI|M2 GIC|S1 |H2 OK|net-dhcp|panic|FAR_EL1' <<<"$clean" | tail -40 >&2
exit 1
