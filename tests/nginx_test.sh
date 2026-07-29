#!/usr/bin/env bash
# nginx_test.sh — W1 acceptance: nginx runs and serves static HTTP on SwiftOS.
#
# Boots the base image (which bakes in /sbin/nginx + a daemon-off, single-process
# config listening on 8080) with a slirp NIC hostfwding host TCP to guest 8080,
# logs in, starts nginx in the background, and fetches the index page from the
# host with curl. Seeing the index marker proves nginx parsed its config, opened
# a listening socket, accepted a connection, and served a file end to end.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
INDEX_MARK="swift-os nginx package"
HOST_PORT="${HOST_PORT:-$(( (RANDOM % 20000) + 20000 ))}"

[[ -f "$KERNEL" ]]   || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-nginx.XXXXXX)"
BODY="$(mktemp -t swiftos-nginx-body.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-nginx-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-nginx-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
cleanup() { stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$BODY" "$PIDFILE" "$INFIFO"; }
trap cleanup EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
send() { printf '%s\n' "$1" >&3; sleep 0.2; }

fail() {
  echo "FAIL: $1" >&2
  echo "--- serial tail (look for nginx [emerg]/[alert]) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -40 >&2 || true
  exit 1
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8080" \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# Log in to a root shell.
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || fail "no tty line prompt"
send 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
printf '\003' >&3; sleep 0.15
await "swift-os login:" 90 || fail "no login prompt"
send 'root'
await "Password:" 90 || fail "no password prompt"
send 'swordfish'
await "Welcome to swift-os, root" 120 || fail "root login did not complete"

# Start nginx in the background (config is daemon off / master_process off).
await_shell_ready "$LOG" 60 || fail "guest shell not reading after login"
send '/sbin/nginx &'
sleep 1
# nginx writes only to its error_log file on success; a startup failure prints to
# stderr (serial). Catch the obvious failure markers early.
if grep -qiE "\[emerg\]|\[alert\]" "$LOG"; then
  fail "nginx reported a fatal startup error"
fi

# Patiently fetch the index from the host (guest gets its slirp IP via DHCP, then
# nginx must be accepting). Retry for a bounded window.
ok=0
for _ in $(seq 1 40); do
  if curl -s -m 5 "http://127.0.0.1:${HOST_PORT}/" -o "$BODY" 2>/dev/null; then
    if grep -qF "$INDEX_MARK" "$BODY"; then ok=1; break; fi
  fi
  sleep 0.5
done

send 'exit' || true
stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: nginx served the static index over HTTP (W1 acceptance) — '$(tr -d '\r\n' < "$BODY" | head -c 60)'"
  exit 0
fi
fail "did not fetch the nginx index marker '$INDEX_MARK' from http://127.0.0.1:${HOST_PORT}/"
