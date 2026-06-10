#!/usr/bin/env bash
# tcp_connect_test.sh — net-d acceptance: a native Swift /bin/tcpget client.
#
# The guest connects OUT to a host TCP server. QEMU slirp maps 10.0.2.2 to the
# host, so a host `nc -l 5555` is reachable from the guest at 10.0.2.2:5555 with
# no hostfwd. /bin/tcpget connects, sends a request line, reads the reply, prints
# it. We assert both directions:
#   - the guest received the server's reply (host→guest, from the serial log), and
#   - the guest's request bytes appear on the NIC (guest→host) — captured via
#     QEMU's filter-dump pcap, which is deterministic (nc's file output is block-
#     buffered and its exit timing is unreliable, so we don't assert on it).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
PORT="${TCP_CONNECT_HOST_PORT:-$((22000 + ($$ % 20000)))}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
command -v nc >/dev/null 2>&1 || { echo "FAIL: nc not found (needed for the host server)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-tcpc.XXXXXX)"
PCAP="$(mktemp -t swiftos-tcpc-pcap.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-tcpc-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-tcpc-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""; NCPID=""
stop_all() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$NCPID" ]] && kill "$NCPID" 2>/dev/null || true
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_all; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PCAP" "$PIDFILE" "$INFIFO"' EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (tcp connect driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M7 tty:/,$p' >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${TCP_CONNECT_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${TCP_CONNECT_SEND_DELAY:-0.08}"
}

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

# Host TCP server: replies "srv-reply" and holds the connection open (sleep) so
# it stays in ESTABLISHED through the exchange.
( { printf 'srv-reply\n'; sleep 10; } | nc -l "$PORT" >/dev/null 2>&1 ) &
NCPID=$!
disown "$NCPID" 2>/dev/null || true   # silence the job-control "Terminated" notice on cleanup
sleep 0.5

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -object "filter-dump,id=f0,netdev=n0,file=$PCAP" \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 40 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 20 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 60 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 60 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 60 || drive_fail "root login did not complete"
await "built-in shell (ash)" 60 || drive_fail "root shell did not start"
send_line "/bin/tcpget 10.0.2.2 $PORT"
await "srv-reply" 80 || true
stop_all
QP=""; NCPID=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "tcpget: connected" <<<"$clean" || { echo "FAIL: client did not connect" >&2; ok=0; }
grep -qF "srv-reply" <<<"$clean" || { echo "FAIL: client did not receive the server reply" >&2; ok=0; }
strings "$PCAP" 2>/dev/null | grep -qF "GET swos" \
  || { echo "FAIL: client's request was not transmitted on the wire" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/tcpget TCP active open + round-trip to a host server (net-d acceptance)"
  exit 0
fi
echo "--- serial (tcpget region) ---" >&2
sed -n '/tcpget:/,$p' <<<"$clean" | head -20 >&2
echo "--- request on wire? ---" >&2; strings "$PCAP" 2>/dev/null | grep -F "GET swos" >&2
exit 1
