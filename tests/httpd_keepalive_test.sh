#!/usr/bin/env bash
# httpd_keepalive_test.sh — HTTP/1.0 keep-alive on one accepted socket.
#
# Boots /bin/httpd with hostfwd, then issues TWO sequential GETs on a single
# TCP connection with Connection: keep-alive. Asserts both response bodies and
# that the server advertised keep-alive / logged two 200s (and preferably the
# keep-alive marker). Uses python3 so we control the single-connection path
# (curl may reopen sockets).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_PORT="${HTTPD_KA_HOST_PORT:-$((25000 + ($$ % 20000)))}"
INDEX_MARK="swift-os httpd"
HELLO_MARK="hello from the swift-os static file server"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" || "$ROOT/userland/httpd.swift" -nt "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 not available" >&2
  exit 2
fi

LOG="$(mktemp -t swiftos-httpdka.XXXXXX)"
OUT="$(mktemp -t swiftos-httpdka-out.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-httpdka-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-httpdka-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$OUT" "$PIDFILE" "$INFIFO"' EXIT

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
  echo "--- serial (httpd keep-alive driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${HTTPD_KA_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${HTTPD_KA_SEND_DELAY:-0.08}"
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8080" \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
send_line 'root'
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line '/bin/httpd'

await "httpd: listening on 8080" 120 || drive_fail "httpd never reported listening"

# Two sequential requests on ONE TCP connection (HTTP/1.0 keep-alive).
python3 - "$HOST_PORT" >"$OUT" 2>&1 <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=10)
req1 = (
    "GET / HTTP/1.0\r\n"
    "Host: localhost\r\n"
    "Connection: keep-alive\r\n"
    "\r\n"
)
req2 = (
    "GET /hello.txt HTTP/1.0\r\n"
    "Host: localhost\r\n"
    "Connection: close\r\n"
    "\r\n"
)
s.sendall(req1.encode())
# Read first response until Content-Length body is complete (or timeout).
buf = b""
s.settimeout(8)
while b"\r\n\r\n" not in buf:
    chunk = s.recv(4096)
    if not chunk:
        break
    buf += chunk
# Parse Content-Length of first response.
header, _, rest = buf.partition(b"\r\n\r\n")
clen = 0
for line in header.split(b"\r\n"):
    if line.lower().startswith(b"content-length:"):
        try:
            clen = int(line.split(b":", 1)[1].strip())
        except ValueError:
            clen = 0
while len(rest) < clen:
    chunk = s.recv(4096)
    if not chunk:
        break
    rest += chunk
first = header + b"\r\n\r\n" + rest[:clen]
leftover = rest[clen:]
s.sendall(req2.encode())
second = leftover
while True:
    try:
        chunk = s.recv(4096)
    except socket.timeout:
        break
    if not chunk:
        break
    second += chunk
s.close()
sys.stdout.buffer.write(b"===FIRST===\n")
sys.stdout.buffer.write(first)
sys.stdout.buffer.write(b"\n===SECOND===\n")
sys.stdout.buffer.write(second)
sys.stdout.buffer.write(b"\n===END===\n")
PY

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
out_clean="$(sed 's/\r//' "$OUT")"
ok=1

# Split host-side capture into first/second responses.
first_body="$(awk '/^===FIRST===$/{p=1;next}/^===SECOND===$/{p=0}p' <<<"$out_clean")"
second_body="$(awk '/^===SECOND===$/{p=1;next}/^===END===$/{p=0}p' <<<"$out_clean")"

grep -qF "$INDEX_MARK" <<<"$first_body" \
  || { echo "FAIL: first keep-alive response missing index body" >&2; ok=0; }
grep -qiF "Connection: keep-alive" <<<"$first_body" \
  || { echo "FAIL: first response missing Connection: keep-alive" >&2; ok=0; }
grep -qF "$HELLO_MARK" <<<"$second_body" \
  || { echo "FAIL: second sequential response missing /hello.txt body" >&2; ok=0; }
# Two 200s logged on the guest for the single connection sequence.
served=$(grep -c "httpd: 200" <<<"$clean" || true)
[[ "$served" -ge 2 ]] || { echo "FAIL: server reported $served 200s, expected >= 2" >&2; ok=0; }
grep -qF "httpd: 200 / (keep-alive)" <<<"$clean" \
  || { echo "FAIL: missing keep-alive log marker for first request" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/httpd HTTP/1.0 keep-alive served two sequential requests on one connection"
  exit 0
fi
echo "--- serial (httpd keep-alive) ---" >&2
grep -iE 'httpd:|panic|login:' <<<"$clean" | tail -40 >&2 || true
echo "--- host capture ---" >&2
cat "$OUT" >&2
exit 1
