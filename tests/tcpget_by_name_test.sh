#!/usr/bin/env bash
# tcpget_by_name_test.sh — /bin/tcpget connect-by-name acceptance.
#
# Combines the hermetic DNS responder pattern (dns_test.sh) with a host TCP
# server (tcp_connect_test.sh). Guest runs:
#   /bin/tcpget test.swos <port> 10.0.2.2 5354
# which must resolve test.swos → 192.0.2.7 via DNS, then fail to connect to that
# TEST-NET address OR we need the DNS answer to point at the host.
#
# For a real connect round-trip, the DNS A record is the slirp host alias
# 10.0.2.2 so the guest connects back to the host nc listener after resolving
# the *hostname* (not a literal IP on the command line).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
PORT="${TCPGET_BY_NAME_PORT:-$((24000 + ($$ % 20000)))}"
DNSPORT=5354
HOSTNAME="test.swos"
EXPECT_RESOLVED="tcpget: resolved ${HOSTNAME} -> 10.0.2.2"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" || "$ROOT/userland/tcpget.swift" -nt "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 not available (host DNS responder)" >&2
  exit 2
fi
command -v nc >/dev/null 2>&1 || { echo "FAIL: nc not found (needed for the host server)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-tcpgetname.XXXXXX)"
PCAP="$(mktemp -t swiftos-tcpgetname-pcap.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-tcpgetname-pid.XXXXXX)"
PYRESP="$(mktemp -t swiftos-tcpgetname-py.XXXXXX).py"
INFIFO="$(mktemp -u -t swiftos-tcpgetname-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""; PYPID=""; NCPID=""
stop_all() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$PYPID" ]] && kill "$PYPID" 2>/dev/null || true
  [[ -n "$NCPID" ]] && kill "$NCPID" 2>/dev/null || true
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_all; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PCAP" "$PIDFILE" "$PYRESP" "$INFIFO"' EXIT

cat > "$PYRESP" <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 5354))
s.settimeout(120)
try:
    while True:
        data, addr = s.recvfrom(2048)
        if len(data) < 13:
            continue
        tid = data[0:2]
        i = 12
        while i < len(data) and data[i] != 0:
            i += 1 + data[i]
        qend = i + 1 + 4
        question = data[12:qend]
        # Answer A 10.0.2.2 (slirp host alias) so connect reaches the host nc.
        resp = tid + b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00' + question
        resp += b'\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04' + bytes([10, 0, 2, 2])
        s.sendto(resp, addr)
except socket.timeout:
    pass
PY

python3 "$PYRESP" & PYPID=$!
disown "$PYPID" 2>/dev/null || true
sleep 0.3

# Host TCP server reachable as 10.0.2.2:PORT from the guest via slirp.
( { printf 'srv-reply\n'; sleep 15; } | nc -l "$PORT" >/dev/null 2>&1 ) &
NCPID=$!
disown "$NCPID" 2>/dev/null || true
sleep 0.3

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
  echo "--- serial (tcpget-by-name driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M7 tty:/,$p' | tail -80 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${TCPGET_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${TCPGET_SEND_DELAY:-0.08}"
}

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

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

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 60 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 60 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 60 || drive_fail "root login did not complete"
await "M12c: shell ready" 60 || drive_fail "root shell did not start"
# Hostname + port + hermetic DNS at 10.0.2.2:5354 — no literal connect target IP.
send_line "/bin/tcpget ${HOSTNAME} ${PORT} 10.0.2.2 ${DNSPORT}"
await "srv-reply" 90 || true
stop_all
QP=""; PYPID=""; NCPID=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "$EXPECT_RESOLVED" <<<"$clean" \
  || { echo "FAIL: did not resolve hostname via DNS (expected: $EXPECT_RESOLVED)" >&2; ok=0; }
grep -qF "tcpget: connected by name" <<<"$clean" \
  || { echo "FAIL: client did not connect after resolve-by-name" >&2; ok=0; }
grep -qF "srv-reply" <<<"$clean" \
  || { echo "FAIL: client did not receive the server reply" >&2; ok=0; }
# Ensure the command line used a hostname, not a dotted IP as argv[1].
grep -qE "/bin/tcpget ${HOSTNAME} " <<<"$clean" \
  || { echo "FAIL: guest command did not invoke tcpget with hostname" >&2; ok=0; }
strings "$PCAP" 2>/dev/null | grep -qF "GET swos" \
  || { echo "FAIL: client's request was not transmitted on the wire" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/tcpget resolve-by-name + TCP connect round-trip (hostname ${HOSTNAME})"
  exit 0
fi
echo "--- serial (tcpget-by-name region) ---" >&2
sed -n '/tcpget:/,$p' <<<"$clean" | head -30 >&2
echo "--- request on wire? ---" >&2; strings "$PCAP" 2>/dev/null | grep -F "GET swos" >&2 || true
exit 1
