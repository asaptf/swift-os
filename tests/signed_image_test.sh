#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# signed_image_test.sh — negative acceptance for the signed base image (I8).
#
# Case A: a byte flipped inside the SIGNED metadata (the entry table) must make
#         the kernel refuse the disk base at mount ("signature INVALID"), with
#         no "M11c: read-only base mounted from disk" marker.
# Case B: a byte flipped inside a FILE'S PAYLOAD (/etc/motd content) leaves the
#         metadata signature intact, so the image mounts — but the first open
#         of that file fails its signed content hash ("content hash mismatch")
#         while the system keeps booting (fail-closed per file, not per boot).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]] || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not found" >&2; exit 2; }

META_IMG="$(mktemp -t swiftos-sigmeta.XXXXXX)"
DATA_IMG="$(mktemp -t swiftos-sigdata.XXXXXX)"
LOG="$(mktemp -t swiftos-sig.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sig-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-sig-in.XXXXXX)"
mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$META_IMG" "$DATA_IMG" "$LOG" "$PIDFILE" "$INFIFO"' EXIT

# Build the two corrupted copies. Case A flips a byte inside the entry table
# (signed); case B flips the first payload byte of etc/motd (hashed, unsigned
# region), located by parsing the v3 layout.
python3 - "$DISK" "$META_IMG" "$DATA_IMG" <<'EOF'
import struct, sys
src, meta_out, data_out = sys.argv[1:4]
img = bytearray(open(src, 'rb').read())
magic, ver, hsz, esz, cnt = img[0:8], *struct.unpack_from('<IIII', img, 8)
assert magic == b'SWOSBASE' and ver == 3 and esz == 72, (magic, ver, esz)
e_off, s_off, s_sz, d_off, d_sz = struct.unpack_from('<QQQQQ', img, 24)

meta = bytearray(img)
meta[e_off + 8] ^= 0xFF          # corrupt a signed byte (entry 0's kind field)
open(meta_out, 'wb').write(meta)

target = None
for k in range(cnt):
    off = e_off + k * esz
    p_off, p_len, kind = struct.unpack_from('<III', img, off)
    f_off, f_len = struct.unpack_from('<QQ', img, off + 16)
    path = bytes(img[s_off + p_off : s_off + p_off + p_len]).decode()
    if path == 'etc/motd':
        target = (d_off + f_off, f_len)
assert target and target[1] > 0, 'etc/motd not found'
data = bytearray(img)
data[target[0]] ^= 0xFF          # corrupt motd's first content byte
open(data_out, 'wb').write(data)
print(f'corrupted: meta@{e_off+8}, motd payload@{target[0]}')
EOF
[[ $? -eq 0 ]] || { echo "FAIL: could not build corrupted images" >&2; exit 2; }

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

boot_with() { # boot_with <image>  — stdin from the FIFO so we can drive login
  : > "$LOG"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    "${dtb_args[@]}" \
    -drive "file=$1,format=raw,if=none,id=swosbase,readonly=on" \
    -device virtio-blk-device,drive=swosbase \
    -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
  QP=$!
  exec 3<>"$INFIFO"
}

await() {  # await MARKER [MAXSEC]  (override: needs the per-boot reset above)
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# Drive the boot demo past the interactive ttydemo to a root shell.
to_shell() {
  await "M7 tty: type a line then Enter" 60 || return 1
  printf 'tty-line\n' >&3
  await "M7 tty: running; press Ctrl-C" 40 || return 1
  printf '\003' >&3
  await "swift-os login:" 90 || return 1
  printf 'root\n' >&3
  await "Password:" 90 || return 1
  printf 'swordfish\n' >&3
  await "built-in shell (ash)" 120 || return 1
  return 0
}

# --- Case A: tampered metadata -> mount refused -------------------------------
boot_with "$META_IMG"
await "vfs: base image signature INVALID" 60 || fail "tampered metadata was not refused"
if grep -qF "M11c: read-only base mounted from disk" "$LOG"; then
  fail "tampered image was mounted anyway"
fi
exec 3>&-; stop_qemu; QP=""

# --- Case B: tampered payload -> mounts, file rejected on first open ---------
boot_with "$DATA_IMG"
await "base image signature verified (ed25519)" 60 || fail "payload-tampered image did not mount (metadata is intact)"
if to_shell; then
  # Opening the corrupted file trips the lazy content check; cat reports an
  # error but the shell (and OS) keep running — fail-closed per file, not OS-wide.
  printf 'cat /etc/motd\n' >&3
  await "vfs: content hash mismatch" 60 || fail "tampered file content was not rejected"
  printf 'echo IMAGE-B-SURVIVED\n' >&3
  await "IMAGE-B-SURVIVED" 60 || fail "shell did not survive a tampered file"
else
  fail "could not reach a shell on the payload-tampered image"
fi
exec 3>&-; stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: signed base image — tampered metadata refused at mount; tampered content rejected at first open (boot survives)"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | tail -40 >&2
exit 1
