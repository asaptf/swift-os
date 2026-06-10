#!/usr/bin/env bash
# cap_enforce_test.sh — M13 acceptance: VFS access is checked against the
# process capability mask.
#
# Logs in as `guest`, whose principal has only capSpawn (no capFsRead /
# capTmpWrite). The shell still runs (exec is a kernel path), and builtins like
# `echo` work, but opening files for read is denied: `cat /etc/motd` and `ls /`
# fail with EACCES. (root/user, which hold capFsRead, are exercised by
# busybox_test, so the allow path is covered there.)

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

LOG="$(mktemp -t swiftos-cap.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-cap-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-cap-in.XXXXXX)"; mkfifo "$INFIFO"
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

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (guest driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/swift-os login:/,$p' >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${CAP_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${CAP_SEND_DELAY:-0.08}"
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

await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'guest'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'guest'
await "session: principal=3 session=3 caps=2" 120 || drive_fail "guest did not log in with the restricted context"
send_line 'echo GUEST-ECHO-OK'
await "GUEST-ECHO-OK" 60 || drive_fail "echo builtin should still work"
send_line 'cat /etc/motd'
await "can't open '/etc/motd'" 60 || drive_fail "reading /etc/motd was not denied"
send_line 'ls /'
await "can't open '/'" 60 || drive_fail "listing / was not denied"
send_line '/bin/id'
await "principal=3 session=3 caps=0x2" 60 || drive_fail "/bin/id did not report the guest context"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

ok=1
grep -qF "session: principal=3 session=3 caps=2" "$LOG" || { echo "FAIL: guest did not log in with the restricted context" >&2; ok=0; }
grep -qF "GUEST-ECHO-OK" "$LOG"        || { echo "FAIL: echo builtin should still work" >&2; ok=0; }
grep -qF "can't open '/etc/motd'" "$LOG" || { echo "FAIL: reading /etc/motd was not denied" >&2; ok=0; }
grep -qF "can't open '/'" "$LOG"      || { echo "FAIL: listing / was not denied" >&2; ok=0; }
# /bin/id (Swift) reports the numeric context even without capFsRead (no name lookup).
grep -qF "principal=3 session=3 caps=0x2" "$LOG" || { echo "FAIL: /bin/id did not report the guest context" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: VFS enforced capabilities — capless guest denied FS reads (M13 acceptance)"
  exit 0
fi
echo "--- serial (guest session) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/principal=3/,$p' >&2
exit 1
