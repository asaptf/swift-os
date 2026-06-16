#!/usr/bin/env bash
# datafs_fsync_test.sh — D2 acceptance: the durable-sync path is wired.
#
# fsync(fd)/fdatasync(fd)/sync() now issue a real virtio-blk cache flush of the
# /data disk (instead of the old no-op fsync stub). This boots the kernel with a
# data disk attached and asserts the post-mount self-test confirms the flush
# mechanism runs ("D2 OK: data sync path ready"). The userland fsync()->SYS_FSYNC
# path is exercised end-to-end by durable SQLite (D3, freshly built against the
# new stubs).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-d2.XXXXXX)"
DATA_IMG="$WORK/data.img"
PIDFILE="$(mktemp -t swiftos-d2-pid.XXXXXX)"
LOG="$WORK/boot.log"
QP=""

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
}
cleanup() { stop_qemu; rm -rf "$WORK" "$PIDFILE"; }
trap cleanup EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
base_args=()
if [[ -f "$BASE_IMG" ]]; then
  base_args=(-drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on"
             -device virtio-blk-device,drive=swosbase)
fi

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  ${dtb_args[@]+"${dtb_args[@]}"} \
  ${base_args[@]+"${base_args[@]}"} \
  -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" \
  -device virtio-blk-device,drive=swosdata \
  -kernel "$KERNEL" </dev/null >"$LOG" 2>&1 &
QP=$!

n=0
while (( n < 600 )); do
  grep -qF "D2 OK: data sync path ready" "$LOG" 2>/dev/null && break
  grep -qF "D2: data flush failed" "$LOG" 2>/dev/null && break
  sleep 0.1; n=$((n + 1))
done
stop_qemu

if grep -qF "D2 OK: data sync path ready" "$LOG"; then
  echo "PASS: $(sed 's/\r//' "$LOG" | grep -F 'D2 OK: data sync path ready' | tail -1)"
  exit 0
fi
echo "FAIL: D2 durable-sync path not confirmed" >&2
sed 's/\r//' "$LOG" 2>/dev/null | grep -E "D0|D1|D2" >&2 || true
exit 1
