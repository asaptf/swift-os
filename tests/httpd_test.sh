#!/usr/bin/env bash
# httpd_test.sh — net-e acceptance: a concurrent poll()-driven HTTP server.
#
# Boots with a slirp NIC that hostfwds host TCP 8080 to the guest. After logging
# in, the shell runs /bin/httpd, a single poll() loop multiplexing the listener
# plus all live connections. Once it prints "listening", we fire TWO concurrent
# host requests and assert both receive the body — proving concurrent serving.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
BODY="Hello from swift-os"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

# Prefer curl; fall back to an nc-built HTTP/1.0 request.
have_curl=0; command -v curl >/dev/null 2>&1 && have_curl=1
[[ "$have_curl" -eq 1 ]] || command -v nc >/dev/null 2>&1 || { echo "FAIL: need curl or nc" >&2; exit 2; }
fetch() { # $1 = output file
  if [[ "$have_curl" -eq 1 ]]; then
    curl -s -m 5 http://127.0.0.1:8080/ > "$1" 2>/dev/null || true
  else
    printf 'GET / HTTP/1.0\r\n\r\n' | nc -w3 127.0.0.1 8080 > "$1" 2>/dev/null || true
  fi
}

LOG="$(mktemp -t swiftos-httpd.XXXXXX)"
O1="$(mktemp -t swiftos-httpd-o1.XXXXXX)"
O2="$(mktemp -t swiftos-httpd-o2.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-httpd-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$O1" "$O2" "$PIDFILE"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

(
  sleep 8;   printf 'tty-line\n'
  sleep 1;   printf '\003'
  sleep 3;   printf 'root\n'
  sleep 1.5; printf 'swordfish\n'
  sleep 3;   printf '/bin/httpd\n'
  sleep 20
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:8080-:8080 \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!

listening=0
for _ in $(seq 1 40); do
  if grep -qF "httpd: listening on 8080" "$LOG"; then listening=1; break; fi
  sleep 1
done
if [[ "$listening" -eq 1 ]]; then
  fetch "$O1" & p1=$!
  fetch "$O2" & p2=$!
  wait "$p1" "$p2" 2>/dev/null || true
fi
sleep 2
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
[[ "$listening" -eq 1 ]] || { echo "FAIL: /bin/httpd never reported listening" >&2; ok=0; }
grep -qF "$BODY" "$O1" || { echo "FAIL: first request did not get the body" >&2; ok=0; }
grep -qF "$BODY" "$O2" || { echo "FAIL: second concurrent request did not get the body" >&2; ok=0; }
served=$(grep -c "httpd: 200 fd" <<<"$clean")
[[ "$served" -ge 2 ]] || { echo "FAIL: server reported $served responses, expected >= 2" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/httpd served two concurrent HTTP requests (net-e acceptance)"
  exit 0
fi
echo "--- serial (httpd region) ---" >&2
sed -n '/httpd:/,$p' <<<"$clean" | head -20 >&2
echo "--- response 1 ---" >&2; cat "$O1" >&2
echo "--- response 2 ---" >&2; cat "$O2" >&2
exit 1
