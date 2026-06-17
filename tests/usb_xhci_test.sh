#!/usr/bin/env bash
# usb_xhci_test.sh — USB M1 acceptance: bring up the xHCI controller over PCIe
# and detect an attached USB keyboard.
#
# Boots the kernel on QEMU `virt` with a real xHCI controller (`-device
# qemu-xhci`) and a USB keyboard plugged into it (`-device usb-kbd`). The USB M1
# probe finds the controller through the PCIe ECAM window, resets and runs it,
# then scans the root-hub ports. Success means the controller reached the
# running state AND the keyboard was seen on a port — proving we drove real xHCI
# registers, not a kernel literal.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-usb.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-usb-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
cleanup() { stop_qemu; rm -f "$LOG" "$PIDFILE"; }
trap cleanup EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

# qemu-xhci is a PCIe device; usb-kbd plugs into its USB bus. The probe runs
# early in boot, so a short Ctrl-C afterwards just stops the kernel.
( sleep 9; printf '\003'; sleep 1 ) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  ${dtb_args[@]+"${dtb_args[@]}"} \
  -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
await "USB1 OK: xHCI up" 30 || true
sleep 1
stop_qemu
QP=""

ok=1
grep -qE "USB1: xHCI [0-9a-fx]+ at" "$LOG" || { echo "FAIL: xHCI controller not found on PCI" >&2; ok=0; }
grep -qF "USB1 OK: xHCI up" "$LOG"        || { echo "FAIL: xHCI controller did not reach running state" >&2; ok=0; }
grep -qF "USB1: device connected on xHCI port" "$LOG" || { echo "FAIL: USB keyboard not detected on any port" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: xHCI brought up over PCIe, USB keyboard detected (USB M1 acceptance)"
else
  echo "----- guest log -----" >&2
  grep -E "USB1|M9 platform|panic" "$LOG" >&2 || true
  exit 1
fi
