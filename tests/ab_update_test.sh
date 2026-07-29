#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ab_update_test.sh — acceptance for the A/B update store (U1a): manifest-driven,
# verified slot selection with verified fallback, over a persistent writable
# virtio-blk "update store" disk.
#
# Case A:  manifest active=A → kernel selects slot A, mounts+verifies it, boots.
# Case B:  manifest active=B → kernel selects slot B (placed at a different LBA),
#          mounts+verifies it, boots — proves manifest-driven SELECTION, not
#          "always slot 0".
# Case FB: manifest active=B, but slot B's image has tampered (signed) metadata.
#          The kernel selects slot B, rejects it at Ed25519 verification, and
#          rolls back to the known-good slot A, which mounts and serves files —
#          the verified FALLBACK half of A/B.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${AB_UPDATE_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${AB_UPDATE_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
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

CORRUPT="$(mktemp -t swiftos-ab-corrupt.XXXXXX)"
STORE_A="$(mktemp -t swiftos-ab-a.XXXXXX)"
STORE_B="$(mktemp -t swiftos-ab-b.XXXXXX)"
STORE_FB="$(mktemp -t swiftos-ab-fb.XXXXXX)"
LOG="$(mktemp -t swiftos-ab.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-ab-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-ab-in.XXXXXX)"
mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true;
      rm -f "$CORRUPT" "$STORE_A" "$STORE_B" "$STORE_FB" "$LOG" "$PIDFILE" "$INFIFO"' EXIT

# Build a corrupt copy of the base image: flip a byte inside the SIGNED entry
# table so its Ed25519 signature fails. The magic/header stay valid, so the
# kernel recognises it as a base image and then rejects it at verification.
python3 - "$BASE" "$CORRUPT" <<'EOF'
import struct, sys
src, out = sys.argv[1:3]
img = bytearray(open(src, 'rb').read())
assert img[0:8] == b'SWOSBASE', 'not a SWOSBASE image'
e_off = struct.unpack_from('<Q', img, 24)[0]   # entries_offset
img[e_off + 8] ^= 0xFF                          # corrupt a signed metadata byte
open(out, 'wb').write(img)
EOF
[[ $? -eq 0 ]] || { echo "FAIL: could not build corrupt base image" >&2; exit 2; }

# Two valid slots (A active) and (B active) prove selection; (B active, B bad)
# proves fallback. Slots are full signed base images; the tool packs them into a
# SWOSBOOT store with the chosen active/fallback slots.
"$USTORE" "$STORE_A"  A "$BASE" "$BASE"    >/dev/null || { echo "FAIL: build store A" >&2; exit 2; }
"$USTORE" "$STORE_B"  B "$BASE" "$BASE"    >/dev/null || { echo "FAIL: build store B" >&2; exit 2; }
"$USTORE" "$STORE_FB" B "$BASE" "$CORRUPT" >/dev/null || { echo "FAIL: build store FB" >&2; exit 2; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

boot_with() { # boot_with <store-image> — the store disk is writable (A/B store)
  : > "$LOG"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    "${dtb_args[@]}" \
    -drive "file=$1,format=raw,if=none,id=swosstore" \
    -device virtio-blk-device,drive=swosstore \
    -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
  QP=$!
  exec 3<>"$INFIFO"
}


# Drive the boot demo past the interactive ttydemo to a root shell.
to_shell() {
  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || return 1
  send_line 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || return 1
  printf '\003' >&3
  await "swift-os login:" 90 || return 1
  send_line 'root'
  await "Password:" 90 || return 1
  send_line 'swordfish'
  await "M12c: shell ready" 120 || return 1
  await_shell_ready "$LOG" 60 || return 1
  return 0
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# --- Case A: active slot A selected, verified, mounted, exec works ------------
# The mount markers print at boot (tick 0). Reaching the tty demo proves the
# kernel exec'd /bin/ttydemo from the selected slot (content reads work).
boot_with "$STORE_A"
await "update-store: SWOSBOOT manifest valid, active slot A" 60 || fail "A: slot A not selected"
await "update-store: mounted active slot" 60 || fail "A: active slot not mounted"
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || fail "A: did not exec from slot A"
exec 3>&-; stop_qemu; QP=""

# --- Case B: active slot B selected (a different LBA), verified, mounted ------
boot_with "$STORE_B"
await "update-store: SWOSBOOT manifest valid, active slot B" 60 || fail "B: slot B not selected"
await "update-store: mounted active slot" 60 || fail "B: active slot not mounted"
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || fail "B: did not exec from slot B"
if grep -qF "active slot A" "$LOG"; then fail "B: selected slot A instead of B"; fi
exec 3>&-; stop_qemu; QP=""

# --- Case FB: active slot B is corrupt -> verified fallback to slot A ---------
boot_with "$STORE_FB"
await "update-store: SWOSBOOT manifest valid, active slot B" 60 || fail "FB: slot B not selected"
await "vfs: base image signature INVALID" 60 || fail "FB: corrupt slot B not rejected"
await "rolling back to fallback slot" 60 || fail "FB: did not roll back"
await "update-store: mounted fallback slot" 60 || fail "FB: fallback slot not mounted"
if to_shell; then
  send_line 'cat /etc/motd'
  await "Welcome to swift-os" 60 || fail "FB: fallback slot did not serve /etc/motd"
  send_line 'echo AB-FALLBACK-OK'
  await "AB-FALLBACK-OK" 60 || fail "FB: shell not functional after fallback"
else
  fail "FB: could not reach a shell on the fallback slot"
fi
exec 3>&-; stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: A/B update store — manifest-driven slot selection (A and B) and verified fallback"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | tail -50 >&2
exit 1
