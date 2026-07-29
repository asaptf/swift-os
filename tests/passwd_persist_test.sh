#!/usr/bin/env bash
# passwd_persist_test.sh — K3 acceptance: a password changed via /bin/passwd is
# read by console-login and SURVIVES REBOOT, and the old/default password is then
# rejected (the overlay, not the base default, is authoritative).
#
# Two QEMU boots share ONE persistent data disk:
#   Boot 1: log in as user/swordfish (base default), change it to s3cret, sync.
#   Boot 2 (same data.img, no re-init): user/swordfish is REJECTED, user/s3cret
#           logs in — proving the /data overlay persisted and console-login reads it.
#
# A low PBKDF2 work factor (-i) keeps the emulated run quick. Each boot is retried
# from scratch to ride over transient boot-time shell-exec failures.

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
ITERS="${PASSWD_TEST_ITERS:-4096}"
MAX_BOOTS="${PASSWD_TEST_BOOTS:-5}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

WORK="$(mktemp -d -t swiftos-persist.XXXXXX)"
DATA_IMG="$WORK/data.img"     # shared across both boots (the whole point)
dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null

LOG=""; INFIFO=""; PIDFILE=""; QP=""
cleanup_boot() {
  exec 3>&- 2>/dev/null || true
  if [[ -n "$PIDFILE" && -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  rm -f "$PIDFILE" "$INFIFO" 2>/dev/null || true
}
trap 'cleanup_boot; rm -rf "$WORK" 2>/dev/null || true' EXIT

await() { local m="$1" max="${2:-30}" n=0; while (( n < max*10 )); do grep -qF "$m" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
await_count() { local m="$1" want="$2" max="${3:-30}" n=0 got=0; while (( n < max*10 )); do got="$(grep -cF "$m" "$LOG" 2>/dev/null || true)"; (( got >= want )) && return 0; sleep 0.1; n=$((n+1)); done; return 1; }

reach_login() {  # drive past the boot tty probe to the first login prompt; 2 = boot failed
  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || return 2
  send_line 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || return 2
  printf '\003' >&3
  await "swift-os login:" 90 || return 2
  return 0
}

# Phase 1: change the password to s3cret.   Returns 0 ok · 2 retry boot.
phase1_once() {
  launch
  reach_login || { cleanup_boot; return 2; }
  send_line 'user'
  await "Password:" 90 || { cleanup_boot; return 2; }
  send_line 'swordfish'
  await "Welcome to swift-os, user" 120 || { cleanup_boot; return 2; }
  if await "console-login: exec of shell failed" 8; then cleanup_boot; return 2; fi
  await_shell_ready "$LOG" 60 || { cleanup_boot; return 2; }
  send_line 'echo SHELL-OK'
  await "SHELL-OK" 60 || { cleanup_boot; return 2; }
  send_line "/bin/passwd -i $ITERS"
  await "Current password:" 60 || { cleanup_boot; return 2; }
  send_line 'swordfish'
  await "New password:" 60 || { cleanup_boot; return 2; }
  send_line 's3cret'
  await "Retype new password:" 60 || { cleanup_boot; return 2; }
  send_line 's3cret'
  await "passwd: password updated" 120 || { echo "FAIL: phase1 passwd not committed" >&2; cleanup_boot; return 1; }
  send_line 'sync'      # belt-and-suspenders flush before we cut power
  sleep 1
  cleanup_boot
  return 0
}

# Phase 2: after reboot, old password rejected, new password works. 0 ok · 2 retry · 1 hard fail.
phase2_once() {
  launch
  reach_login || { cleanup_boot; return 2; }
  # Old/default password must now be rejected by the overlay.
  send_line 'user'
  await "Password:" 90 || { cleanup_boot; return 2; }
  send_line 'swordfish'
  await "Login incorrect" 60 || { echo "FAIL: stale/default password was ACCEPTED after reboot" >&2; cleanup_boot; return 1; }
  # New password must work.
  await_count "swift-os login:" 2 60 || { cleanup_boot; return 2; }
  send_line 'user'
  await_count "Password:" 2 90 || { cleanup_boot; return 2; }
  send_line 's3cret'
  await "Welcome to swift-os, user" 120 || { echo "FAIL: new password did NOT work after reboot" >&2; cleanup_boot; return 1; }
  if await "console-login: exec of shell failed" 8; then cleanup_boot; return 2; fi
  await_shell_ready "$LOG" 60 || { cleanup_boot; return 2; }
  send_line 'echo SHELL-OK'
  await "SHELL-OK" 60 || { cleanup_boot; return 2; }
  cleanup_boot
  return 0
}

run_phase() {  # $1 = phase function name, $2 = label
  local fn="$1" label="$2" b rc
  for b in $(seq 1 "$MAX_BOOTS"); do
    echo "$label: boot $b/$MAX_BOOTS ..." >&2
    "$fn"; rc=$?
    [[ "$rc" -eq 0 ]] && return 0
    [[ "$rc" -eq 1 ]] && return 1
    echo "  (boot-time shell-exec race; retrying)" >&2
  done
  echo "FAIL: $label never reached a shell across $MAX_BOOTS boots" >&2
  return 1
}

run_phase phase1_once "phase1(change)" || exit 1
run_phase phase2_once "phase2(reboot-verify)" || exit 1

echo "PASS: password change persisted across reboot; default rejected, new password accepted (K3)"
exit 0
