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
  sleep 7;  printf 'tty-line\n'        # M7 ttydemo
  sleep 1;  printf '\003'              # Ctrl-C -> busybox
  sleep 2;  printf '/bin/console-login\n'
  sleep 1;  printf 'user\n'            # wrong password first
  sleep 1;  printf 'wrongpw\n'
  sleep 1;  printf 'user\n'            # then the real one
  sleep 1;  printf 'swordfish\n'
  sleep 2;  printf 'echo LOGGED-IN-SHELL\n'
  sleep 1;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 20
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
