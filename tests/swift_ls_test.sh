#!/usr/bin/env bash
# swift_ls_test.sh — native Swift /bin/ls (with -l) on swift-os.
#
# /bin/ls is a pure-Swift userland tool (userland/ls.swift) built on the kernel
# getdents/stat ABI; `-l` formats mode/owner/group/size, resolving owner and
# group names from /etc/passwd and /etc/group. It is invoked by absolute path so
# the busybox standalone shell execs our binary rather than its own ls applet.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-sls.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sls-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-sls-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

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

await_regex() {  # await_regex REGEX [MAXSEC]
  local regex="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -Eq -- "$regex" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (swift ls driver) ---" >&2
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

# Long format: "mode nlink owner group size YYYY-MM-DD HH:MM name".
D='20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]'

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
printf 'tty-line\n' >&3
await "M7 tty: running; press Ctrl-C" 20 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 60 || drive_fail "timed out waiting for login prompt"
printf 'root\n' >&3
await "Password:" 60 || drive_fail "timed out waiting for password prompt"
printf 'swordfish\n' >&3
await "Welcome to swift-os, root" 60 || drive_fail "root login did not complete"
await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
printf '/bin/ls /etc\n' >&3
await_regex '^motd$' 20 || drive_fail "plain /bin/ls did not list /etc/motd"
printf '/bin/ls -l /etc\n' >&3
await_regex "^-rw-r--r-- +1 +root +root +21 +$D +motd\$" 20 || drive_fail "ls -l did not show /etc/motd"
printf '/bin/ls -l /bin/busybox\n' >&3
await_regex "^-rwxr-xr-x +1 +root +root +[0-9]+ +$D +/bin/busybox\$" 20 || drive_fail "single-file /bin/ls -l did not show busybox"
printf 'exit\n' >&3
await "M12c: session ended" 20 || drive_fail "shell did not exit cleanly"

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
check() { grep -Eq -- "$1" <<<"$clean" || { echo "FAIL: $2" >&2; ok=0; }; }

check '^motd$'                                                 "plain /bin/ls did not list /etc/motd"
check "^drwxr-xr-x +1 +root +root +0 +$D +swos\$"              "ls -l did not show /etc/swos dir (root, drwxr-xr-x)"
check "^-rw-r--r-- +1 +root +root +21 +$D +motd\$"             "ls -l did not show motd (root, -rw-r--r--, size 21)"
check "^-rwxr-xr-x +1 +root +root +[0-9]+ +$D +/bin/busybox\$" "ls -l of a single executable file wrong"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift /bin/ls lists and long-formats with resolved owner/group"
  exit 0
fi
echo "--- serial (ls region) ---" >&2
sed -n '/\/bin\/ls/,$p' <<<"$clean" | head -30 >&2
exit 1
