#!/usr/bin/env bash
# passwd_change_test.sh — K2 acceptance: /bin/passwd changes the calling
# principal's password, written as a crash-safe overlay on the persistent /data
# tier and read back within the same boot.
#
# Boots the base image WITH a writable data disk attached (datafs mounts /data),
# logs in as `user`/swordfish, then drives /bin/passwd three times:
#   1. swordfish -> hunter2   (first change: writes passwd.0 + prov.0, fsync)
#   2. hunter2   -> hunter3   (ping-pong: proves the new password is read back)
#   3. swordfish -> (denied)  (proves the OLD password is now rejected — the
#                              overlay, not the base default, is authoritative)
# A low PBKDF2 work factor (-i) keeps the emulated run quick.
#
# Whole-boot retry: attaching the data disk makes the console-login shell-exec
# intermittently fail under the boot's concurrent service churn (a pre-existing
# base+data virtio-blk race, also seen by console_login_test + a data disk). The
# failure does not recover within a boot (init restarts compound the leak), so we
# retry the ENTIRE boot from scratch. A passwd-LOGIC failure (wrong read-back,
# stale password accepted) is a hard failure and never retried.

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

# Per-attempt globals (set by boot_attempt).
LOG=""; INFIFO=""; PIDFILE=""; QP=""; DATA_IMG=""; WORK=""

cleanup_attempt() {
  exec 3>&- 2>/dev/null || true
  if [[ -n "$PIDFILE" && -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  rm -rf "$WORK" "$PIDFILE" "$INFIFO" 2>/dev/null || true
}
trap cleanup_attempt EXIT

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

# boot_attempt: launch QEMU, drive login + the three passwd changes.
# Returns: 0 full pass · 2 shell never started (retry the boot) · 1 logic failure (hard).
boot_attempt() {
  WORK="$(mktemp -d -t swiftos-passwd.XXXXXX)"
  DATA_IMG="$WORK/data.img"; LOG="$WORK/boot.log"
  PIDFILE="$(mktemp -t swiftos-passwd-pid.XXXXXX)"
  INFIFO="$(mktemp -u -t swiftos-passwd-in.XXXXXX)"; mkfifo "$INFIFO"; QP=""
  dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=16 2>/dev/null
  printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null

  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    ${dtb_args[@]+"${dtb_args[@]}"} \
    -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
    -device virtio-blk-device,drive=swosbase \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" \
    -device virtio-blk-device,drive=swosdata \
    -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
  QP=$!
  exec 3<>"$INFIFO"

  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || return 2
  send_line 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || return 2
  printf '\003' >&3
  await "swift-os login:" 90 || return 2
  send_line 'user'
  await "Password:" 90 || return 2
  send_line 'swordfish'
  await "Welcome to swift-os, user" 120 || return 2
  # If the shell exec is going to fail, it does so right after "shell ready".
  if await "console-login: exec of shell failed" 8; then return 2; fi
  await_shell_ready "$LOG" 60 || return 2
  send_line 'echo SHELL-OK'
  await "SHELL-OK" 60 || return 2

  # --- from here, failures are real (the shell is up) → hard failure (1) ---

  # Change 1: swordfish -> hunter2.
  send_line "/bin/passwd -i $ITERS"
  await "Current password:" 60 || { echo "FAIL: passwd #1 no prompt" >&2; return 1; }
  send_line 'swordfish'
  await "New password:" 60 || { echo "FAIL: passwd #1 no new-password prompt" >&2; return 1; }
  send_line 'hunter2'
  await "Retype new password:" 60 || { echo "FAIL: passwd #1 no retype prompt" >&2; return 1; }
  send_line 'hunter2'
  await_count "passwd: password updated" 1 120 || { echo "FAIL: passwd #1 not committed" >&2; return 1; }

  # Change 2: hunter2 -> hunter3 (proves the just-written password is read back).
  send_line "/bin/passwd -i $ITERS"
  await_count "Current password:" 2 60 || { echo "FAIL: passwd #2 no prompt" >&2; return 1; }
  send_line 'hunter2'
  await_count "New password:" 2 60 || { echo "FAIL: passwd #2 rejected new password (read-back failed)" >&2; return 1; }
  send_line 'hunter3'
  await_count "Retype new password:" 2 60 || { echo "FAIL: passwd #2 no retype prompt" >&2; return 1; }
  send_line 'hunter3'
  await_count "passwd: password updated" 2 120 || { echo "FAIL: passwd #2 not committed" >&2; return 1; }

  # Change 3: the ORIGINAL password must now be rejected.
  send_line "/bin/passwd -i $ITERS"
  await_count "Current password:" 3 60 || { echo "FAIL: passwd #3 no prompt" >&2; return 1; }
  send_line 'swordfish'
  await "passwd: authentication failure" 120 || { echo "FAIL: stale password was NOT rejected" >&2; return 1; }

  if grep -qF "unable to write credential store" "$LOG"; then
    echo "FAIL: credential store write failed" >&2; return 1
  fi
  return 0
}

rc=2
for boot in $(seq 1 "$MAX_BOOTS"); do
  echo "boot attempt $boot/$MAX_BOOTS ..." >&2
  boot_attempt; rc=$?
  if [[ "$rc" -eq 0 ]]; then break; fi
  if [[ "$rc" -eq 1 ]]; then
    echo "--- serial (passwd region) ---" >&2
    sed 's/\r//' "$LOG" | sed -n '/M12c: shell ready/,$p' | tail -40 >&2
    cleanup_attempt; exit 1
  fi
  echo "  (shell did not start — pre-existing base+data race; retrying a fresh boot)" >&2
  cp "$LOG" "/tmp/k2attempt_${boot}.log" 2>/dev/null || true
  cleanup_attempt
done

if [[ "$rc" -eq 0 ]]; then
  echo "PASS: /bin/passwd committed a crash-safe overlay change and read it back (K2 acceptance)"
  exit 0
fi
echo "FAIL: shell never started across $MAX_BOOTS boots (base+data race)" >&2
exit 1
