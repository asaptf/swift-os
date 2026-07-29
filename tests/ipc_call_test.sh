#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ipc_call_test.sh — QW1 acceptance: synchronous request/reply IPC over a kernel
# reply port (ipc_call / ipc_reply_recv).
#
# Boots at -smp 4 so a lost cross-CPU wakeup (caller parked on a reply port,
# server parked on the endpoint) causes a hang and the await to time out.
#
# Markers emitted by /bin/ipc-call-test:
#   ipc-call: bogus token rejected EINVAL   — forged reply-port token refused
#   ipc-call: reply N correlated            — each reply correlates to its request
#   ipc-call: handle round-tripped          — a handle moved caller->server->caller
#   ipc-call: server-exit gives EPIPE       — caller fails (not hangs) on server death
#   IPC-CALL OK: ...                        — all scenarios passed

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="0.02"
SEND_SEND_DELAY="0.1"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPU_COUNT="${SMP_CPUS:-4}"
TIMEOUT="${TIMEOUT:-120}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-ipc-call.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-ipc-call-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-ipc-call-in.XXXXXX)"; mkfifo "$INFIFO"
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


# Boot and login.
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40
printf '\003' >&3
await "swift-os login:" 90
send_line 'root'
await "Password:" 30
send_line 'swordfish'
await "M12c: shell ready" 120

# Run the synchronous request/reply demo at -smp 4.
await_shell_ready "$LOG" 60 || { echo "FAIL: guest shell not reading after login" >&2; exit 1; }
send_line '/bin/ipc-call-test'
await "ipc-call: bogus token rejected EINVAL" 30
await "ipc-call: reply 1 correlated" 30
await "ipc-call: reply 2 correlated" 30
await "ipc-call: reply 3 correlated" 30
await "ipc-call: handle round-tripped" 30
await "ipc-call: server-exit gives EPIPE" 30
await "IPC-CALL OK" 30

send_line 'exit'
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
for marker in \
  "ipc-call: bogus token rejected EINVAL" \
  "ipc-call: reply 1 correlated" \
  "ipc-call: reply 2 correlated" \
  "ipc-call: reply 3 correlated" \
  "ipc-call: handle round-tripped" \
  "ipc-call: server-exit gives EPIPE" \
  "IPC-CALL OK"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: marker not seen: $marker" >&2; ok=0; }
done

# No mismatch/failure markers, and no kernel panic.
if grep -qE "MISMATCH|FAILED|NOT rejected|did NOT give EPIPE" <<<"$clean"; then
  echo "FAIL: a failure marker was emitted" >&2; ok=0
fi
if grep -qF "panic:" <<<"$clean"; then
  echo "FAIL: kernel panic during the test" >&2; ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: QW1 ipc_call/ipc_reply_recv — correlated replies, handle round-trip, EINVAL/EPIPE (smp=$SMP_CPU_COUNT)"
  exit 0
else
  exit 1
fi
