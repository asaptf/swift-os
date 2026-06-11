#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ab_flush_test.sh — U1h acceptance: the kernel negotiates VIRTIO_BLK_F_FLUSH and
# flushes the device write cache after each manifest write, so boot-state is
# durable WITHOUT a cache=writethrough host backend.
#
# Unlike ab_persist_test (which forces cache=writethrough), this boots the SAME
# store with the default write-back cache. It asserts:
#   1. the kernel reports "write durability via virtio FLUSH" (the feature was
#      negotiated at bring-up);
#   2. the boot-attempt counter still persists 1 -> 2 -> 3 across reboots.
# Point (2) also verifies the flush REQUEST succeeds: updateStoreWriteBack treats
# a failed flush as a failed write-back, so a broken/rejected FLUSH would stall
# the counter (no "recorded boot attempt 2") rather than advance it.
#
# Caveat: QEMU writes land in the host OS page cache, which survives a kill, so
# this cannot simulate host power loss — it proves the negotiate+flush+commit
# path is correct under the realistic write-back cache mode, which is the part a
# regression would break.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE="$ROOT/build/base.img"
USTORE="$ROOT/build/updatestore"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE" ]]   || { echo "FAIL: $BASE missing (make base-image)" >&2; exit 2; }
[[ -x "$USTORE" ]] || { echo "FAIL: $USTORE missing (make updatestore)" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

STORE="$(mktemp -t swiftos-abf.XXXXXX)"
LOG="$(mktemp -t swiftos-abf-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-abf-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$STORE" "$LOG" "$PIDFILE"' EXIT

"$USTORE" "$STORE" A "$BASE" "$BASE" >/dev/null || { echo "FAIL: could not build store" >&2; exit 2; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

# Default write-back cache (no cache=writethrough): durability rides on FLUSH.
boot_once() {  # boot_once <attempt-marker>
  : > "$LOG"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    "${dtb_args[@]}" \
    -drive "file=$STORE,format=raw,if=none,id=swosstore,cache=writeback" \
    -device virtio-blk-device,drive=swosstore \
    -kernel "$KERNEL" </dev/null >"$LOG" 2>&1 &
  QP=$!
  local rc=1
  await "$1" 60 && rc=0
  stop_qemu; QP=""
  return $rc
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

boot_once "update-store: recorded boot attempt 1 for active slot A" \
  || fail "boot 1 did not record attempt 1"
grep -qF "update-store: write durability via virtio FLUSH" "$LOG" \
  || fail "kernel did not negotiate VIRTIO_BLK_F_FLUSH"
boot_once "update-store: recorded boot attempt 2 for active slot A" \
  || fail "boot 2 did not persist attempt 2 (flush did not commit the write-back)"
boot_once "update-store: recorded boot attempt 3 for active slot A" \
  || fail "boot 3 did not persist attempt 3 across reboot"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: A/B FLUSH — VIRTIO_BLK_F_FLUSH negotiated; boot-state persists across reboots with a write-back cache"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'update-store|FLUSH|signature|mounted' >&2 | tail -20
exit 1
