#!/usr/bin/env bash
# console_login_test.sh — M12b acceptance: authenticate a principal from the
# base-image identity store and adopt its security context.
#
# Boots with the packed base image (which carries /etc/swos/passwd and
# /bin/console-login), runs console-login from the shell, rejects a wrong
# password, then logs in as `user` and verifies the adopted principal/caps via
# the kernel security_info syscall before the user's shell starts.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${CONSOLE_LOGIN_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${CONSOLE_LOGIN_SEND_DELAY:-0.08}"
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

LOG="$(mktemp -t swiftos-login.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-login-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-login-in.XXXXXX)"; mkfifo "$INFIFO"
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

await_count() {  # await_count MARKER COUNT [MAXSEC]
  local marker="$1" want="$2" max="${3:-30}" n=0 got=0
  while (( n < max * 10 )); do
    got="$(grep -cF "$marker" "$LOG" 2>/dev/null || true)"
    (( got >= want )) && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (login driver) ---" >&2
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

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'user'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'wrongpw'
await "Login incorrect" 60 || drive_fail "wrong password was not rejected"
await_count "swift-os login:" 2 60 || drive_fail "second login prompt did not appear"
send_line 'user'
await_count "Password:" 2 90 || drive_fail "timed out waiting for second password prompt"
send_line 'swordfish'
await "Welcome to swift-os, user" 120 || drive_fail "authentication did not succeed"
send_line 'echo LOGGED-IN-SHELL'
await "LOGGED-IN-SHELL" 60 || drive_fail "user shell did not start"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

ok=1
grep -qF "swift-os login:" "$LOG"               || { echo "FAIL: no login prompt" >&2; ok=0; }
grep -qF "Login incorrect" "$LOG"               || { echo "FAIL: wrong password not rejected" >&2; ok=0; }
grep -qF "Welcome to swift-os, user" "$LOG"      || { echo "FAIL: authentication did not succeed" >&2; ok=0; }
grep -qF "session: principal=2 session=2 caps=14" "$LOG" || { echo "FAIL: security context not adopted from store" >&2; ok=0; }
grep -qF "LOGGED-IN-SHELL" "$LOG"                || { echo "FAIL: user shell did not start" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: console-login authenticated a principal from the base image (M12b acceptance)"
  exit 0
fi
echo "--- serial (login region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/console-login/,$p' >&2
exit 1
