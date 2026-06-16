#!/usr/bin/env bash
# datafs_test.sh — D1 acceptance: the persistent /data filesystem survives reboot.
#
# Boots the real base image with a writable "data" disk, logs in, and through the
# normal VFS syscall path (busybox `>` redirect, mkdir, cat, ls) creates a file
# and a nested file under /data. Then it reboots against the SAME data disk and
# reads them back. Seeing the file contents after a full reboot proves datafs
# persists to the block device (not RAM tmpfs) and that the on-disk inode/bitmap/
# directory structures survive remount.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

PERSISTMARK="swiftos-DATAFS-PERSIST-9q2z"
NESTMARK="swiftos-DATAFS-NESTED-5x8w"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$BASE_IMG" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-datafs.XXXXXX)"
DATA_IMG="$WORK/data.img"
PIDFILE="$(mktemp -t swiftos-datafs-pid.XXXXXX)"
QP=""; CURLOG=""

dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null

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

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$CURLOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
send() { printf '%s\n' "$1" >&3; sleep 0.15; }

fail() {
  echo "FAIL: $1" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$CURLOG" 2>/dev/null | sed -n '/D1/,$p' | tail -40 >&2 || true
  exit 1
}

start_boot() {  # start_boot LOGFILE INFIFO
  local log="$1" fifo="$2"
  rm -f "$fifo"; mkfifo "$fifo"
  CURLOG="$log"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    "${dtb_args[@]}" \
    -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" \
    -device virtio-blk-device,drive=swosbase \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" \
    -device virtio-blk-device,drive=swosdata \
    -kernel "$KERNEL" <"$fifo" >"$log" 2>&1 &
  QP=$!
  exec 3<>"$fifo"
}

login() {  # walk the boot tty + login prompts to a root busybox shell
  await "M7 tty: type a line then Enter" 60 || fail "no tty line prompt"
  send 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
  printf '\003' >&3; sleep 0.15
  await "swift-os login:" 90 || fail "no login prompt"
  send 'root'
  await "Password:" 90 || fail "no password prompt"
  send 'swordfish'
  await "Welcome to swift-os, root" 120 || fail "root login did not complete"
}

# ---- Boot 1: create files under /data via real syscalls --------------------
start_boot "$WORK/boot1.log" "$WORK/in1"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted on boot 1"
login
send "echo $PERSISTMARK > /data/persist.txt"
send 'mkdir /data/subdir'
send "echo $NESTMARK > /data/subdir/inner.txt"
send 'ls /data'
await "persist.txt" 30 || fail "persist.txt not created under /data (boot 1)"
await "subdir" 20      || fail "subdir not created under /data (boot 1)"
send 'exit'
sleep 0.5
stop_qemu

# ---- Boot 2: same data disk, read the files back ---------------------------
start_boot "$WORK/boot2.log" "$WORK/in2"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted on boot 2"
login
send 'cat /data/persist.txt'
await "$PERSISTMARK" 30 || fail "/data/persist.txt did NOT survive reboot"
send 'cat /data/subdir/inner.txt'
await "$NESTMARK" 30 || fail "/data/subdir/inner.txt did NOT survive reboot"
send 'exit'
sleep 0.3
stop_qemu

echo "PASS: /data datafs files persist across reboot (D1 acceptance)"
exit 0
