#!/usr/bin/env bash
# ls_l_test.sh — M13c acceptance: file ownership + a real `ls -l` view.
#
# Boots with the packed base image. Logs in as `root` and runs `ls -l` on the
# read-only base: directories are drwxr-xr-x, /bin/* are -rwxr-xr-x, text files
# are -rw-r--r--, all owned by `root` (owner resolved from /etc/passwd, group
# from /etc/group via the compat getpwuid/getgrgid). Then logs in as `user`,
# creates a tmpfs directory with `mkdir`, and `ls -l /tmp` shows it owned by
# `user` — proving the kernel stamps a tmpfs node with the creating principal
# (kernel/vfs/vfs.swift createTmpNode), not always root.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-lsl.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-lsl-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

(
  sleep 8;  printf 'tty-line\n'              # M7 ttydemo
  sleep 1;  printf '\003'                    # Ctrl-C -> login prompt
  sleep 3;  printf 'root\n'
  sleep 1.5;  printf 'swordfish\n'
  sleep 3;  printf 'ls -l /\n'
  sleep 3;  printf 'ls -l /bin\n'
  sleep 3;  printf 'ls -l /etc\n'
  sleep 3;  printf 'exit\n'                   # back to login prompt
  sleep 3;  printf 'user\n'
  sleep 1.5;  printf 'swordfish\n'
  sleep 3;  printf 'mkdir /tmp/d; ls -l /tmp\n'  # tmpfs node owned by the user
  sleep 3;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 52
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
check() { # <regex> <message>
  grep -Eq -- "$1" <<<"$clean" || { echo "FAIL: $2" >&2; ok=0; }
}

# Base (root-owned): dir, executable, and text-file modes all show owner root.
check 'drwxr-xr-x +[0-9]+ +root +root .* bin'        "ls -l / did not show bin as root-owned drwxr-xr-x"
check '-rwxr-xr-x +[0-9]+ +root +root .* busybox'    "ls -l /bin did not show busybox as root-owned -rwxr-xr-x"
check '-rw-r--r-- +[0-9]+ +root +root .* motd'       "ls -l /etc did not show motd as root-owned -rw-r--r--"
# tmpfs directory created by the `user` session is owned by user, not root.
check 'drwxr-xr-x +[0-9]+ +user +user .* d$'         "ls -l /tmp did not show /tmp/d owned by user"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: ls -l shows per-file ownership/mode; tmpfs files owned by creator (M13c acceptance)"
  exit 0
fi
echo "--- serial (ls -l region) ---" >&2
sed -n '/swift-os login:/,$p' <<<"$clean" >&2
exit 1
