#!/usr/bin/env bash
# v4_pci_test.sh — V4b acceptance: a SWDATAFS data volume attached over the
# virtio-PCI transport (a real Hetzner Cloud Volume is a virtio-blk-pci disk) is
# enumerated, mounted, read/written, and survives reboot — exactly like a
# virtio-mmio data disk. The /data root stays on virtio-mmio; only the extra
# "media" volume rides virtio-blk-pci, proving the block driver drives both
# transports through VirtioTransportOps (V4a) and the PCI scan finds it (V4b).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

LABEL="media"
FILEMARK="swiftos-V4-PCI-file-6r2v"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-v4pci.XXXXXX)"
DATA_IMG="$WORK/data.img"        # volume 0 -> /data (unlabeled, virtio-mmio)
MEDIA_IMG="$WORK/media.img"      # the "Hetzner Volume": labeled, on virtio-blk-pci
PIDFILE="$(mktemp -t swiftos-v4pci-pid.XXXXXX)"
QP=""; CURLOG=""

dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
dd if=/dev/zero of="$MEDIA_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$MEDIA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
printf '\005'     | dd of="$MEDIA_IMG" bs=1 seek=60 conv=notrunc 2>/dev/null
printf '%s' "$LABEL" | dd of="$MEDIA_IMG" bs=1 seek=61 conv=notrunc 2>/dev/null

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  QP=""
  exec 3>&- 2>/dev/null || true
}
cleanup() { stop_qemu; rm -rf "$WORK" "$PIDFILE"; }
trap cleanup EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() { local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do grep -qF "$marker" "$CURLOG" 2>/dev/null && return 0; sleep 0.1; n=$((n + 1)); done
  return 1
}
send() { printf '%s\n' "$1" >&3; sleep 0.2; }

fail() {
  echo "FAIL: $1" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$CURLOG" 2>/dev/null | sed -n '/D1/,$p' | tail -40 >&2 || true
  exit 1
}

# The "media" disk rides virtio-blk-PCI (the Hetzner Volume transport); base +
# /data stay on virtio-mmio. QEMU `virt` exposes a PCIe ECAM at 0x40_1000_0000,
# which the kernel scans (platform.pcieEcamBase default).
start_boot() { local log="$1" fifo="$2"
  rm -f "$fifo"; mkfifo "$fifo"; CURLOG="$log"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
    -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" -device virtio-blk-device,drive=swosbase \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" -device virtio-blk-device,drive=swosdata \
    -drive "file=$MEDIA_IMG,format=raw,if=none,id=swosmedia" -device virtio-blk-pci,drive=swosmedia \
    -kernel "$KERNEL" <"$fifo" >"$log" 2>&1 &
  QP=$!; exec 3<>"$fifo"
}

login() {
  await "M7 tty: type a line then Enter" 60 || fail "no tty line prompt"
  send 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
  printf '\003' >&3; sleep 0.15
  await "swift-os login:" 90 || fail "no login prompt"
  send 'root'; await "Password:" 90 || fail "no password prompt"
  send 'swordfish'; await "Welcome to swift-os, root" 120 || fail "root login did not complete"
}

# ---- Boot 1: the PCI volume is enumerated + mounted; write a file --------------
start_boot "$WORK/b1.log" "$WORK/in1"
await "V4: virtio-blk-pci disks enumerated" 60 || fail "virtio-blk-pci disk not enumerated (PCI scan)"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "PCI media volume not mounted on boot 1"
login
send 'ls /mnt'
await "$LABEL" 30 || fail "PCI volume did not mount at /mnt/$LABEL"
send "echo $FILEMARK > /mnt/$LABEL/f.txt"
send "cat /mnt/$LABEL/f.txt"
await "$FILEMARK" 30 || fail "could not write/read the PCI-backed volume (boot 1)"
send 'sync'; send 'exit'; sleep 0.8; stop_qemu

# ---- Boot 2: the PCI volume re-mounts; the file survives reboot ----------------
start_boot "$WORK/b2.log" "$WORK/in2"
await "V4: virtio-blk-pci disks enumerated" 60 || fail "virtio-blk-pci disk not enumerated on boot 2"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "PCI media volume not re-mounted on boot 2"
login
send "cat /mnt/$LABEL/f.txt"
await "$FILEMARK" 30 || fail "PCI-backed file did NOT survive reboot"
send 'exit'; sleep 0.3; stop_qemu

echo "PASS: SWDATAFS volume over virtio-blk-pci enumerated, mounted, read/written, persistent (V4b acceptance)"
exit 0
