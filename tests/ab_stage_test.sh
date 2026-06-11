#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ab_stage_test.sh — U1f-2b acceptance: /bin/swos-update copies the attached
# read-only payload disk into the INACTIVE A/B slot, and the staged slot is a
# valid, bootable image.
#
# Setup: a store with a VALID active slot A and a deliberately CORRUPT slot B (a
# same-size copy of base.img with one signed-metadata byte flipped, so booting B
# as-is would fail Ed25519 verification). A VALID payload disk (base.img) is
# attached alongside.
#
# Boot 1: boot slot A, reach a root shell, run /bin/swos-update (stages the
#         payload into slot B) then /bin/swos-activate (promotes B for next boot).
# Boot 2: reboot the SAME store. Slot B is now active and — crucially — its image
#         passes Ed25519 verification and mounts. If swos-update had NOT written,
#         B would still be corrupt and the kernel would log "signature INVALID"
#         and fall back to A. A clean verified mount of slot B therefore proves
#         the stage copy wrote a valid image.
#
# cache=writethrough makes the staged bytes + manifest write-back durable across
# the kill+reboot.

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
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not found" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

STORE="$(mktemp -t swiftos-abs.XXXXXX)"
BADB="$(mktemp -t swiftos-abs-badb.XXXXXX)"
LOG="$(mktemp -t swiftos-abs-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-abs-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-abs-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$STORE" "$BADB" "$LOG" "$PIDFILE" "$INFIFO"' EXIT

# Build slot B: a same-size copy of base.img with one SIGNED byte flipped (entry
# 0's kind field, as in signed_image_test) so it fails verification until staged
# over. Same byte length => the store slot is sized to hold the payload exactly.
python3 - "$BASE" "$BADB" <<'EOF'
import struct, sys
src, out = sys.argv[1:3]
img = bytearray(open(src, 'rb').read())
magic, ver, hsz, esz, cnt = img[0:8], *struct.unpack_from('<IIII', img, 8)
assert magic == b'SWOSBASE' and ver == 3, (magic, ver)
e_off = struct.unpack_from('<Q', img, 24)[0]
img[e_off + 8] ^= 0xFF      # corrupt a signed byte
open(out, 'wb').write(img)
EOF
[[ $? -eq 0 ]] || { echo "FAIL: could not build corrupt slot B" >&2; exit 2; }

# Active slot A valid, slot B corrupt (same size as the payload).
"$USTORE" "$STORE" A "$BASE" "$BADB" >/dev/null || { echo "FAIL: could not build store" >&2; exit 2; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

# Store (writable) + payload disk (read-only base.img).
QEMU_DRIVE=(-drive "file=$STORE,format=raw,if=none,id=swosstore,cache=writethrough"
            -device virtio-blk-device,drive=swosstore
            -drive "file=$BASE,format=raw,if=none,id=swospayload,readonly=on"
            -device virtio-blk-device,drive=swospayload)

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

boot_fifo() {
  : > "$LOG"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false "${dtb_args[@]}" "${QEMU_DRIVE[@]}" \
    -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
  QP=$!; exec 3<>"$INFIFO"
}
boot_quiet() {
  : > "$LOG"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false "${dtb_args[@]}" "${QEMU_DRIVE[@]}" \
    -kernel "$KERNEL" </dev/null >"$LOG" 2>&1 &
  QP=$!
}
# Byte-by-byte serial drive (see tests/ab_activate_test.sh).
send() {
  sleep 0.3
  local s="$1" i
  for (( i = 0; i < ${#s}; i++ )); do printf '%s' "${s:i:1}" >&3; sleep 0.03; done
}
to_shell() {
  await "M7 tty: type a line then Enter" 60 || return 1
  send $'tty-line\n'
  await "M7 tty: running; press Ctrl-C" 40 || return 1
  send $'\003'
  await "swift-os login:" 90 || return 1
  send $'root\n'
  await "Password:" 90 || return 1
  send $'swordfish\n'
  await "built-in shell (ash)" 120 || return 1
  return 0
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# --- Boot 1: stage the payload into slot B, then activate it ------------------
boot_fifo
if to_shell; then
  await "update-store: SWOSBOOT manifest valid, active slot A" 30 || fail "boot1: did not boot slot A"
  await "update payload disk present" 30 || fail "boot1: payload disk not discovered"

  # Stage the payload. Re-run on a dropped serial line — update_stage always
  # targets the inactive slot (fixed at boot), so re-staging the same payload is
  # idempotent.
  staged=0
  for _ in 1 2 3 4 5; do
    send $'/bin/swos-update\n'
    if await "update-store: staged payload" 25; then staged=1; break; fi
  done
  [[ "$staged" -eq 1 ]] || fail "boot1: kernel did not stage the payload"
  await "swos-update: payload staged into the inactive slot" 10 || fail "boot1: swos-update program did not confirm"

  # Promote the staged slot for the next boot.
  activated=0
  for _ in 1 2 3 4 5; do
    send $'/bin/swos-activate\n'
    if await "update-store: activated slot B (on trial)" 15; then activated=1; break; fi
  done
  [[ "$activated" -eq 1 ]] || fail "boot1: kernel did not activate slot B"
else
  fail "boot1: could not reach a shell"
fi
exec 3>&-; stop_qemu; QP=""

# --- Boot 2: slot B is active and its STAGED image verifies + mounts ---------
boot_quiet
await "update-store: SWOSBOOT manifest valid, active slot B" 60 || fail "boot2: slot B not active (activate did not persist)"
await "base image signature verified (ed25519)" 60 || fail "boot2: staged slot B image did not verify (stage copy wrote a bad image)"
await "M11c: read-only base mounted from disk" 30 || fail "boot2: staged slot B did not mount"
if grep -qF "vfs: base image signature INVALID" "$LOG"; then
  fail "boot2: slot B failed verification — stage copy did not overwrite the corrupt image"
fi
stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: A/B stage — /bin/swos-update copies the payload into the inactive slot; the staged image verifies and boots"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'update-store|swos-update|swos-activate|signature|M11c' >&2 | tail -25
exit 1
