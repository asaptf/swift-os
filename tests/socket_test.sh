#!/usr/bin/env bash
# socket_test.sh - C/newlib fd-flag and TCP socket compatibility probe.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${SOCKET_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${SOCKET_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_GUEST_PORT="${SOCKET_HOST_GUEST_PORT:-$((25000 + ($$ % 15000)))}"
HOST_CLIENT_PORT="${SOCKET_HOST_CLIENT_PORT:-$((41000 + ($$ % 15000)))}"
GUEST_SERVER_PORT="${SOCKET_GUEST_SERVER_PORT:-8087}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-socket.XXXXXX)"
HOST_CLIENT_LOG="$(mktemp -t swiftos-socket-client-host.XXXXXX)"
HOST_SERVER_LOG="$(mktemp -t swiftos-socket-server-host.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-socket-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-socket-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""; PYPID=""

stop_all() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$PYPID" ]] && kill "$PYPID" 2>/dev/null || true
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_all; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$HOST_CLIENT_LOG" "$HOST_SERVER_LOG" "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

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
  echo "--- serial (socket driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  echo "--- host client server ---" >&2
  cat "$HOST_CLIENT_LOG" >&2 2>/dev/null || true
  echo "--- host-to-guest client ---" >&2
  cat "$HOST_SERVER_LOG" >&2 2>/dev/null || true
  exit 1
}


"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_GUEST_PORT}-:${GUEST_SERVER_PORT}" \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"

send_line '/bin/socketprobe flags'
await "SOCKETPROBE-FLAGS-OK" 120 || drive_fail "/bin/socketprobe flags did not report success"

python3 - "$HOST_CLIENT_PORT" >"$HOST_CLIENT_LOG" 2>&1 <<'PY' &
import socket
import sys

port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
s.settimeout(120)
conn, _ = s.accept()
with conn:
    conn.settimeout(30)
    data = conn.recv(1024)
    if data != b"ping-from-guest":
        raise SystemExit(f"unexpected guest payload: {data!r}")
    conn.sendall(b"socketprobe-client-ok")
print("host-client-server-ok", flush=True)
PY
PYPID=$!
sleep 0.3

send_line "/bin/socketprobe client 10.0.2.2 ${HOST_CLIENT_PORT}"
await "SOCKETPROBE-CLIENT-OK" 120 || drive_fail "/bin/socketprobe client did not report success"

send_line "/bin/socketprobe server ${GUEST_SERVER_PORT}"
await "socketprobe: server listening port=${GUEST_SERVER_PORT}" 120 \
  || drive_fail "/bin/socketprobe server did not start listening"

python3 - "$HOST_GUEST_PORT" >"$HOST_SERVER_LOG" 2>&1 <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
last = None
for _ in range(80):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=2)
        break
    except OSError as exc:
        last = exc
        time.sleep(0.1)
else:
    raise SystemExit(f"could not connect to guest server: {last}")
with s:
    s.settimeout(30)
    s.sendall(b"ping-from-host")
    data = s.recv(1024)
    if data != b"socketprobe-server-ok":
        raise SystemExit(f"unexpected guest reply: {data!r}")
print("host-to-guest-ok", flush=True)
PY

await "SOCKETPROBE-SERVER-OK" 120 || drive_fail "/bin/socketprobe server did not report success"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_all
QP=""; PYPID=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
for marker in \
  "socketprobe: pipe2 flags OK" \
  "socketprobe: socket flags OK" \
  "socketprobe: client connected OK" \
  "socketprobe: client exchange OK" \
  "socketprobe: accept4 flags OK" \
  "socketprobe: server exchange OK" \
  "SOCKETPROBE-FLAGS-OK" \
  "SOCKETPROBE-CLIENT-OK" \
  "SOCKETPROBE-SERVER-OK"; do
  if grep -qF "$marker" <<<"$clean"; then
    echo "PASS: $marker"
  else
    echo "FAIL: missing marker: $marker" >&2
    ok=0
  fi
done
grep -qF "host-client-server-ok" "$HOST_CLIENT_LOG" \
  || { echo "FAIL: host TCP server did not observe guest client payload" >&2; ok=0; }
grep -qF "host-to-guest-ok" "$HOST_SERVER_LOG" \
  || { echo "FAIL: host TCP client did not observe guest server reply" >&2; ok=0; }

if (( ok )); then exit 0; fi
echo "--- serial (socketprobe region) ---" >&2
sed -n '/socketprobe/,$p' <<<"$clean" | head -80 >&2
echo "--- host client server ---" >&2
cat "$HOST_CLIENT_LOG" >&2
echo "--- host-to-guest client ---" >&2
cat "$HOST_SERVER_LOG" >&2
exit 1
