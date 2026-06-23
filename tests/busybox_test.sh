#!/usr/bin/env bash
# busybox_test.sh — M8 acceptance: interactive busybox sh runs ls/cat/echo.
#
# Boot order ends with the M7 tty demo then the busybox init shell. We satisfy
# the tty demo (a line + Ctrl-C), then drive busybox: echo, ls /, cat /etc/motd,
# exit. Asserts busybox's banner and each command's output.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-bb.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-bb-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-bb-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  if [[ -n "$QP" ]]; then
    wait "$QP" 2>/dev/null || true
  fi
}
cleanup() {
  stop_qemu
  exec 3>&- 2>/dev/null || true
  rm -f "$LOG" "$PIDFILE" "$INFIFO"
}
trap cleanup EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

# Attach the packed base image (modern virtio-mmio) so the shell and /bin/*
# come off disk.
DISK="$ROOT/build/base.img"
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
blk_args=()
if [[ -f "$DISK" ]]; then
  blk_args=(-global virtio-mmio.force-legacy=false \
            -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
            -device virtio-blk-device,drive=swosbase)
fi

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

await_line() {  # await_line LINE [MAXSEC]
  local line="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -qxF -- "$line" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (busybox driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M7 tty:/,$p' >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${BUSYBOX_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${BUSYBOX_SEND_DELAY:-0.08}"
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 120 || drive_fail "root login did not complete"
await "M12c: shell ready" 30 || drive_fail "busybox ash did not start"
send_line 'echo M8-BUSYBOX-OK'
await_line "M8-BUSYBOX-OK" 20 || drive_fail "echo applet did not respond"
send_line 'ls /'
await "readme.txt" 20 || drive_fail "ls / did not list readme.txt"
send_line 'cat /etc/motd'
await_line "Welcome to swift-os." 20 || drive_fail "cat /etc/motd did not print motd"
send_line 'ps'
await_regex '^ *PID +PPID +STATE +CMD$' 20 || drive_fail "ps output missing"
send_line '/bin/id'
await "principal=1(root) session=1 caps=0x3f" 20 || drive_fail "/bin/id output missing"
send_line 'exit'
await "M12c: session ended" 20 || drive_fail "shell did not exit cleanly"

exec 3>&-
stop_qemu
QP=""

ok=1
clean="$(sed 's/\r//' "$LOG")"
grep -qF "M12c: shell ready" <<<"$clean" || { echo "FAIL: no busybox ash banner" >&2; ok=0; }
grep -qF "M8-BUSYBOX-OK" <<<"$clean"        || { echo "FAIL: echo applet" >&2; ok=0; }
grep -qF "readme.txt" <<<"$clean"           || { echo "FAIL: ls applet (dir listing)" >&2; ok=0; }
grep -qF "Welcome to swift-os." <<<"$clean" || { echo "FAIL: cat applet" >&2; ok=0; }
grep -qE "PID +PPID +STATE +CMD" <<<"$clean" || { echo "FAIL: ps (PATH exec of /bin/ps)" >&2; ok=0; }
grep -qF "principal=1(root) session=1 caps=0x3f" <<<"$clean" || { echo "FAIL: /bin/id (Swift) context + name" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: busybox ash ran echo/ls/cat on swift-os (M8 acceptance)"
  exit 0
fi
echo "--- serial (busybox region) ---" >&2
sed -n '/built-in shell/,$p' <<<"$clean" >&2
exit 1
