#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ab_persist_test.sh — U1b acceptance: the kernel DURABLY writes the SWOSBOOT
# boot manifest across reboots. It boots the SAME writable update-store disk
# three times and asserts the active slot's boot-attempt counter increments
# 1 -> 2 -> 3, proving virtio-blk write + atomic double-buffered manifest
# write-back + reboot persistence. (The attempt counter is recorded early at
# vfsInit, before the interactive tty demo, so no login drive is needed.)
#
# cache=writethrough makes each completed guest write durable to the backing
# file, so a subsequent QEMU instance sees the updated manifest even though we
# kill (not gracefully shut down) the previous one.

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

STORE="$(mktemp -t swiftos-abp.XXXXXX)"
LOG="$(mktemp -t swiftos-abp-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-abp-pid.XXXXXX)"
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

boot_once() {  # boot_once <attempt-marker>  — boots the SAME store, waits, kills
  : > "$LOG"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    "${dtb_args[@]}" \
    -drive "file=$STORE,format=raw,if=none,id=swosstore,cache=writethrough" \
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
boot_once "update-store: recorded boot attempt 2 for active slot A" \
  || fail "boot 2 did not persist attempt 2 across reboot"
boot_once "update-store: recorded boot attempt 3 for active slot A" \
  || fail "boot 3 did not persist attempt 3 across reboot"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: A/B update store — boot-attempt counter persists across reboots (1->2->3)"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'update-store|signature|mounted' >&2 | tail -20
exit 1
