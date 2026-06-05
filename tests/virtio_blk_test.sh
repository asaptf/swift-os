#!/usr/bin/env bash
# virtio_blk_test.sh — M11b acceptance: read a sector from a real disk.
#
# Attaches the packed base image (build/base.img) as a virtio-blk disk and boots
# the kernel. The M11b probe brings up the block device discovered in the
# virtio-mmio window, reads sector 0, and recognises the "SWOSBASE" magic that
# starts every packed base image — proving the kernel read real bytes off the
# disk, not a kernel literal.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-blk.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-blk-pid.XXXXXX)"
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
  if [[ -n "$QP" ]]; then
    wait "$QP" 2>/dev/null || true
  fi
}
cleanup() {
  stop_qemu
  rm -f "$LOG" "$PIDFILE"
}
trap cleanup EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

# force-legacy=false selects the modern (v2) virtio-mmio interface our driver
# speaks. The probe runs early in boot, so a short Ctrl-C just stops the kernel.
( sleep 9; printf '\003'; sleep 1 ) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=disk0,readonly=on" \
  -device virtio-blk-device,drive=disk0 \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 12
stop_qemu
QP=""

ok=1
grep -qF "M9 platform: virtio-mmio" "$LOG" || { echo "FAIL: HAL did not discover the virtio-mmio window" >&2; ok=0; }
grep -qF "M11b: virtio-blk disk, capacity" "$LOG" || { echo "FAIL: block device not brought up" >&2; ok=0; }
grep -qF "M11b OK: sector 0 read from disk, SWOSBASE magic verified" "$LOG" || { echo "FAIL: sector 0 read/verify" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: virtio-blk read sector 0 from disk (M11b acceptance)"
  exit 0
fi
echo "--- serial log ---" >&2
sed 's/\r//' "$LOG" | grep -iE "M9 platform|M11b|virtio|panic" >&2
exit 1
