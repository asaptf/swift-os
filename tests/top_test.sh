#!/usr/bin/env bash
# top_test.sh — native Swift /bin/top (process/resource monitor).
#
# Boots with the packed base image, logs in as root, and runs `/bin/top -b -n 2`
# (batch mode, two refreshes). Asserts the summary header (uptime, tasks, CPU,
# memory, and the kernel's own footprint), the process-table column header, that
# TWO frames rendered (proving the refresh/%CPU-delta path), and that the shell
# survives top (a trailing marker) — top must restore cleanly and exit.

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

LOG="$(mktemp -t swiftos-top.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-top-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-top-in.XXXXXX)"; mkfifo "$INFIFO"
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

await_regex_count() {  # await_regex_count REGEX COUNT [MAXSEC]
  local regex="$1" want="$2" max="${3:-30}" n=0 got=0
  while (( n < max * 10 )); do
    got="$(sed 's/\r//' "$LOG" 2>/dev/null | grep -Ec -- "$regex" || true)"
    (( got >= want )) && return 0
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
  echo "--- serial (top driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/swift-os login:/,$p' >&2 || true
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

await "M7 tty: type a line then Enter" 40 || drive_fail "timed out waiting for tty line prompt"
send_text $'tty-line\n' || drive_fail "failed to send tty line"
await "M7 tty: running; press Ctrl-C" 30 || drive_fail "timed out waiting for tty Ctrl-C prompt"
send_text $'\003' || drive_fail "failed to send Ctrl-C"
await "swift-os login:" 60 || drive_fail "timed out waiting for login prompt"
send_text $'root\n' || drive_fail "failed to send login"
await "Password:" 60 || drive_fail "timed out waiting for password prompt"
send_text $'swordfish\n' || drive_fail "failed to send password"
await "Welcome to swift-os, root" 60 || drive_fail "root login did not complete"
send_text $'/bin/top -b -n 2 -d 1\n' || drive_fail "failed to send top command"
await_regex_count '^top - up ' 2 40 || drive_fail "top did not render two frames"
send_text $'echo TOP-SHELL-ALIVE\n' || drive_fail "failed to send shell marker"
await_line "TOP-SHELL-ALIVE" 20 || drive_fail "shell did not respond after top"
send_text $'exit\n' || drive_fail "failed to send exit"
await "M12c: session ended" 20 || drive_fail "shell did not exit cleanly"

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
check()  { grep -Eq -- "$1" <<<"$clean" || { echo "FAIL: $2" >&2; ok=0; }; }

# Two frames must have rendered (proves the refresh loop / %CPU delta path).
frames="$(grep -c -- 'top - up ' <<<"$clean" || true)"
[[ "$frames" -ge 2 ]] || { echo "FAIL: expected >=2 top frames, saw $frames" >&2; ok=0; }

check '^top - up [0-9]+:[0-9][0-9]:[0-9][0-9],'      "missing/!malformed uptime header"
check '^Tasks: [0-9]+ total,'                        "missing Tasks summary line"
check '^Cpu: .*busy, .*idle$'                        "missing Cpu busy/idle line"
check '^Mem: +[0-9]+K total,'                        "missing Mem total line"
check '^Kernel: +[0-9]+K image,'                     "missing Kernel image/heap line"
check 'PID +PPID USER +S +%CPU +RES +TIME\+ +COMMAND' "missing process-table column header"
check '/bin/top$'                                    "top did not list its own process row"
check '^TOP-SHELL-ALIVE$'                             "shell did not survive top (no trailing marker)"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/top renders summary + process table over $frames frames"
  exit 0
fi
echo "--- serial (top region) ---" >&2
sed -n '/top - up\|BusyBox\|swift-os login/,$p' <<<"$clean" | head -60 >&2
exit 1
