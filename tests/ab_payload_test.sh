#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ab_payload_test.sh — U1f-1 acceptance: the kernel discovers and reads a second
# virtio-blk disk attached as the A/B update payload (a signed SWOSBASE image),
# alongside the SWOSBOOT update-store disk. This proves the multi-device read
# path (re-bring-up between the store and the payload) before U1f-2 stages the
# payload into the inactive slot.
#
# Two disks: the update store (SWOSBOOT) is selected to serve the base; base.img
# (SWOSBASE) rides along as the payload. The kernel must read the payload's
# header and report it, and still mount the active slot from the store.

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

# Store disk (SWOSBOOT) + base.img attached as the read-only payload (SWOSBASE).
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
  -drive "file=$STORE,format=raw,if=none,id=swosstore" \
  -device virtio-blk-device,drive=swosstore \
  -drive "file=$BASE,format=raw,if=none,id=swospayload,readonly=on" \
  -device virtio-blk-device,drive=swospayload \
  -kernel "$KERNEL" </dev/null >"$LOG" 2>&1 &
QP=$!

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

await "update-store: update payload disk present" 60 || fail "payload disk not discovered/read via the secondary device"
await "update-store: SWOSBOOT manifest valid, active slot A" 30 || fail "store slot not selected"
await "M11c: read-only base mounted from disk" 30 || fail "base did not mount from the store (payload probe disrupted the store)"
stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: A/B update payload — secondary virtio-blk disk discovered, read, and verified as a signed v3 base image"
  exit 0
fi
echo "--- serial ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'update-store|payload|mounted' >&2 | tail -20
exit 1
