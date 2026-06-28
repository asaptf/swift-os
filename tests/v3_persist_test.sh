#!/usr/bin/env bash
# v3_persist_test.sh — V3b acceptance: a PERSIST runtime mount survives reboot by
# writing its entry through to the /data/.system/mounts manifest.
#
# Boot 1 (no manifest): the "media" disk auto-mounts at /mnt/media (V2a default).
#   We write a comment-only manifest to /data so media is NOT auto-mounted next
#   boot — leaving it enumerated-but-unmounted for the runtime mount.
# Boot 2 (manifest lists nothing): media is unmounted. /bin/mountprobe mounts it
#   at /mnt/store with PERSIST, which appends `media /mnt/store` to the manifest;
#   we write a marker file under it and confirm the manifest was updated.
# Boot 3 (manifest now lists media /mnt/store): WITHOUT running mountprobe, the
#   boot-time manifest path mounts media at /mnt/store and the marker file is
#   present — proving the PERSIST mount re-applied across reboot.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

FILEMARK="swiftos-V3B-persist-7m4q"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-v3per.XXXXXX)"
DATA_IMG="$WORK/data.img"        # volume 0 -> /data (unlabeled, holds the manifest)
DATA2_IMG="$WORK/data2.img"      # labeled "media"
PIDFILE="$(mktemp -t swiftos-v3per-pid.XXXXXX)"
QP=""; CURLOG=""

dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
dd if=/dev/zero of="$DATA2_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA2_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
printf '\005'     | dd of="$DATA2_IMG" bs=1 seek=60 conv=notrunc 2>/dev/null
printf 'media'    | dd of="$DATA2_IMG" bs=1 seek=61 conv=notrunc 2>/dev/null

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

start_boot() { local log="$1" fifo="$2"
  rm -f "$fifo"; mkfifo "$fifo"; CURLOG="$log"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
    -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" -device virtio-blk-device,drive=swosbase \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" -device virtio-blk-device,drive=swosdata \
    -drive "file=$DATA2_IMG,format=raw,if=none,id=swosdata2" -device virtio-blk-device,drive=swosdata2 \
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

# ---- Boot 1: media auto-mounts; seed a comment-only manifest -------------------
start_boot "$WORK/b1.log" "$WORK/in1"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "media disk not auto-mounted on boot 1"
login
send 'mkdir -p /data/.system'
send 'echo "# v3b: persisted mounts are appended below" > /data/.system/mounts'
send 'sync'; send 'exit'; sleep 0.8; stop_qemu

# ---- Boot 2: media unmounted; PERSIST mount writes through to the manifest ------
start_boot "$WORK/b2.log" "$WORK/in2"
await "V2 OK: mount manifest applied" 60 || fail "boot 2: manifest not read"
login
# media must be unmounted at boot (manifest lists nothing for it).
send 'cat /mnt/media/x 2>/dev/null || echo V3-MEDIA-UNMOUNTED'
await "V3-MEDIA-UNMOUNTED" 30 || fail "boot 2: media should be unmounted at boot"
# Runtime mount with PERSIST.
send 'mountprobe mount media /mnt/store persist'
await "MP: mount rc=0" 30 || fail "persist mount failed"
await "V3 OK: mount persisted to manifest" 30 || fail "kernel did not report the persist write-through"
send "echo $FILEMARK > /mnt/store/keep.txt"
# The manifest now carries the entry.
send 'cat /data/.system/mounts'
await "media /mnt/store" 30 || fail "boot 2: manifest was not updated with the persisted entry"
send 'sync'; send 'exit'; sleep 0.8; stop_qemu

# ---- Boot 3: the persisted entry re-mounts media at /mnt/store (no mountprobe) --
start_boot "$WORK/b3.log" "$WORK/in3"
await "V2 OK: mount manifest applied" 60 || fail "boot 3: manifest not read"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "boot 3: media not re-mounted from the manifest"
login
send 'ls /mnt'
await "store" 30 || fail "boot 3: media did not re-mount at /mnt/store"
send 'cat /mnt/store/keep.txt'
await "$FILEMARK" 30 || fail "boot 3: persisted file missing after reboot"
send 'exit'; sleep 0.3; stop_qemu

echo "PASS: PERSIST runtime mount writes through to the manifest and re-mounts across reboot (V3b acceptance)"
exit 0
