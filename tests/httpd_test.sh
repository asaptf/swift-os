#!/usr/bin/env bash
# httpd_test.sh — net-e/net-g/net-h2 acceptance: a concurrent static-file HTTP server.
#
# Boots with a slirp NIC that hostfwds host TCP to guest port 8080. /bin/httpd is
# a poll() loop multiplexing the listener + all live connections, serving files
# from the /www docroot on the VFS. On QEMU builds that accept
# `hostfwd=tcp:[::1]...`, set HTTPD_IPV6_HOSTFWD=1 to launch `/bin/httpd 6` and
# drive the AF_INET6 listener with curl -6. Darwin QEMU rejects that hostfwd form,
# so the default remains the portable IPv4 hostfwd acceptance path.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_PORT="${HTTPD_HOST_PORT:-$((23000 + ($$ % 20000)))}"
INDEX_MARK="swift-os httpd"
HELLO_MARK="hello from the swift-os static file server"
HTTPD_IPV6_HOSTFWD="${HTTPD_IPV6_HOSTFWD:-}"
if [[ -z "$HTTPD_IPV6_HOSTFWD" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    HTTPD_IPV6_HOSTFWD=0
  else
    HTTPD_IPV6_HOSTFWD=1
  fi
fi

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-httpd.XXXXXX)"
O1="$(mktemp -t swiftos-httpd-o1.XXXXXX)"
O2="$(mktemp -t swiftos-httpd-o2.XXXXXX)"
OH="$(mktemp -t swiftos-httpd-oh.XXXXXX)"
OHH="$(mktemp -t swiftos-httpd-ohh.XXXXXX)"   # /hello.txt response headers
OD="$(mktemp -t swiftos-httpd-od.XXXXXX)"     # /sub/ directory listing body
PIDFILE="$(mktemp -t swiftos-httpd-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-httpd-in.XXXXXX)"
mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$O1" "$O2" "$OH" "$OHH" "$OD" "$PIDFILE" "$INFIFO"' EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

# await: block until a literal MARKER appears in the serial log (bounded).
# (Robust pattern from ipv6_*_test.sh to avoid fixed-sleep flakes under ipv6=on.)
await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (httpd driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${HTTPD_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${HTTPD_SEND_DELAY:-0.08}"
}

# Boot QEMU driven via FIFO (fd 3) for reactive input.
netdev_arg="user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8080"
httpd_cmd="/bin/httpd"
listen_marker="httpd: listening on 8080"
base_url="http://127.0.0.1:${HOST_PORT}"
curl_args=(-s -m 5)
pass_label="IPv4"
if [[ "$HTTPD_IPV6_HOSTFWD" == "1" ]]; then
  netdev_arg="user,id=n0,ipv6=on,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8080,hostfwd=tcp:[::1]:${HOST_PORT}-:8080"
  httpd_cmd="/bin/httpd 6"
  listen_marker="httpd: listening on 8080 (IPv6)"
  base_url="http://[::1]:${HOST_PORT}"
  curl_args=(-g -6 -s -m 5)
  pass_label="IPv6"
fi
qemu_args+=(
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev "$netdev_arg"
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL"
)
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
send_line 'root'
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"
send_line "$httpd_cmd"

listening=0
await "$listen_marker" 120 && listening=1
code404=""
if [[ "$listening" -eq 1 ]]; then
  # Two concurrent requests for the index page.
  curl "${curl_args[@]}" "${base_url}/" > "$O1" 2>/dev/null & p1=$!
  curl "${curl_args[@]}" "${base_url}/index.html" > "$O2" 2>/dev/null & p2=$!
  wait "$p1" "$p2" 2>/dev/null || true
  # A non-index file (body + headers, for the net-h2 Content-Type check).
  curl "${curl_args[@]}" "${base_url}/hello.txt" > "$OH" 2>/dev/null || true
  curl "${curl_args[@]}" -D - -o /dev/null "${base_url}/hello.txt" > "$OHH" 2>/dev/null || true
  # A directory with no index → generated listing (net-h2).
  curl "${curl_args[@]}" "${base_url}/sub/" > "$OD" 2>/dev/null || true
  # A missing path → 404.
  code404="$(curl "${curl_args[@]}" -o /dev/null -w '%{http_code}' "${base_url}/nope" 2>/dev/null || true)"
fi
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
[[ "$listening" -eq 1 ]] || { echo "FAIL: /bin/httpd never reported listening ($pass_label)" >&2; ok=0; }
if [[ "$HTTPD_IPV6_HOSTFWD" == "1" ]]; then
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
  echo "PASS: /bin/httpd ($pass_label) served files (typed) + a directory listing from /www, 404 on miss"
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
