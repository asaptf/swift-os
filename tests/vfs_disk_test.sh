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
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
PACKER="$ROOT/build/basepack"
MARKER="swift-os-DISK-MARKER-M11c"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -x "$PACKER" ]]; then
  ( cd "$ROOT" && swiftc tools/basepack.swift -o "$PACKER" ) || { echo "FAIL: cannot build basepack" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-vfs.XXXXXX)"
LOG="$(mktemp -t swiftos-vfs.XXXXXX)"
trap 'rm -rf "$WORK" "$LOG"' EXIT

# Seed tree with a marker motd and an extra file absent from the static tree.
mkdir -p "$WORK/seed/etc"
printf '%s\n' "$MARKER" > "$WORK/seed/etc/motd"
printf 'only-on-disk\n'  > "$WORK/seed/diskonly.txt"
IMG="$WORK/disk.img"
"$PACKER" "$WORK/seed" "$IMG" >/dev/null || { echo "FAIL: basepack failed" >&2; exit 2; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

(
  sleep 7;  printf 'tty-line\n'        # satisfy the M7 ttydemo
  sleep 1;  printf '\003'              # Ctrl-C -> busybox starts
  sleep 2;  printf 'cat /etc/motd\n'
  sleep 1;  printf 'ls /\n'
  sleep 1;  printf 'cat /diskonly.txt\n'
  sleep 1;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$IMG,format=raw,if=none,id=disk0" \
  -device virtio-blk-device,drive=disk0 \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 19
kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null

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
