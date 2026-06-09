#!/usr/bin/env bash
# udp_echo_test.sh — net-b acceptance: a native Swift /bin/udpecho round-trip.
#
# Boots with a slirp NIC that hostfwds host UDP 5555 to the guest. After logging
# in, the shell runs /bin/udpecho, which opens a UDP socket (net capability),
# binds 5555, and echoes the first datagram it receives. Once the guest prints
# its "listening" line we send a datagram from the host with `nc -u`, then assert
# both the guest's "got N bytes from …" line and that nc received the echo back —
# exercising the whole path: driver ↔ sans-IO UDP ↔ socket syscalls ↔ bridge ↔
# userland.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MSG="swos-udp"
HOST_PORT="${UDP_ECHO_HOST_PORT:-$((20000 + ($$ % 20000)))}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
command -v nc >/dev/null 2>&1 || { echo "FAIL: nc not found (needed to send the datagram)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-udp.XXXXXX)"
NCOUT="$(mktemp -t swiftos-udp-nc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-udp-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-udp-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
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

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev "user,id=n0,hostfwd=udp:127.0.0.1:${HOST_PORT}-:5555" \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

send_after "M7 tty: type a line then Enter" 60 $'tty-line\n'
send_after "M7 tty: running; press Ctrl-C" 40 $'\003'
send_after "swift-os login:" 60 $'root\n'
send_after "Password:" 40 $'swordfish\n'
send_after "Welcome to swift-os, root" 60 $'/bin/udpecho\n'

# Wait for the guest to bind the socket, then send a datagram from the host.
listening=0
for _ in $(seq 1 40); do
  if grep -qF "udpecho: listening on 5555" "$LOG"; then listening=1; break; fi
  sleep 1
done
if [[ "$listening" -eq 1 ]]; then
  printf '%s' "$MSG" | nc -u -w2 127.0.0.1 "$HOST_PORT" >"$NCOUT" 2>/dev/null || true
fi
sleep 2
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
[[ "$listening" -eq 1 ]] || { echo "FAIL: /bin/udpecho never reported listening" >&2; ok=0; }
grep -Eq "udpecho: got 8 bytes from 10\.0\.2\.2:" <<<"$clean" \
  || { echo "FAIL: guest did not receive the datagram" >&2; ok=0; }
grep -qF "$MSG" "$NCOUT" \
  || { echo "FAIL: host did not receive the echoed datagram back" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/udpecho UDP round-trip over slirp hostfwd (net-b acceptance)"
  exit 0
fi
echo "--- serial (udpecho region) ---" >&2
sed -n '/udpecho:/,$p' <<<"$clean" | head -20 >&2
echo "--- nc output ---" >&2; cat "$NCOUT" >&2
exit 1
