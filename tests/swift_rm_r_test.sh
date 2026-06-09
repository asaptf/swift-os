#!/usr/bin/env bash
# swift_rm_r_test.sh — native Swift /bin/rm recursive `-r`/`-R`.
#
# Builds a small tree under /tmp (the writable tmpfs) and exercises the new
# recursive removal in userland/rm.swift: a bare `rm DIR` must refuse (it is a
# directory), while `rm -r DIR` removes the populated tree depth-first. Invoked
# by absolute path so the busybox standalone shell execs our binary.

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

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (rm -r driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/swift-os login:/,$p' >&2 || true
  exit 1
}

# Sequence (all under /tmp, the writable tmpfs):
#   mkdir /tmp/d, /tmp/d/sub; populate with files at two depths.
#   rm /tmp/d        -> refuses (is a directory); ls /tmp still shows d.
#   rm -r /tmp/d     -> removes the whole tree; ls /tmp no longer shows d.
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 40 || drive_fail "timed out waiting for tty line prompt"
send_text $'tty-line\n' || drive_fail "failed to send tty line"
await "M7 tty: running; press Ctrl-C" 30 || drive_fail "timed out waiting for tty Ctrl-C prompt"
send_text $'\003' || drive_fail "failed to send Ctrl-C"
await "swift-os login:" 60 || drive_fail "timed out waiting for login prompt"
send_text $'root\n' || drive_fail "failed to send login"
await "Password:" 60 || drive_fail "timed out waiting for password prompt"
send_text $'swordfish\n' || drive_fail "failed to send password"
await "Welcome to swift-os, root" 60 || drive_fail "root login did not complete"
await "built-in shell" 15 || drive_fail "busybox shell did not start"
await "# " 15 || drive_fail "shell prompt did not appear"
send_text $'/bin/mkdir /tmp/d\necho MK1\'\'-DONE\n' || drive_fail "failed to send mkdir /tmp/d"
await "MK1-DONE" 20 || drive_fail "mkdir /tmp/d did not complete"
send_text $'/bin/mkdir /tmp/d/sub\necho MK2\'\'-DONE\n' || drive_fail "failed to send mkdir /tmp/d/sub"
await "MK2-DONE" 20 || drive_fail "mkdir /tmp/d/sub did not complete"
send_text $'echo hi > /tmp/d/f\necho WR1\'\'-DONE\n' || drive_fail "failed to write /tmp/d/f"
await "WR1-DONE" 20 || drive_fail "write /tmp/d/f did not complete"
send_text $'echo deep > /tmp/d/sub/g\necho WR2\'\'-DONE\n' || drive_fail "failed to write /tmp/d/sub/g"
await "WR2-DONE" 20 || drive_fail "write /tmp/d/sub/g did not complete"
send_text $'/bin/rm /tmp/d\necho RC1=$?\necho RM1\'\'-DONE\n' || drive_fail "failed to send non-recursive rm"
await "RM1-DONE" 20 || drive_fail "non-recursive rm did not complete"
send_text $'/bin/ls /tmp\necho LS1\'\'-DONE\n' || drive_fail "failed to send first ls"
await "LS1-DONE" 20 || drive_fail "first ls did not complete"
send_text $'/bin/rm -r /tmp/d\necho RC2=$?\necho RM2\'\'-DONE\n' || drive_fail "failed to send recursive rm"
await "RM2-DONE" 20 || drive_fail "recursive rm did not complete"
send_text $'/bin/ls /tmp\necho LS2\'\'-DONE\n' || drive_fail "failed to send second ls"
await "LS2-DONE" 20 || drive_fail "second ls did not complete"
send_text $'echo RMR\'\'-DONE\n' || drive_fail "failed to send done marker"
await_line "RMR-DONE" 20 || drive_fail "shell did not complete the rm -r ops"
send_text $'exit\n' || drive_fail "failed to send exit"
await "M12c: session ended" 20 || drive_fail "shell did not exit cleanly"
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
# Bare `rm /tmp/d` must refuse (directory) and report a non-zero status.
grep -qF "RC1=0" <<<"$clean" && { echo "FAIL: rm of a directory without -r unexpectedly succeeded" >&2; ok=0; }
grep -q "is a directory" <<<"$clean" || { echo "FAIL: rm did not report 'is a directory'" >&2; ok=0; }
# After the refusal, /tmp/d is still listed.
awk '/# \/bin\/ls \/tmp$/{c++} c==1&&/^# \/bin\/ls/{next} c==1&&/^# /{c=2} c==1' <<<"$clean" | grep -qxF "d" \
  || { echo "FAIL: /tmp/d missing after a refused (no -r) rm" >&2; ok=0; }
# `rm -r /tmp/d` succeeds (status 0).
grep -qF "RC2=0" <<<"$clean" || { echo "FAIL: rm -r did not exit 0" >&2; ok=0; }
# After rm -r, the *second* `ls /tmp` no longer lists d.
awk '/# \/bin\/ls \/tmp$/{c++} c==2&&/^# \/bin\/ls/{next} c==2&&/^# /{c=3} c==2' <<<"$clean" | grep -qxF "d" \
  && { echo "FAIL: /tmp/d still present after rm -r" >&2; ok=0; }
grep -qF "RMR-DONE" <<<"$clean" || { echo "FAIL: shell did not survive the rm -r ops" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift rm -r removes a populated directory tree"
  exit 0
fi
echo "--- serial (rm -r region) ---" >&2
sed -n '/\/bin\/mkdir/,$p' <<<"$clean" | head -50 >&2
exit 1
