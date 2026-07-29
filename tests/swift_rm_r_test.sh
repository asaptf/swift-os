#!/usr/bin/env bash
# swift_rm_r_test.sh — native Swift /bin/rm recursive `-r`/`-R`.
#
# Builds a small tree under /tmp (the writable tmpfs) and exercises the new
# recursive removal in userland/rm.swift: a bare `rm DIR` must refuse (it is a
# directory), while `rm -r DIR` removes the populated tree depth-first. Invoked
# by absolute path so the busybox standalone shell execs our binary.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${RMR_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${RMR_SEND_DELAY:-0.08}"
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

LOG="$(mktemp -t swiftos-rmr.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-rmr-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-rmr-in.XXXXXX)"; mkfifo "$INFIFO"
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
  echo "--- serial (rm-r driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -100 >&2 || true
  exit 1
}


# Sequence (all under /tmp, the writable tmpfs):
#   mkdir /tmp/d, /tmp/d/sub; populate with files at two depths.
#   rm /tmp/d        -> refuses (is a directory); ls /tmp still shows d.
#   rm -r /tmp/d     -> removes the whole tree; ls /tmp no longer shows d.
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

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
send_line '/bin/mkdir /tmp/d'
send_line '/bin/mkdir /tmp/d/sub'
send_line 'echo hi > /tmp/d/f'
send_line 'echo deep > /tmp/d/sub/g'
send_line '/bin/rm /tmp/d'
send_line 'echo RC1=$?'
send_line '/bin/ls /tmp'
send_line '/bin/rm -r /tmp/d'
send_line 'echo RC2=$?'
send_line '/bin/ls /tmp'
send_line 'echo RMR-DONE'
send_line 'exit'
await "RMR-DONE" 180 || drive_fail "shell did not survive the rm-r ops"
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
# Bare `rm /tmp/d` must refuse (directory) and report a non-zero status.
grep -qxF "RC1=0" <<<"$clean" && { echo "FAIL: rm of a directory without -r unexpectedly succeeded" >&2; ok=0; }
grep -q "is a directory" <<<"$clean" || { echo "FAIL: rm did not report 'is a directory'" >&2; ok=0; }
# After the refusal, /tmp/d is still listed.
awk '/M11d: exec loaded from disk \/bin\/ls/{c++; next} c==1&&/^# /{c=0} c==1' <<<"$clean" | grep -qxF "d" \
  || { echo "FAIL: /tmp/d missing after a refused (no -r) rm" >&2; ok=0; }
# `rm -r /tmp/d` succeeds (status 0).
grep -qxF "RC2=0" <<<"$clean" || { echo "FAIL: rm -r did not exit 0" >&2; ok=0; }
# After rm -r, the *second* `ls /tmp` no longer lists d.
awk '/M11d: exec loaded from disk \/bin\/ls/{c++; next} c==2&&/^# /{c=0} c==2' <<<"$clean" | grep -qxF "d" \
  && { echo "FAIL: /tmp/d still present after rm -r" >&2; ok=0; }
grep -qF "RMR-DONE" <<<"$clean" || { echo "FAIL: shell did not survive the rm -r ops" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift rm -r removes a populated directory tree"
  exit 0
fi
echo "--- serial (rm -r region) ---" >&2
sed -n '/\/bin\/mkdir/,$p' <<<"$clean" | head -50 >&2
exit 1
