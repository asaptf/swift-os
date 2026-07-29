#!/usr/bin/env bash
# node_http_test.sh — Node.js in-kernel HTTP server smoke.
# Boots with hostfwd to guest :8080, starts node http.createServer in the
# background, and fetches "ok" from the host with curl.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${NODE_HTTP_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${NODE_HTTP_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="${NODE_DTB:-$ROOT/build/virt-2048.dtb}"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MEM="${NODE_QEMU_MEM:-2048M}"
HOST_PORT="${NODE_HTTP_HOST_PORT:-$((24000 + ($$ % 20000)))}"
READY_MARK="NODE-HTTP-READY"
BODY_MARK="ok"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK"   ]] || { echo "FAIL: $DISK missing (make base-image INCLUDE_NODE=1)" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-node-http.XXXXXX)"
OUT="$(mktemp -t swiftos-node-http-out.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-node-http-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-node-http-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$OUT" "$PIDFILE" "$INFIFO"' EXIT

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
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

NODE_HTTP_JS='require("http").createServer((_,r)=>r.end("ok")).listen(8080,()=>console.log("NODE-HTTP-READY"))'

"$QEMU" -M virt -cpu cortex-a72 -m "$MEM" -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8080" \
  -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "no tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "no tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "no login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "no password prompt"
send_line 'swordfish'
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"

# Background jobs in ash detach stdin; Node PlatformInit needs valid stdio
# fds for fcntl(F_GETFL). Redirect all three before backgrounding.
send_line "/bin/node -e '$NODE_HTTP_JS' </dev/null >>/tmp/node-http.log 2>&1 &"
await "$READY_MARK" 180 || drive_fail "node HTTP server did not report ready"

curl -s -m 8 "http://127.0.0.1:${HOST_PORT}/" >"$OUT" 2>/dev/null || true
exec 3>&-; stop_qemu; QP=""

if grep -qF "$BODY_MARK" "$OUT"; then
  echo "PASS: node http.createServer served ok on :8080"
  exit 0
fi
echo "FAIL: curl body missing '$BODY_MARK'" >&2
echo "--- curl output ---" >&2; cat "$OUT" >&2
echo "--- serial tail ---" >&2
sed 's/\r//' "$LOG" | tail -80 >&2
exit 1