#!/usr/bin/env bash
# swift_chmodown_test.sh — native Swift /bin/chmod and /bin/chown.
#
# Changes mode/owner of a tmpfs file and confirms via /bin/ls -l. chmod/chown
# only affect the writable tmpfs (the base FS is read-only) and require
# capTmpWrite. Invoked by absolute path so the busybox shell execs our binaries.

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

LOG="$(mktemp -t swiftos-cm.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-cm-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-cm-in.XXXXXX)"; mkfifo "$INFIFO"
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
  echo "--- serial (chmod/chown driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -80 >&2 || true
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

await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
printf 'tty-line\n' >&3
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
printf 'root\n' >&3
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
printf 'swordfish\n' >&3
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"
printf 'echo hi > /tmp/f\n' >&3
await "echo hi > /tmp/f" 60 || drive_fail "shell did not accept file creation command"
printf '/bin/chmod 600 /tmp/f\n' >&3
await "M11d: exec loaded from disk /bin/chmod" 60 || drive_fail "chmod did not execute"
printf '/bin/ls -l /tmp/f\n' >&3
await_regex '^-rw------- +1 +root +root +3 +' 60 || drive_fail "chmod 600 was not reflected"
printf '/bin/chown 2 /tmp/f\n' >&3
await "M11d: exec loaded from disk /bin/chown" 60 || drive_fail "chown did not execute"
printf '/bin/ls -l /tmp/f\n' >&3
await_regex '^-rw------- +1 +user +user +3 +' 60 || drive_fail "chown 2 was not reflected"
printf 'echo CHOWN-DONE\n' >&3
await "CHOWN-DONE" 180 || drive_fail "shell did not survive chmod/chown"
printf 'exit\n' >&3
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
check() { grep -Eq -- "$1" <<<"$clean" || { echo "FAIL: $2" >&2; ok=0; }; }

D='20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]'
check "^-rw------- +1 +root +root +3 +$D +/tmp/f\$"  "chmod 600 not reflected (expected -rw------- root)"
check "^-rw------- +1 +user +user +3 +$D +/tmp/f\$"  "chown 2 not reflected (expected owner/group user)"
check 'CHOWN-DONE'                                   "shell did not survive chmod/chown"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift chmod/chown change tmpfs mode and owner (shown by ls -l)"
  exit 0
fi
echo "--- serial (chmod/chown region) ---" >&2
sed -n '/chmod/,$p' <<<"$clean" | head -30 >&2
exit 1
