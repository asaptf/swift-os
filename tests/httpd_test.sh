#!/usr/bin/env bash
# httpd_test.sh — net-e/net-g/net-h2 acceptance: a concurrent static-file HTTP server.
#
# Boots with a slirp NIC that hostfwds host TCP 8080 to the guest. Where host
# QEMU supports IPv6 hostfwd, the server is launched as "/bin/httpd 6" to cover
# the AF_INET6 listener path; Darwin keeps the existing IPv4 hostfwd path because
# QEMU there rejects IPv6 hostfwd literals. /bin/httpd is a poll() loop
# multiplexing the listener + all live connections, serving files from the /www
# docroot on the VFS. The test asserts: two concurrent requests for /index.html
# both return the page (concurrency, net-e), a request for /hello.txt returns its
# content (file serving, net-g) with a text/plain Content-Type (net-h2 MIME
# types), a directory request /sub/ returns a listing containing note.txt (net-h2
# directory listing), and a missing path returns 404.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
INDEX_MARK="swift-os httpd"
HELLO_MARK="hello from the swift-os static file server"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-httpd.XXXXXX)"
O1="$(mktemp -t swiftos-httpd-o1.XXXXXX)"
O2="$(mktemp -t swiftos-httpd-o2.XXXXXX)"
OH="$(mktemp -t swiftos-httpd-oh.XXXXXX)"
OHH="$(mktemp -t swiftos-httpd-ohh.XXXXXX)"   # /hello.txt response headers
OD="$(mktemp -t swiftos-httpd-od.XXXXXX)"     # /sub/ directory listing body
PIDFILE="$(mktemp -t swiftos-httpd-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-httpd-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null; rm -f "$LOG" "$O1" "$O2" "$OH" "$OHH" "$OD" "$PIDFILE" "$INFIFO"' EXIT

USE_V6=0
NETDEV="user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080"
HTTPD_CMD="/bin/httpd"
LISTEN_MARK="httpd: listening on 8080"
URL_ROOT="http://127.0.0.1:8080"
CURL=(curl -s -m 5)
if [[ "$(uname -s)" != "Darwin" ]]; then
  USE_V6=1
  NETDEV="user,id=n0,ipv6=on,hostfwd=tcp:127.0.0.1:8080-:8080,hostfwd=tcp:[::1]:8080-:8080"
  HTTPD_CMD="/bin/httpd 6"
  LISTEN_MARK="httpd: listening on 8080 (IPv6)"
  URL_ROOT="http://[::1]:8080"
  CURL=(curl -g -6 -s -m 5)
fi

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

# await: block until a literal MARKER appears in the serial log (bounded).
await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

BOOT_DRIVE_OK=1
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
    echo "FAIL: did not see boot marker '$marker'" >&2
    BOOT_DRIVE_OK=0
    return 1
  fi
  send_text "$text" || { BOOT_DRIVE_OK=0; return 1; }
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev "$NETDEV" \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

send_after "M7 tty: type a line then Enter" 40 $'tty-line\n' || true
send_after "M7 tty: running; press Ctrl-C" 30 $'\003' || true
send_after "swift-os login:" 40 $'root\n' || true
send_after "Password:" 40 $'swordfish\n' || true
send_after "Welcome to swift-os, root" 40 "${HTTPD_CMD}"$'\n' || true

listening=0
for _ in $(seq 1 60); do
  if grep -qF "$LISTEN_MARK" "$LOG"; then listening=1; break; fi
  sleep 1
done
code404=""
if [[ "$listening" -eq 1 ]]; then
  # Two concurrent requests for the index page.
  "${CURL[@]}" "$URL_ROOT/" > "$O1" 2>/dev/null & p1=$!
  "${CURL[@]}" "$URL_ROOT/index.html" > "$O2" 2>/dev/null & p2=$!
  wait "$p1" "$p2" 2>/dev/null || true
  # A non-index file (body + headers, for the net-h2 Content-Type check).
  "${CURL[@]}" "$URL_ROOT/hello.txt" > "$OH" 2>/dev/null || true
  "${CURL[@]}" -D - -o /dev/null "$URL_ROOT/hello.txt" > "$OHH" 2>/dev/null || true
  # A directory with no index → generated listing (net-h2).
  "${CURL[@]}" "$URL_ROOT/sub/" > "$OD" 2>/dev/null || true
  # A missing path → 404.
  code404="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$URL_ROOT/nope" 2>/dev/null || true)"
fi
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
[[ "$BOOT_DRIVE_OK" -eq 1 ]] || ok=0
[[ "$listening" -eq 1 ]] || { echo "FAIL: /bin/httpd never reported listening marker '$LISTEN_MARK'" >&2; ok=0; }
if [[ "$USE_V6" -eq 1 ]]; then
  grep -qF "net: IPv6 link-local configured" <<<"$clean" \
    || { echo "FAIL: kernel did not configure IPv6 link-local (EUI-64/NDP path with ipv6=on)" >&2; ok=0; }
fi
grep -qF "$INDEX_MARK" "$O1" || { echo "FAIL: first request did not get the index page" >&2; ok=0; }
grep -qF "$INDEX_MARK" "$O2" || { echo "FAIL: second concurrent request did not get the index page" >&2; ok=0; }
grep -qF "$HELLO_MARK" "$OH" || { echo "FAIL: /hello.txt was not served" >&2; ok=0; }
# net-h2: a .txt file must carry a text/plain Content-Type (header match, case-insensitive).
grep -qiF "Content-Type: text/plain" "$OHH" || { echo "FAIL: /hello.txt missing 'Content-Type: text/plain'" >&2; ok=0; }
# net-h2: a directory with no index returns a listing mentioning its entries.
grep -qF "note.txt" "$OD" || { echo "FAIL: /sub/ listing did not contain note.txt" >&2; ok=0; }
[[ "$code404" == "404" ]] || { echo "FAIL: missing path returned '$code404', expected 404" >&2; ok=0; }
served=$(grep -c "httpd: 200" <<<"$clean")
[[ "$served" -ge 2 ]] || { echo "FAIL: server reported $served 200s, expected >= 2" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  if [[ "$USE_V6" -eq 1 ]]; then
    echo "PASS: /bin/httpd (IPv6) served files (typed) + a directory listing from /www, 404 on miss (net-h2 + AF_INET6 path)"
  else
    echo "PASS: /bin/httpd served files (typed) + a directory listing from /www, 404 on miss (net-h2 acceptance)"
  fi
  exit 0
fi
echo "--- serial (httpd + net region) ---" >&2
grep -iE 'httpd:|net: IPv6|panic|abort|login:|M7' <<<"$clean" | tail -30 >&2 || true
echo "--- index (O1) ---" >&2; cat "$O1" >&2
echo "--- hello (OH) ---" >&2; cat "$OH" >&2
echo "--- hello headers (OHH) ---" >&2; cat "$OHH" >&2
echo "--- /sub/ listing (OD) ---" >&2; cat "$OD" >&2
echo "--- 404 code: $code404 ---" >&2
exit 1
