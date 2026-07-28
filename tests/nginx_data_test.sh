#!/usr/bin/env bash
# nginx_data_test.sh — W2 acceptance: nginx serves a web root on /data that
# survives reboot.
#
# Boots the base image (bakes /sbin/nginx + nginx-data.conf) with BOTH a writable
# data disk and a slirp NIC. Boot 1 creates the web root + an index page on /data
# and serves it; boot 2 reuses the SAME data disk (no recreating) and serves the
# same page. Fetching the marker after a reboot proves the hosted content lives on
# the durable /data tier, not in RAM.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
CONF="/usr/etc/nginx/nginx-data.conf"
MARK="swiftos-DATA-WWW-PERSIST-8x3k"
HOST_PORT="${HOST_PORT:-$(( (RANDOM % 20000) + 20000 ))}"

[[ -f "$KERNEL" ]]   || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-nginxd.XXXXXX)"
DATA_IMG="$WORK/data.img"
PIDFILE="$(mktemp -t swiftos-nginxd-pid.XXXXXX)"
QP=""; CURLOG=""

dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=32 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  QP=""
  exec 3>&- 2>/dev/null || true
}
cleanup() { stop_qemu; rm -rf "$WORK" "$PIDFILE"; }
trap cleanup EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$CURLOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
send() { printf '%s\n' "$1" >&3; sleep 0.2; }

fail() {
  echo "FAIL: $1" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$CURLOG" 2>/dev/null | tail -40 >&2 || true
  exit 1
}

start_boot() {  # start_boot LOGFILE INFIFO
  local log="$1" fifo="$2"
  rm -f "$fifo"; mkfifo "$fifo"
  CURLOG="$log"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    ${dtb_args[@]+"${dtb_args[@]}"} \
    -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" \
    -device virtio-blk-device,drive=swosbase \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" \
    -device virtio-blk-device,drive=swosdata \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8080" \
    -device virtio-net-device,netdev=n0 \
    -kernel "$KERNEL" <"$fifo" >"$log" 2>&1 &
  QP=$!
  exec 3<>"$fifo"
}

login() {
  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || fail "no tty line prompt"
  send 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
  printf '\003' >&3; sleep 0.15
  await "swift-os login:" 90 || fail "no login prompt"
  send 'root'
  await "Password:" 90 || fail "no password prompt"
  send 'swordfish'
  await "Welcome to swift-os, root" 120 || fail "root login did not complete"
}

curl_marker() {  # returns 0 if the page with MARK is fetched within the window
  local body="$WORK/body.$1" i
  for i in $(seq 1 40); do
    if curl -s -m 5 "http://127.0.0.1:${HOST_PORT}/" -o "$body" 2>/dev/null; then
      grep -qF "$MARK" "$body" && return 0
    fi
    sleep 0.5
  done
  return 1
}

# ---- Boot 1: create the web root on /data and serve it ---------------------
start_boot "$WORK/boot1.log" "$WORK/in1"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 1)"
login
send 'mkdir -p /data/www /data/logs'
send "echo $MARK > /data/www/index.html"
send "/sbin/nginx -c $CONF &"
sleep 1
grep -qiE "\[emerg\]|\[alert\]" "$CURLOG" && fail "nginx fatal error on boot 1"
curl_marker 1 || fail "nginx did not serve /data/www/index.html on boot 1"
send 'exit'; sleep 0.5
stop_qemu

# ---- Boot 2: same data disk, content must persist --------------------------
start_boot "$WORK/boot2.log" "$WORK/in2"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 2)"
login
send "/sbin/nginx -c $CONF &"
sleep 1
grep -qiE "\[emerg\]|\[alert\]" "$CURLOG" && fail "nginx fatal error on boot 2"
curl_marker 2 || fail "/data web root did NOT survive reboot — marker not served on boot 2"
send 'exit'; sleep 0.3
stop_qemu

echo "PASS: nginx served a /data web root that survived reboot (W2 acceptance)"
exit 0
