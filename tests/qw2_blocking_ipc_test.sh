#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# qw2_blocking_ipc_test.sh — QW2 acceptance: ipc_recv parks on an empty
# endpoint and is woken by ipc_send (or by the last sender closing).
#
# Boots at -smp 4 so a lost cross-CPU wakeup causes the child to hang and the
# await to time out, failing the test.
#
# Markers emitted by /bin/qw2-ipc:
#   QW2-RECV-PARKED  — child reached ipc_recv before any message
#   QW2-RECV-OK <n>  — child received the bytes the parent sent after parking
#   QW2-EOF-OK       — parked receiver woke with errPipe when sender closed
#   QW2 OK           — all scenarios passed

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPU_COUNT="${SMP_CPUS:-4}"
TIMEOUT="${TIMEOUT:-120}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-qw2.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-qw2-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-qw2-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M
  -nographic -no-reboot -pidfile "$PIDFILE"
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

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-$TIMEOUT}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    if [[ -n "$QP" ]] && ! jobs -pr | grep -qx "$QP"; then
      echo "FAIL: QEMU exited while waiting for marker: $marker" >&2
      echo "--- serial tail ---" >&2
      sed 's/\r//' "$LOG" | tail -80 >&2
      exit 1
    fi
    sleep 0.1; n=$((n + 1))
  done
  echo "FAIL: timed out waiting for marker: $marker" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$LOG" | tail -80 >&2
  exit 1
}

send_line() {
  local line="$1" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep 0.02
  done
  printf '\n' >&3
  sleep 0.1
}

# Boot and login.
await "M7 tty: type a line then Enter" 60
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40
printf '\003' >&3
await "swift-os login:" 90
send_line 'root'
await "Password:" 30
send_line 'swordfish'
await "M12c: shell ready" 120

# Run the blocking IPC demo at -smp 4. QW2-RECV-PARKED must appear first
# (child reaches recv before the parent sends), then the recv/EOF results.
send_line '/bin/qw2-ipc'
await "QW2-RECV-PARKED" 30
await "QW2-RECV-OK 5" 30
await "QW2-EOF-OK" 30
await "QW2 OK" 30

send_line 'exit'
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "QW2-RECV-PARKED"  <<<"$clean" || { echo "FAIL: QW2-RECV-PARKED not seen" >&2; ok=0; }
grep -qF "QW2-RECV-OK 5"    <<<"$clean" || { echo "FAIL: QW2-RECV-OK 5 not seen"   >&2; ok=0; }
grep -qF "QW2-EOF-OK"        <<<"$clean" || { echo "FAIL: QW2-EOF-OK not seen"      >&2; ok=0; }
grep -qF "QW2 OK"            <<<"$clean" || { echo "FAIL: QW2 OK not seen"          >&2; ok=0; }

# QW2-RECV-PARKED must precede QW2-RECV-OK (receiver parked before message arrived).
parked_line=$(grep -n "QW2-RECV-PARKED" <<<"$clean" | head -1 | cut -d: -f1)
recvok_line=$(grep -n "QW2-RECV-OK"     <<<"$clean" | head -1 | cut -d: -f1)
if [[ -n "$parked_line" && -n "$recvok_line" && "$parked_line" -ge "$recvok_line" ]]; then
  echo "FAIL: QW2-RECV-PARKED did not precede QW2-RECV-OK in output" >&2
  ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: QW2 blocking IPC — receiver parks and is woken by sender and EOF (smp=$SMP_CPU_COUNT)"
  exit 0
else
  exit 1
fi
