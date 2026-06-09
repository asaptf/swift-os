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
INFIFO="$(mktemp -u -t swiftos-lsl-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

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

await_count() {  # await_count MARKER COUNT [MAXSEC]
  local marker="$1" want="$2" max="${3:-30}" n=0 got=0
  while (( n < max * 10 )); do
    got="$(grep -cF "$marker" "$LOG" 2>/dev/null || true)"
    (( got >= want )) && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_regex() {  # await_regex REGEX [MAXSEC]
  local regex="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -Eq -- "$regex" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

send_text() {  # send_text TEXT
  local text="$1" i
  for (( i = 0; i < ${#text}; i++ )); do
    printf '%s' "${text:i:1}" >&3 || return 1
    sleep 0.02
  done
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (ls -l driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/swift-os login:/,$p' >&2 || true
  exit 1
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 40 || drive_fail "timed out waiting for tty line prompt"
send_text $'tty-line\n' || drive_fail "failed to send tty line"
await "M7 tty: running; press Ctrl-C" 30 || drive_fail "timed out waiting for tty Ctrl-C prompt"
send_text $'\003' || drive_fail "failed to send Ctrl-C"
await_count "swift-os login:" 1 60 || drive_fail "timed out waiting for root login prompt"
send_text $'root\n' || drive_fail "failed to send root login"
await_count "Password:" 1 60 || drive_fail "timed out waiting for root password prompt"
send_text $'swordfish\n' || drive_fail "failed to send root password"
await "Welcome to swift-os, root" 60 || drive_fail "root login did not complete"
send_text $'ls -l /\n' || drive_fail "failed to send root ls / command"
await_regex 'drwxr-xr-x +[0-9]+ +root +root .* bin' 20 || drive_fail "root ls -l / did not list /bin"
send_text $'ls -l /bin\n' || drive_fail "failed to send root ls /bin command"
await_regex '-rwxr-xr-x +[0-9]+ +root +root .* busybox' 20 || drive_fail "root ls -l /bin did not list busybox"
send_text $'ls -l /etc\n' || drive_fail "failed to send root ls /etc command"
await_regex '-rw-r--r-- +[0-9]+ +root +root .* motd' 20 || drive_fail "root ls -l /etc did not list motd"
send_text $'exit\n' || drive_fail "failed to send root exit"
await_count "M12c: session ended" 1 60 || drive_fail "root session did not end"
await_count "swift-os login:" 2 60 || drive_fail "timed out waiting for user login prompt"
send_text $'user\n' || drive_fail "failed to send user login"
await_count "Password:" 2 60 || drive_fail "timed out waiting for user password prompt"
send_text $'swordfish\n' || drive_fail "failed to send user password"
await "Welcome to swift-os, user" 60 || drive_fail "user login did not complete"
send_text $'mkdir /tmp/d; ls -l /tmp\n' || drive_fail "failed to send user ls /tmp command"
await_regex 'drwxr-xr-x +[0-9]+ +user +user .* d$' 20 || drive_fail "user ls -l /tmp did not list /tmp/d"
send_text $'exit\n' || drive_fail "failed to send user exit"
await_count "M12c: session ended" 2 60 || drive_fail "user session did not end"

exec 3>&-
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
