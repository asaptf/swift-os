#!/usr/bin/env bash
# vfs_disk_test.sh — M11c acceptance: the read-only base FS is served from disk.
#
# Packs a throwaway base image whose /etc/motd carries a UNIQUE marker that does
# not appear anywhere in the kernel's compiled-in literals, attaches it as a
# virtio-blk disk, and drives busybox to `cat /etc/motd` and `ls /`. Seeing the
# marker proves the bytes came off the disk (the M11c extents path), not the
# static fallback tree.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
PACKER="$ROOT/build/basepack"
MARKER="swift-os-DISK-MARKER-M11c"
# I8: the kernel embeds an image-signing trust root and refuses any base image
# that is not signed v3, so this throwaway disk must be signed with the same dev
# image key that `make base-image` mints.
SEED="$ROOT/models/dev-image-signing.seed"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -x "$PACKER" ]]; then
  # Mirror the Makefile $(BASEPACK) rule: basepack now needs packfs plus the
  # crypto sources to emit the signed v3 layout.
  ( cd "$ROOT" && swiftc -O tools/basepack.swift tools/packfs.swift \
      kernel/crypto/sha256.swift kernel/crypto/ed25519.swift kernel/crypto/sha512.swift \
      -o "$PACKER" ) || { echo "FAIL: cannot build basepack" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-vfs.XXXXXX)"
LOG="$(mktemp -t swiftos-vfs.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-vfs-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-vfs-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  if [[ -n "$QP" ]]; then
    wait "$QP" 2>/dev/null || true
  fi
}
cleanup() {
  stop_qemu
  exec 3>&- 2>/dev/null || true
  rm -rf "$WORK" "$LOG" "$PIDFILE" "$INFIFO"
}
trap cleanup EXIT

# Seed tree with a marker motd and an extra file absent from the static tree.
# busybox must be on this disk too: it is the shell, and since M11d the kernel
# loads /bin/busybox only from the packed image (no embedded blob). /bin/ps is
# also needed by the S2b/S2d boot guards, and /bin/coproc feeds the S2g
# coproc-dispatch telemetry guard before init.
mkdir -p "$WORK/seed/etc" "$WORK/seed/bin"
printf '%s\n' "$MARKER" > "$WORK/seed/etc/motd"
printf 'only-on-disk\n'  > "$WORK/seed/diskonly.txt"
[[ -f "$ROOT/build/busybox.elf" ]] || { echo "FAIL: build/busybox.elf missing (make busybox)" >&2; exit 2; }
[[ -f "$ROOT/build/ps.elf" ]] || { echo "FAIL: build/ps.elf missing (make base-image)" >&2; exit 2; }
[[ -f "$ROOT/build/coproc.elf" ]] || { echo "FAIL: build/coproc.elf missing (make build)" >&2; exit 2; }
[[ -f "$SEED" ]] || { echo "FAIL: $SEED missing (make base-image)" >&2; exit 2; }
cp "$ROOT/build/busybox.elf" "$WORK/seed/bin/busybox"
cp "$ROOT/build/ps.elf" "$WORK/seed/bin/ps"
cp "$ROOT/build/coproc.elf" "$WORK/seed/bin/coproc"
IMG="$WORK/disk.img"
"$PACKER" "$WORK/seed" "$IMG" "$SEED" >/dev/null || { echo "FAIL: basepack failed" >&2; exit 2; }

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

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (vfs disk driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M11c:/,$p' >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${VFS_DISK_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${VFS_DISK_SEND_DELAY:-0.08}"
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$IMG,format=raw,if=none,id=disk0,readonly=on" \
  -device virtio-blk-device,drive=disk0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# This throwaway disk intentionally carries only busybox, guard fixtures, and
# test files. With no /bin/ttydemo or /bin/console-login, init falls back
# directly to raw ash. First await after QEMU still covers the full pre-login
# demo boot (role = DEMO_BOOT_TIMEOUT). The readiness marker is busybox's ash
# banner — not "M12c: shell ready", which only console-login emits (absent here).
await "built-in shell (ash)" "$DEMO_BOOT_TIMEOUT" || drive_fail "busybox shell did not start"
send_line 'cat /etc/motd'
await "$MARKER" 60 || drive_fail "/etc/motd marker not read from disk"
send_line 'ls /'
await "diskonly.txt" 60 || drive_fail "disk-only file missing from ls /"
send_line 'cat /diskonly.txt'
await "only-on-disk" 60 || drive_fail "disk-only file contents not read"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

ok=1
grep -qF "M11c: read-only base mounted from disk" "$LOG" || { echo "FAIL: base was not mounted from disk" >&2; ok=0; }
grep -qF "$MARKER" "$LOG"        || { echo "FAIL: /etc/motd marker not read from disk" >&2; ok=0; }
grep -qF "diskonly.txt" "$LOG"   || { echo "FAIL: disk-only file missing from ls /" >&2; ok=0; }
grep -qF "only-on-disk" "$LOG"   || { echo "FAIL: disk-only file contents not read" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: read-only base served from disk (M11c acceptance)"
  exit 0
fi
echo "--- serial (shell region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/built-in shell/,$p' >&2
exit 1
