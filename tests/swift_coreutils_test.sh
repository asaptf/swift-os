#!/usr/bin/env bash
# swift_coreutils_test.sh — native Swift /bin/echo, /bin/cat, /bin/pwd.
#
# Pure-Swift coreutils (userland/{echo,cat,pwd}.swift) over the userland bridge.
# Invoked by absolute path so the busybox standalone shell execs our binaries
# (bare echo/cat/pwd stay the busybox builtin/applet).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${COREUTILS_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${COREUTILS_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-cu.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-cu-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-cu-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_line() {  # await_line LINE [MAXSEC]
  local line="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -qxF -- "$line" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (coreutils driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/swift-os login:/,$p' >&2 || true
  exit 1
}


qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -kernel "$KERNEL")
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
send_line '/bin/echo hello swift echo'
await_line "hello swift echo" 60 || drive_fail "/bin/echo did not print its arguments"
send_line '/bin/cat /etc/motd'
await_line "Welcome to swift-os." 60 || drive_fail "/bin/cat did not print /etc/motd"
send_line 'cd /etc'
send_line '/bin/pwd'
await_line "/etc" 60 || drive_fail "/bin/pwd did not print the cwd after cd /etc"
send_line '/bin/echo -n no-newline-here'
await "no-newline-here" 60 || drive_fail "/bin/echo -n did not print marker"
printf '\n' >&3
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
check() { grep -Eq -- "$1" <<<"$clean" || { echo "FAIL: $2" >&2; ok=0; }; }

check '^hello swift echo$'        "/bin/echo did not print its arguments"
check '^Welcome to swift-os\.$'   "/bin/cat did not print /etc/motd"
check '^/etc$'                    "/bin/pwd did not print the cwd after cd /etc"
check 'no-newline-here#'          "/bin/echo -n still emitted a trailing newline"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift echo/cat/pwd work on swift-os"
  exit 0
fi
echo "--- serial (coreutils region) ---" >&2
sed -n '/hello swift echo\|BusyBox/,$p' <<<"$clean" | head -30 >&2
exit 1
