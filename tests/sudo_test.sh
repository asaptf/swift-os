#!/usr/bin/env bash
# sudo_test.sh — acceptance: /bin/sudo elevates an authenticated user to root via
# setuid-on-exec rooted in the signed base image.
#
# Boots the packed base image, logs in as `user` (an unprivileged principal,
# caps=0xe, NOT capConsole), and:
#   1. confirms `/bin/id` reports the user context (principal 2);
#   2. runs `sudo id` — sudo (setuid-root) prompts for the user's own password,
#      and on the correct password runs `id` as root (principal 1, caps 0x3f);
#   3. confirms a wrong sudo password is rejected (authentication failure);
#   4. confirms `id` after sudo still reports the unprivileged user (the elevated
#      identity did not leak back into the login shell).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${SUDO_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${SUDO_SEND_DELAY:-0.08}"
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

LOG="$(mktemp -t swiftos-sudo.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-sudo-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-sudo-in.XXXXXX)"; mkfifo "$INFIFO"
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
  echo "--- serial (sudo driver) ---" >&2
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
send_line 'swordfish'
await "Welcome to swift-os, user" 120 || drive_fail "login as user did not succeed"

# Baseline: the login shell is the unprivileged user (principal 2).
await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
send_line '/bin/id'
await "principal=2(user) session=2 caps=0xe" 60 || drive_fail "user shell did not report the user context"

# Wrong sudo password is rejected.
send_line 'sudo id'
await "[sudo] password for user:" 60 || drive_fail "sudo did not prompt for a password"
send_line 'wrongpass'
await "Sorry, try again." 60 || drive_fail "wrong sudo password was not rejected"
# Cancel the remaining retries with EOF-ish empty lines, then a fresh attempt.
send_line ''
send_line ''
await "sudo: authentication failure" 60 || true

# Correct sudo password runs `id` as root (principal 1, full caps).
send_line 'sudo id'
await_count "[sudo] password for user:" 2 60 || drive_fail "sudo did not prompt on the second run"
send_line 'swordfish'
await "principal=1(root) session=1 caps=0x3f" 90 || drive_fail "sudo did not run id as root"

# The login shell identity is unchanged after sudo exits.
send_line '/bin/id'
await_count "principal=2(user) session=2 caps=0xe" 2 60 || drive_fail "elevated identity leaked into the login shell"

send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

ok=1
grep -qF "principal=2(user) session=2 caps=0xe" "$LOG"  || { echo "FAIL: user baseline context missing" >&2; ok=0; }
grep -qF "[sudo] password for user:" "$LOG"             || { echo "FAIL: no sudo password prompt" >&2; ok=0; }
grep -qF "Sorry, try again." "$LOG"                     || { echo "FAIL: wrong sudo password not rejected" >&2; ok=0; }
grep -qF "principal=1(root) session=1 caps=0x3f" "$LOG" || { echo "FAIL: sudo did not elevate id to root" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: sudo elevated an authenticated user to root via setuid-on-exec"
  exit 0
fi
echo "--- serial (sudo region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/swift-os login:/,$p' >&2
exit 1
