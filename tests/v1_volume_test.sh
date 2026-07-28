#!/usr/bin/env bash
# v1_volume_test.sh — V1 acceptance: a SECOND SWDATAFS volume mounts at
# /mnt/data1 as a distinct datafs instance, writes to it are isolated from
# /data, and both volumes survive reboot independently.
#
# Boots the real base image with TWO writable "data" disks (both stamped with
# the SWDATAFS sector-0 magic). The kernel mounts the first as /data (volume 0)
# and the second under /mnt/data1 (volume 1). Through the normal VFS syscall
# path the test writes the SAME filename (iso.txt) to both mountpoints with
# DIFFERENT content, plus a file that exists only on /data. It proves:
#   - isolation: /data/iso.txt and /mnt/data1/iso.txt keep distinct content
#     (a shared backing store would have one overwrite the other), and a file
#     created on /data is absent on /mnt/data1;
#   - persistence: after a full reboot against the SAME two disks, each volume
#     still reads back its own content.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

DATAMARK="swiftos-V1-DATA-iso-7r3k"     # /data/iso.txt
VOLMARK="swiftos-V1-VOL1-iso-2m9p"      # /mnt/data1/iso.txt (same name, diff content)
DATAONLY="swiftos-V1-DATAONLY-5t8x"     # /data/onlydata.txt (must NOT appear on vol1)
NOFILE1="V1-ISO-NOFILE-BOOT1-q4z7"      # vol1 lacks onlydata.txt (boot 1)
NOFILE2="V1-ISO-NOFILE-BOOT2-w8c2"      # vol1 lacks onlydata.txt (boot 2, post-reboot)

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$BASE_IMG" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-v1vol.XXXXXX)"
DATA_IMG="$WORK/data.img"
DATA2_IMG="$WORK/data2.img"
PIDFILE="$(mktemp -t swiftos-v1vol-pid.XXXXXX)"
QP=""; CURLOG=""

# Two blank, SWDATAFS-stamped data disks. The kernel formats each on first boot.
for img in "$DATA_IMG" "$DATA2_IMG"; do
  dd if=/dev/zero of="$img" bs=1048576 count=16 2>/dev/null
  printf 'SWDATAFS' | dd of="$img" bs=1 seek=0 conv=notrunc 2>/dev/null
done

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
    -drive "file=$DATA2_IMG,format=raw,if=none,id=swosdata2" \
    -device virtio-blk-device,drive=swosdata2 \
    -kernel "$KERNEL" <"$fifo" >"$log" 2>&1 &
  QP=$!
  exec 3<>"$fifo"
}

login() {  # walk the boot tty + login prompts to a root busybox shell
  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || fail "no tty line prompt"
  send 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
  printf '\003' >&3; sleep 0.15
  await "swift-os login:" 90 || fail "no login prompt"
  send 'root'
  await "Password:" 90 || fail "no password prompt"
  send 'swordfish'
  await "Welcome to swift-os, root" 120 || fail "root login did not complete"
}

# ---- Boot 1: write distinct content to both volumes ------------------------
start_boot "$WORK/boot1.log" "$WORK/in1"
await "D1 OK: datafs mounted at /data" 60 || fail "/data (volume 0) not mounted on boot 1"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "second volume not mounted on boot 1"
login
send "echo $DATAMARK > /data/iso.txt"
send "echo $VOLMARK > /mnt/data1/iso.txt"
send "echo $DATAONLY > /data/onlydata.txt"
send 'ls /mnt/data1'
await "iso.txt" 30 || fail "/mnt/data1/iso.txt not created (boot 1)"
# Same-path isolation, live: each mountpoint reads back its own content.
send 'cat /data/iso.txt'
await "$DATAMARK" 30 || fail "/data/iso.txt wrong content (boot 1)"
send 'cat /mnt/data1/iso.txt'
await "$VOLMARK" 30 || fail "/mnt/data1/iso.txt wrong content (boot 1)"
# A /data-only file must be absent on volume 1 (separate inode tables).
send "cat /mnt/data1/onlydata.txt 2>/dev/null || echo $NOFILE1"
await "$NOFILE1" 30 || fail "onlydata.txt leaked onto /mnt/data1 (boot 1) — volumes not isolated"
send 'exit'
sleep 0.5
stop_qemu

# ---- Boot 2: same two disks, read both volumes back ------------------------
start_boot "$WORK/boot2.log" "$WORK/in2"
await "D1 OK: datafs mounted at /data" 60 || fail "/data not mounted on boot 2"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "second volume not mounted on boot 2"
login
send 'cat /data/iso.txt'
await "$DATAMARK" 30 || fail "/data/iso.txt did NOT survive reboot"
send 'cat /mnt/data1/iso.txt'
await "$VOLMARK" 30 || fail "/mnt/data1/iso.txt did NOT survive reboot (or aliased /data)"
send 'cat /data/onlydata.txt'
await "$DATAONLY" 30 || fail "/data/onlydata.txt did NOT survive reboot"
send "cat /mnt/data1/onlydata.txt 2>/dev/null || echo $NOFILE2"
await "$NOFILE2" 30 || fail "onlydata.txt present on /mnt/data1 after reboot — volumes not isolated"
send 'exit'
sleep 0.3
stop_qemu

echo "PASS: second datafs volume mounts at /mnt/data1, isolated from /data, both survive reboot (V1 acceptance)"
exit 0
