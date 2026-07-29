#!/usr/bin/env bash
# v2_anchor_test.sh — V2c acceptance: the root /data volume is anchored by a UUID
# pinned in the kernel command line (FDT /chosen/bootargs datafs.root=<hex>), so
# /data follows that specific disk regardless of attach/scan order — and on first
# boot a blank disk is formatted as the root stamping the pinned UUID.
#
# The pin is hi=0x0A (10), lo=0x14 (20) -> the kernel reports `V2c root: uuid=20:10`.
# Two blank, unlabeled data disks are attached. Boot 1 (order A,B) formats the
# first as the pinned root and writes a marker to /data. Boot 2 SWAPS the disk
# order (B,A): the pinned disk — now second in scan order — must still be /data
# (same UUID, marker file present), proving the anchor beats scan order.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

PIN_HEX="000000000000000a0000000000000014"   # hi=0x0A=10, lo=0x14=20
PIN_MARK="V2c root: uuid=20:10"
ANCHOR="swiftos-V2C-anchor-6h2n"

[[ -f "$KERNEL" ]]   || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }
[[ -f "$DTB" ]]      || { echo "FAIL: $DTB missing (make build/virt.dtb)" >&2; exit 2; }
command -v dtc >/dev/null || { echo "FAIL: dtc not installed (needed to bake the cmdline UUID into a DTB)" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-v2anc.XXXXXX)"
PDTB="$WORK/virt-anchor.dtb"
DA="$WORK/da.img"; DB="$WORK/db.img"
PIDFILE="$(mktemp -t swiftos-v2anc-pid.XXXXXX)"
QP=""; CURLOG=""

# Bake the pinned root UUID into /chosen/bootargs of a copy of virt.dtb.
dtc -I dtb -O dts "$DTB" 2>/dev/null \
  | awk -v b="\t\tbootargs = \"datafs.root=$PIN_HEX\";" '/chosen \{/{print; print b; next} {print}' \
  | dtc -I dts -O dtb 2>/dev/null > "$PDTB"
strings "$PDTB" | grep -q "datafs.root=$PIN_HEX" || { echo "FAIL: could not bake the pin into the DTB" >&2; rm -rf "$WORK" "$PIDFILE"; exit 2; }

# Two blank, unlabeled data disks (magic only).
for img in "$DA" "$DB"; do
  dd if=/dev/zero of="$img" bs=1048576 count=16 2>/dev/null
  printf 'SWDATAFS' | dd of="$img" bs=1 seek=0 conv=notrunc 2>/dev/null
done

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  QP=""; exec 3>&- 2>/dev/null || true
}
cleanup() { stop_qemu; rm -rf "$WORK" "$PIDFILE"; }
trap cleanup EXIT

await() { local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do grep -qF "$marker" "$CURLOG" 2>/dev/null && return 0; sleep 0.1; n=$((n + 1)); done
  return 1
}
send() { printf '%s\n' "$1" >&3; sleep 0.2; }

fail() { echo "FAIL: $1" >&2; echo "--- serial tail ---" >&2
  sed 's/\r//' "$CURLOG" 2>/dev/null | sed -n '/V2c/,$p' | tail -40 >&2 || true; exit 1; }

# start_boot LOGFILE INFIFO DISK1 DISK2  (DISK1 is first in scan order)
start_boot() { local log="$1" fifo="$2" d1="$3" d2="$4"
  rm -f "$fifo"; mkfifo "$fifo"; CURLOG="$log"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" -global virtio-mmio.force-legacy=false \
    -device "loader,file=$PDTB,addr=0x4FF00000,force-raw=on" \
    -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" -device virtio-blk-device,drive=swosbase \
    -drive "file=$d1,format=raw,if=none,id=sdx" -device virtio-blk-device,drive=sdx \
    -drive "file=$d2,format=raw,if=none,id=sdy" -device virtio-blk-device,drive=sdy \
    -kernel "$KERNEL" <"$fifo" >"$log" 2>&1 &
  QP=$!; exec 3<>"$fifo"
}

login() {
  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || fail "no tty line prompt"
  send 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
  printf '\003' >&3; sleep 0.15
  await "swift-os login:" 90 || fail "no login prompt"
  send 'root'; await "Password:" 90 || fail "no password prompt"
  send 'swordfish'; await "Welcome to swift-os, root" 120 || fail "root login did not complete"
  await_shell_ready "$CURLOG" 60 || fail "guest shell not reading after login"
}

# ---- Boot 1 (order A,B): format the pinned root, write an anchor file ---------
start_boot "$WORK/b1.log" "$WORK/in1" "$DA" "$DB"
await "V2c: kernel command line pins the /data root volume UUID" 60 || fail "boot 1: cmdline pin not parsed"
await "$PIN_MARK" 60 || fail "boot 1: /data not formatted with the pinned UUID"
login
send "echo $ANCHOR > /data/anchor.txt"
send 'cat /data/anchor.txt'
await "$ANCHOR" 30 || fail "boot 1: could not write the anchor file to /data"
send 'sync'; send 'exit'; sleep 0.8; stop_qemu

# ---- Boot 2 (order B,A swapped): the pinned disk is still /data --------------
start_boot "$WORK/b2.log" "$WORK/in2" "$DB" "$DA"
await "$PIN_MARK" 60 || fail "boot 2: /data UUID is not the pinned one after swapping disk order"
login
send 'cat /data/anchor.txt'
await "$ANCHOR" 30 || fail "boot 2: /data did NOT follow the pinned UUID across a scan-order swap (anchor lost)"
send 'exit'; sleep 0.3; stop_qemu

echo "PASS: /data is anchored to the cmdline-pinned UUID across a disk-order swap; blank disk formatted as root (V2c acceptance)"
exit 0
