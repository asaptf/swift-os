#!/usr/bin/env bash
# v2_label_test.sh — V2a acceptance: a datafs volume carries a stable on-disk
# identity (128-bit UUID + label), and the kernel mounts it by LABEL (not scan
# order) at /mnt/<label>, with the UUID stable across reboot.
#
# The second data disk is provisioned offline with the SWDATAFS magic plus a
# label "media" stamped into the superblock. The kernel formats it on first boot
# (generating the UUID, preserving the label), mounts it at /mnt/media, and
# reports `V2 vol: uuid=<lo>:<hi> labellen=5`. After a reboot against the same
# disk the volume is re-mounted at /mnt/media with the SAME UUID and the file
# written under it survives.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

LABEL="media"
FILEMARK="swiftos-V2-LABEL-file-8k4q"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-v2lbl.XXXXXX)"
DATA_IMG="$WORK/data.img"        # volume 0 -> /data (unlabeled)
DATA2_IMG="$WORK/data2.img"      # volume 1 -> /mnt/media (labeled)
PIDFILE="$(mktemp -t swiftos-v2lbl-pid.XXXXXX)"
QP=""; CURLOG=""

# Volume 0: blank, magic only (mounts at /data).
dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
# Volume 1: magic + a provisioned label "media" (labellen at SB_LABELLEN=60,
# label bytes at SB_LABEL=61). The kernel preserves the label across format.
dd if=/dev/zero of="$DATA2_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA2_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
printf '\005'     | dd of="$DATA2_IMG" bs=1 seek=60 conv=notrunc 2>/dev/null
printf '%s' "$LABEL" | dd of="$DATA2_IMG" bs=1 seek=61 conv=notrunc 2>/dev/null

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
uuid_of() { sed 's/\r//' "$1" | sed -n 's/.*V2 vol: uuid=\([0-9]*:[0-9]*\) labellen=\([0-9]*\).*/\1 \2/p' | head -1; }

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

login() {
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

# ---- Boot 1: label-driven mount + write a file -----------------------------
start_boot "$WORK/boot1.log" "$WORK/in1"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "labeled volume not mounted on boot 1"
login
send 'ls /mnt'
await "$LABEL" 30 || fail "volume did not mount at /mnt/$LABEL (label-driven naming failed)"
send "echo $FILEMARK > /mnt/$LABEL/f.txt"
send "cat /mnt/$LABEL/f.txt"
await "$FILEMARK" 30 || fail "could not write/read under /mnt/$LABEL (boot 1)"
send 'exit'
sleep 0.5
stop_qemu
UUID1="$(uuid_of "$WORK/boot1.log")"
[[ -n "$UUID1" ]] || fail "no 'V2 vol: uuid=' marker on boot 1"
LO1="${UUID1%%:*}"; REST1="${UUID1#*:}"; HI1="${REST1%% *}"; LLEN1="${UUID1##* }"
[[ "$LLEN1" == "5" ]] || fail "boot 1 labellen=$LLEN1, expected 5"
[[ "$LO1:$HI1" != "0:0" ]] || fail "boot 1 UUID is zero (not generated)"

# ---- Boot 2: same disks, label mount + UUID stable + file survives ---------
start_boot "$WORK/boot2.log" "$WORK/in2"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "labeled volume not mounted on boot 2"
login
send 'ls /mnt'
await "$LABEL" 30 || fail "volume did not re-mount at /mnt/$LABEL on boot 2"
send "cat /mnt/$LABEL/f.txt"
await "$FILEMARK" 30 || fail "/mnt/$LABEL/f.txt did NOT survive reboot"
send 'exit'
sleep 0.3
stop_qemu
UUID2="$(uuid_of "$WORK/boot2.log")"
LO2="${UUID2%%:*}"; REST2="${UUID2#*:}"; HI2="${REST2%% *}"
[[ "$LO1:$HI1" == "$LO2:$HI2" ]] || fail "UUID changed across reboot: $LO1:$HI1 -> $LO2:$HI2 (not stable)"

echo "PASS: labeled volume mounts at /mnt/$LABEL, UUID $LO1:$HI1 stable across reboot (V2a acceptance)"
exit 0
