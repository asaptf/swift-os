#!/usr/bin/env bash
# ipc_socket_transfer_test.sh — C4b endpoint transfer of a socket handle.
#
# Boots with virtio-net + slirp hostfwd, runs /bin/c4b-sockxfer, and sends one
# host UDP datagram to the socket the parent bound and then moved to the child
# over endpoint IPC. The child receives and echoes the datagram through the
# transferred fd; the parent proves its source fd was invalidated.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
PORT=5566
HOST_PORT="${C4B_SOCK_HOST_PORT:-$((25000 + ($$ % 20000)))}"
MSG="c4b-sock"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
command -v nc >/dev/null 2>&1 || { echo "FAIL: nc not found (needed to send the datagram)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-c4b-sock.XXXXXX)"
NCOUT="$(mktemp -t swiftos-c4b-sock-nc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-c4b-sock-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-c4b-sock-in.XXXXXX)"; mkfifo "$INFIFO"
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
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$NCOUT" "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
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
  return 1
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

send_text() {  # send_text TEXT
  local text="$1" i
  for (( i = 0; i < ${#text}; i++ )); do
    printf '%s' "${text:i:1}" >&3 || return 1
    sleep 0.02
  done
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev "user,id=n0,hostfwd=udp:127.0.0.1:${HOST_PORT}-:${PORT}" \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

send_after "M7 tty: type a line then Enter" 60 $'tty-line\n'
send_after "M7 tty: running; press Ctrl-C" 40 $'\003'
send_after "swift-os login:" 60 $'root\n'
send_after "Password:" 40 $'swordfish\n'
send_after "Welcome to swift-os, root" 60 $'/bin/c4b-sockxfer\n'

if await "c4b-sockxfer: listening on 5566" 60; then
  printf '%s' "$MSG" | nc -u -w5 127.0.0.1 "$HOST_PORT" >"$NCOUT" 2>/dev/null || true
fi
send_after "C4b OK: endpoint IPC moved socket handle safely" 60 $'exit\n'

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "c4b-sockxfer: listening on 5566" <<<"$clean" \
  || { echo "FAIL: guest socket transfer demo never listened" >&2; ok=0; }
grep -qF "C4B-SOCKET-XFER-RECV" <<<"$clean" \
  || { echo "FAIL: child did not receive transferred socket handle" >&2; ok=0; }
grep -qF "C4B-SOCKET-MOVE-ONLY-OK err=-9" <<<"$clean" \
  || { echo "FAIL: parent socket fd was not invalidated after transfer" >&2; ok=0; }
grep -qF "C4B-SOCKET-RECV-OK" <<<"$clean" \
  || { echo "FAIL: child did not receive host datagram on transferred socket" >&2; ok=0; }
grep -qF "C4B-SOCKET-ECHO-OK" <<<"$clean" \
  || { echo "FAIL: child did not echo through transferred socket" >&2; ok=0; }
grep -qF "C4b OK: endpoint IPC moved socket handle safely" <<<"$clean" \
  || { echo "FAIL: final C4b marker missing" >&2; ok=0; }
grep -qF "$MSG" "$NCOUT" \
  || { echo "FAIL: host did not receive socket-transfer echo" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: endpoint IPC moved a UDP socket handle and the child echoed a host datagram (C4b acceptance)"
  exit 0
fi
echo "--- serial (c4b-sockxfer region) ---" >&2
sed -n '/c4b-sockxfer\|C4B\|C4b/,$p' <<<"$clean" | head -80 >&2
echo "--- nc output ---" >&2; cat "$NCOUT" >&2
exit 1
