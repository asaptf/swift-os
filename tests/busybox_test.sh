#!/usr/bin/env bash
# busybox_test.sh — M8 acceptance: interactive busybox sh runs ls/cat/echo.
#
# Boot order ends with the M7 tty demo then the busybox init shell. We satisfy
# the tty demo (a line + Ctrl-C), then drive busybox: echo, ls /, cat /etc/motd,
# exit. Asserts busybox's banner and each command's output.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
QEMU="${QEMU:-qemu-system-aarch64}"
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-bb.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

(
  sleep 7;  printf 'tty-line\n'        # M7 ttydemo: a line
  sleep 1;  printf '\003'              # Ctrl-C -> ttydemo exits, busybox starts
  sleep 2;  printf 'echo M8-BUSYBOX-OK\n'
  sleep 1;  printf 'ls /\n'
  sleep 1;  printf 'cat /etc/motd\n'
  sleep 1;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 18
kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null

ok=1
grep -qF "built-in shell (ash)" "$LOG" || { echo "FAIL: no busybox ash banner" >&2; ok=0; }
grep -qF "M8-BUSYBOX-OK" "$LOG"        || { echo "FAIL: echo applet" >&2; ok=0; }
grep -qF "readme.txt" "$LOG"           || { echo "FAIL: ls applet (dir listing)" >&2; ok=0; }
grep -qF "Welcome to swift-os." "$LOG" | true
grep -c "Welcome to swift-os." "$LOG" | grep -qvx 0 || { echo "FAIL: cat applet" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: busybox ash ran echo/ls/cat on swift-os (M8 acceptance)"
  exit 0
fi
echo "--- serial (busybox region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/launching busybox/,$p' >&2
exit 1
