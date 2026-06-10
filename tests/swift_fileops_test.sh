#!/usr/bin/env bash
# swift_fileops_test.sh — native Swift /bin/mkdir, /bin/rmdir, /bin/rm, /bin/mv.
#
# Pure-Swift tmpfs-mutation utilities (userland/{mkdir,rmdir,rm,mv}.swift) over
# the kernel mkdir/unlink/rename/rmdir syscalls. Invoked by absolute path so the
# busybox standalone shell execs our binaries.

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

LOG="$(mktemp -t swiftos-fo.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-fo-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-fo-in.XXXXXX)"; mkfifo "$INFIFO"
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

# Sequence (all under /tmp, the writable tmpfs):
#   mkdir /tmp/d      -> ls shows d
#   echo > /tmp/d/f   -> ls shows f
#   mv f -> g, rm g, rmdir d, then ls /tmp to confirm they are gone.
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
  echo "--- serial (fileops driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/swift-os login:\|\/bin\/mkdir/,$p' >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${FILEOPS_CHAR_DELAY:-0.02}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${FILEOPS_SEND_DELAY:-0.12}"
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
send_line '/bin/mkdir /tmp/d'
await "M11d: exec loaded from disk /bin/mkdir" 40 || drive_fail "mkdir did not execute"
send_line 'echo hi > /tmp/d/f'
send_line 'echo REDIRECT-DONE'
await "REDIRECT-DONE" 40 || drive_fail "redirected echo did not complete"
send_line '/bin/mv /tmp/d/f /tmp/d/g'
await "M11d: exec loaded from disk /bin/mv" 40 || drive_fail "mv did not execute"
send_line '/bin/ls /tmp/d'
await "M11d: exec loaded from disk /bin/ls" 40 || drive_fail "ls /tmp/d did not execute"
await "g" 40 || drive_fail "ls /tmp/d did not show g"
send_line '/bin/cat /tmp/d/g'
await "hi" 40 || drive_fail "cat /tmp/d/g did not print hi"
send_line '/bin/rm /tmp/d/g'
await "M11d: exec loaded from disk /bin/rm" 40 || drive_fail "rm did not execute"
send_line '/bin/rmdir /tmp/d'
await "M11d: exec loaded from disk /bin/rmdir" 40 || drive_fail "rmdir did not execute"
send_line '/bin/ls /tmp'
send_line 'echo FILEOPS-DONE'
await "FILEOPS-DONE" 180 || drive_fail "shell did not survive the file ops"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
# After `mv f g`, ls /tmp/d shows g (and not f).
awk '/M11d: exec loaded from disk \/bin\/ls/{c++; next} c==1&&/^# /{c=0} c==1' <<<"$clean" | grep -qxF "g" \
  || { echo "FAIL: mv did not rename f->g in /tmp/d" >&2; ok=0; }
grep -qxF "hi" <<<"$clean"        || { echo "FAIL: mv did not preserve file content (cat g != hi)" >&2; ok=0; }
# After rm g + rmdir d, ls /tmp must not list d (but keeps the boot-created note).
awk '/M11d: exec loaded from disk \/bin\/ls/{c++; next} c==2&&/^# /{c=0} c==2' <<<"$clean" | grep -qxF "d" \
  && { echo "FAIL: /tmp/d still present after rmdir" >&2; ok=0; }
grep -qxF "FILEOPS-DONE" <<<"$clean" || { echo "FAIL: shell did not survive the file ops" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift mkdir/rmdir/rm/mv mutate the tmpfs correctly"
  exit 0
fi
echo "--- serial (fileops region) ---" >&2
sed -n '/\/bin\/mkdir/,$p' <<<"$clean" | head -40 >&2
exit 1
