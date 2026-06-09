#!/usr/bin/env bash
# httpd_test.sh — net-e/net-g/net-h2 acceptance: a concurrent static-file HTTP server.
#
# Boots with a slirp NIC that hostfwds host TCP 8080 to the guest. /bin/httpd is
# a poll() loop multiplexing the listener + all live connections, serving files
# from the /www docroot on the VFS. The test asserts: two concurrent requests for
# /index.html both return the page (concurrency, net-e), a request for /hello.txt
# returns its content (file serving, net-g) with a text/plain Content-Type
# (net-h2 MIME types), a directory request /sub/ returns a listing containing
# note.txt (net-h2 directory listing), and a missing path returns 404.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_PORT="${HTTPD_HOST_PORT:-$((23000 + ($$ % 20000)))}"
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
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$O1" "$O2" "$OH" "$OHH" "$OD" "$PIDFILE"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

(
  sleep 8;   printf 'tty-line\n'
  sleep 1;   printf '\003'
  sleep 3;   printf 'root\n'
  sleep 1.5; printf 'swordfish\n'
  sleep 3;   printf '/bin/httpd\n'
  sleep 22
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8080" \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!

listening=0
for _ in $(seq 1 40); do
  if grep -qF "httpd: listening on 8080" "$LOG"; then listening=1; break; fi
  sleep 1
done
code404=""
if [[ "$listening" -eq 1 ]]; then
  # Two concurrent requests for the index page.
  curl -s -m 5 "http://127.0.0.1:${HOST_PORT}/" > "$O1" 2>/dev/null & p1=$!
  curl -s -m 5 "http://127.0.0.1:${HOST_PORT}/index.html" > "$O2" 2>/dev/null & p2=$!
  wait "$p1" "$p2" 2>/dev/null || true
  # A non-index file (body + headers, for the net-h2 Content-Type check).
  curl -s -m 5 "http://127.0.0.1:${HOST_PORT}/hello.txt" > "$OH" 2>/dev/null || true
  curl -s -m 5 -D - -o /dev/null "http://127.0.0.1:${HOST_PORT}/hello.txt" > "$OHH" 2>/dev/null || true
  # A directory with no index → generated listing (net-h2).
  curl -s -m 5 "http://127.0.0.1:${HOST_PORT}/sub/" > "$OD" 2>/dev/null || true
  # A missing path → 404.
  code404="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}/nope" 2>/dev/null || true)"
fi
sleep 2
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
[[ "$listening" -eq 1 ]] || { echo "FAIL: /bin/httpd never reported listening" >&2; ok=0; }
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
  echo "PASS: /bin/httpd served files (typed) + a directory listing from /www, 404 on miss (net-h2 acceptance)"
  exit 0
fi
echo "--- serial (httpd region) ---" >&2
sed -n '/httpd:/,$p' <<<"$clean" | head -20 >&2
echo "--- index (O1) ---" >&2; cat "$O1" >&2
echo "--- hello (OH) ---" >&2; cat "$OH" >&2
echo "--- hello headers (OHH) ---" >&2; cat "$OHH" >&2
echo "--- /sub/ listing (OD) ---" >&2; cat "$OD" >&2
echo "--- 404 code: $code404 ---" >&2
exit 1
