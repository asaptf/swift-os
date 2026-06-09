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
trap 'stop_qemu; exec 3>&- 2>/dev/null; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

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

await_line() {  # await_line LINE [MAXSEC]
  local line="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -qxF -- "$line" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

send_text() {  # send_text TEXT
  local text="$1" i
  for (( i = 0; i < ${#text}; i++ )); do
    printf '%s' "${text:i:1}" >&3 || return 1
    sleep 0.02
  done
}

send_after() {  # send_after MARKER MAXSEC TEXT
  local marker="$1" max="$2" text="$3"
  if ! await "$marker" "$max"; then
    echo "FAIL: timed out waiting for marker: $marker" >&2
    echo "--- serial tail ---" >&2
    sed 's/\r//' "$LOG" | tail -80 >&2
    exit 1
  fi
  send_text "$text"
}

send_line() {
  send_text "$1"$'\n'
}

abort() {
  echo "FAIL: $1" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$LOG" | tail -80 >&2
  exit 1
}

# Sequence (all under /tmp, the writable tmpfs):
#   mkdir /tmp/d      -> ls shows d
#   echo > /tmp/d/f   -> ls shows f
#   mv f -> g, rm g, rmdir d, then ls /tmp to confirm they are gone.
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

send_after "M7 tty: type a line then Enter" 60 $'tty-line\n'
send_after "M7 tty: running; press Ctrl-C" 40 $'\003'
send_after "swift-os login:" 60 $'root\n'
send_after "Password:" 40 $'swordfish\n'
send_after "Welcome to swift-os, root" 60 ''

send_line "/bin/mkdir /tmp/d; echo FILEOPS''-MKDIR-DONE"
await_line 'FILEOPS-MKDIR-DONE' 30 || abort "mkdir step did not complete"
send_line "echo hi > /tmp/d/f; echo FILEOPS''-WRITE-DONE"
await_line 'FILEOPS-WRITE-DONE' 30 || abort "file write step did not complete"
send_line "/bin/mv /tmp/d/f /tmp/d/g; echo FILEOPS''-MV-DONE"
await_line 'FILEOPS-MV-DONE' 30 || abort "mv step did not complete"
send_line "echo FILEOPS''-LS1-BEGIN; /bin/ls /tmp/d; echo FILEOPS''-LS1-DONE"
await_line 'FILEOPS-LS1-BEGIN' 30 || abort "ls /tmp/d step did not start"
await_line 'g' 30 || abort "ls /tmp/d did not show renamed file"
await_line 'FILEOPS-LS1-DONE' 30 || abort "ls /tmp/d step did not complete"
send_line "echo FILEOPS''-CAT-BEGIN; /bin/cat /tmp/d/g; echo FILEOPS''-CAT-DONE"
await_line 'FILEOPS-CAT-BEGIN' 30 || abort "cat step did not start"
await_line 'hi' 30 || abort "cat /tmp/d/g did not show file content"
await_line 'FILEOPS-CAT-DONE' 30 || abort "cat step did not complete"
send_line "/bin/rm /tmp/d/g; echo FILEOPS''-RM-DONE"
await_line 'FILEOPS-RM-DONE' 30 || abort "rm step did not complete"
send_line "/bin/rmdir /tmp/d; echo FILEOPS''-RMDIR-DONE"
await_line 'FILEOPS-RMDIR-DONE' 30 || abort "rmdir step did not complete"
send_line "echo FILEOPS''-LS2-BEGIN; /bin/ls /tmp; echo FILEOPS''-LS2-DONE"
await_line 'FILEOPS-LS2-BEGIN' 30 || abort "ls /tmp step did not start"
await_line 'FILEOPS-LS2-DONE' 30 || abort "ls /tmp step did not complete"
send_line "echo FILEOPS''-DONE"
await_line 'FILEOPS-DONE' 30 || abort "shell did not survive the file ops"
send_line 'exit'

sleep 1
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
section_between() {
  local begin="$1" end="$2"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { inside = 1; next }
    $0 == end { inside = 0 }
    inside { print }
  ' <<<"$clean"
}
# After `mv f g`, ls /tmp/d shows g (and not f).
section_between "FILEOPS-LS1-BEGIN" "FILEOPS-LS1-DONE" | grep -qxF "g" \
  || { echo "FAIL: mv did not rename f->g in /tmp/d" >&2; ok=0; }
grep -qxF "hi" <<<"$clean"        || { echo "FAIL: mv did not preserve file content (cat g != hi)" >&2; ok=0; }
# After rm g + rmdir d, ls /tmp must not list d (but keeps the boot-created note).
section_between "FILEOPS-LS2-BEGIN" "FILEOPS-LS2-DONE" | grep -qxF "d" \
  && { echo "FAIL: /tmp/d still present after rmdir" >&2; ok=0; }
grep -qxF "FILEOPS-DONE" <<<"$clean" || { echo "FAIL: shell did not survive the file ops" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift mkdir/rmdir/rm/mv mutate the tmpfs correctly"
  exit 0
fi
echo "--- serial (fileops region) ---" >&2
sed -n '/\/bin\/mkdir/,$p' <<<"$clean" | head -40 >&2
exit 1
