#!/usr/bin/env bash
# data_persist_test.sh — D0 acceptance: the persistent /data disk survives reboot.
#
# Attaches a second, writable virtio-blk disk stamped with the "SWDATAFS" sector-0
# magic and boots the kernel twice against the SAME image. At boot the kernel's D0
# probe reads a boot counter near the start of the data disk, increments it,
# writes it back, and flushes. If persistence works the counter must read 1 on the
# first boot and 2 on the second — proving the write reached stable media and was
# read back across a full reboot (not just kept in RAM/tmpfs).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]]   || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
# The D0 marker is emitted at boot before vfsInit, so a full base image is not
# required to prove persistence. When base.img is present we boot the
# representative base+data config; otherwise we boot data-only (the kernel falls
# back to its static tree). Both reach the D0 probe.
base_args=()
if [[ -f "$BASE_IMG" ]]; then
  base_args=(-drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on"
             -device virtio-blk-device,drive=swosbase)
fi

WORK="$(mktemp -d -t swiftos-data.XXXXXX)"
DATA_IMG="$WORK/data.img"
PIDFILE="$(mktemp -t swiftos-data-pid.XXXXXX)"
QP=""

# A fresh, stamped data disk: 16 MiB of zeros with the "SWDATAFS" magic at byte 0
# so the kernel scan identifies it positively.
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
}
cleanup() { stop_qemu; rm -rf "$WORK" "$PIDFILE"; }
trap cleanup EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

# Boot once against the data disk; print the parsed boot count (or empty). $1=log.
boot_once() {
  local log="$1" n=0
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    ${dtb_args[@]+"${dtb_args[@]}"} \
    ${base_args[@]+"${base_args[@]}"} \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" \
    -device virtio-blk-device,drive=swosdata \
    -kernel "$KERNEL" </dev/null >"$log" 2>&1 &
  QP=$!
  while (( n < 600 )); do
    grep -qF "D0 OK: data disk persistent" "$log" 2>/dev/null && break
    grep -qF "D0: data" "$log" 2>/dev/null && grep -qiE "data (read|write) failed" "$log" 2>/dev/null && break
    sleep 0.1; n=$((n + 1))
  done
  stop_qemu
  sed 's/\r//' "$log" | grep "D0 OK: data disk persistent, boot count" | tail -1 \
    | grep -oE '[0-9]+$' || true
}

LOG1="$WORK/boot1.log"; LOG2="$WORK/boot2.log"
C1="$(boot_once "$LOG1")"
C2="$(boot_once "$LOG2")"

fail() {
  echo "FAIL: $1" >&2
  echo "--- boot 1 (D0 region) ---" >&2; sed 's/\r//' "$LOG1" | grep -E "D0|M11b" >&2 || true
  echo "--- boot 2 (D0 region) ---" >&2; sed 's/\r//' "$LOG2" | grep -E "D0|M11b" >&2 || true
  exit 1
}

grep -qF "D0: data device," "$LOG1" || fail "data disk not discovered on boot 1"
[[ "$C1" == "1" ]] || fail "expected boot count 1 on first boot, got '${C1:-<none>}'"
[[ "$C2" == "2" ]] || fail "expected boot count 2 on second boot (no persistence?), got '${C2:-<none>}'"

echo "PASS: /data disk persists across reboot (D0 acceptance): boot count $C1 -> $C2"
exit 0
