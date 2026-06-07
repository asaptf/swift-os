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
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

(
  sleep 8;    printf 'tty-line\n'
  sleep 1;    printf '\003'
  sleep 3;    printf 'root\n'
  sleep 1.5;  printf 'swordfish\n'
  sleep 3;    printf '/bin/top -b -n 2 -d 1\n'
  sleep 6;    printf 'echo TOP-SHELL-ALIVE\n'
  sleep 2;    printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 34
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
