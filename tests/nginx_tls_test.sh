#!/usr/bin/env bash
# nginx_tls_test.sh — W3 acceptance: nginx serves HTTPS (TLS) on SwiftOS.
#
# Boots the base image (bakes /sbin/nginx built with the OpenSSL port +
# nginx-tls.conf + a self-signed cert) with a slirp NIC hostfwding host TCP to
# guest 8443, logs in, starts nginx with the TLS config, and fetches the index
# over HTTPS with curl -k. A successful TLS handshake + served page proves the
# static OpenSSL link works and the in-kernel TCP carries TLS records end to end.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
INDEX_MARK="swift-os nginx package"
HOST_PORT="${HOST_PORT:-$(( (RANDOM % 20000) + 20000 ))}"

[[ -f "$KERNEL" ]]   || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-nginxtls.XXXXXX)"
BODY="$(mktemp -t swiftos-nginxtls-body.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-nginxtls-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-nginxtls-in.XXXXXX)"; mkfifo "$INFIFO"
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

await() { local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do grep -qF "$marker" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done
  return 1; }
send() { printf '%s\n' "$1" >&3; sleep 0.2; }
fail() { echo "FAIL: $1" >&2; echo "--- serial tail ---" >&2; sed 's/\r//' "$LOG" 2>/dev/null | tail -40 >&2 || true; exit 1; }

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8443" \
  -device virtio-net-device,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 \
  -device virtio-rng-device,rng=rng0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || fail "no tty line prompt"
send 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
printf '\003' >&3; sleep 0.15
await "swift-os login:" 90 || fail "no login prompt"
send 'root'
await "Password:" 90 || fail "no password prompt"
send 'swordfish'
await "Welcome to swift-os, root" 120 || fail "root login did not complete"

send '/sbin/nginx -c /usr/etc/nginx/nginx-tls.conf &'
sleep 3
grep -qiE "\[emerg\]|\[alert\]" "$LOG" && fail "nginx fatal error starting TLS server"

ok=0
for _ in $(seq 1 30); do
  if curl -k -s -m 8 "https://127.0.0.1:${HOST_PORT}/" -o "$BODY" 2>"$BODY.err"; then
    grep -qF "$INDEX_MARK" "$BODY" && { ok=1; break; }
  fi
  sleep 0.5
done
if [[ "$ok" -ne 1 ]]; then
  echo "--- curl -v (last attempt) ---" >&2
  curl -kv -m 8 "https://127.0.0.1:${HOST_PORT}/" 2>&1 | tail -25 >&2 || true
  send 'cat /tmp/nginx-error.log'; sleep 1
fi

send 'exit' || true
stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: nginx served the index over HTTPS/TLS (W3 acceptance) — '$(tr -d '\r\n' < "$BODY" | head -c 60)'"
  exit 0
fi
fail "did not fetch the index over HTTPS from https://127.0.0.1:${HOST_PORT}/ (TLS handshake or serve failed)"
