#!/usr/bin/env bash
# tls_test.sh — Track A4 acceptance: a native Swift /bin/tlsget HTTPS client.
#
# The guest opens a TLS 1.3 connection OUT to a host server and fetches a page.
# QEMU slirp maps 10.0.2.2 to the host, so a host TLS server bound on the host
# is reachable from the guest at 10.0.2.2:<port> with no hostfwd (this is the
# same reachability tcp_connect_test.sh relies on).
#
# Host server: openssl s_server, TLS 1.3 only, single ciphersuite
# TLS_CHACHA20_POLY1305_SHA256 (the one suite tls13.swift implements), with a
# throwaway self-signed cert. This test runs /bin/tlsget with --insecure (cert
# verification is covered separately by tls_truststore_test.sh). `-www`
# makes the server answer `GET /` with an HTTP status page, so we can assert on
# the decrypted body the guest prints.
#
# Assertions (from the guest serial log):
#   - "tlsget: handshake complete"  (the full TLS 1.3 handshake ran end-to-end), and
#   - "HTTP/1.0 200 ok"             (the guest decrypted a real HTTP response body).
#
# Best-effort note: if openssl s_server cannot be started (missing binary, etc.)
# the test SKIPs rather than fails the build — but on this machine openssl@3
# (3.6.x) serves TLS 1.3 + ChaCha20-Poly1305 fine.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
OPENSSL="${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}"
PORT="${TLS_PORT:-44310}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -x "$OPENSSL" ]]; then
  command -v openssl >/dev/null 2>&1 && OPENSSL="$(command -v openssl)" \
    || { echo "SKIP: openssl not found ($OPENSSL); cannot host a TLS 1.3 server" >&2; exit 0; }
fi

CERTDIR="$(mktemp -d -t swiftos-tls.XXXXXX)"
LOG="$(mktemp -t swiftos-tls-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-tls-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-tls-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""; SPID=""
stop_all() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$SPID" ]] && kill "$SPID" 2>/dev/null || true
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_all; exec 3>&- 2>/dev/null; rm -rf "$CERTDIR"; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

# Throwaway self-signed cert (ECDSA P-256). The client ignores it; openssl still
# needs *a* cert/key pair to serve.
if ! "$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
       -keyout "$CERTDIR/key.pem" -out "$CERTDIR/cert.pem" -days 2 -nodes \
       -subj '/CN=localhost' >/dev/null 2>&1; then
  echo "SKIP: openssl could not generate a self-signed cert" >&2
  exit 0
fi

# Host TLS 1.3 server, single ciphersuite, -www to answer GET / with a page.
# `-4` is essential: openssl s_server otherwise binds IPv6-only (tcp46), which
# QEMU slirp's IPv4 10.0.2.2 alias cannot reach. With `-4` it binds IPv4 *:PORT
# (tcp4) — exactly like the `nc -l` that tcp_connect_test.sh reaches over slirp.
# We deliberately do NOT pass `-naccept 1`: the readiness probe below opens (and
# closes) one connection, so a one-shot server would already be gone before the
# guest connects. -www keeps serving, and the EXIT trap stops it.
"$OPENSSL" s_server -accept "$PORT" -4 \
  -cert "$CERTDIR/cert.pem" -key "$CERTDIR/key.pem" \
  -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 -www -quiet \
  >/dev/null 2>&1 &
SPID=$!
disown "$SPID" 2>/dev/null || true   # silence the shell's "Terminated" notice on cleanup
# Wait for the listener (a quick connect/close; the server keeps serving).
listening=0
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3>&- 3<&-; listening=1; break; fi
  sleep 0.2
done
if [[ "$listening" -ne 1 ]]; then
  echo "SKIP: openssl s_server did not start listening on $PORT" >&2
  exit 0
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

require_await() {  # require_await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}"
  if ! await "$marker" "$max"; then
    echo "FAIL: timed out waiting for serial marker: $marker" >&2
    echo "--- serial tail ---" >&2
    sed 's/\r//' "$LOG" | tail -80 >&2
    exit 1
  fi
}

send_line() {
  local line="$1" delay="${TLS_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${TLS_SEND_DELAY:-0.08}"
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

require_await "M7 tty: type a line then Enter" 60; send_line 'tty-line'
require_await "M7 tty: running; press Ctrl-C" 40; printf '\003' >&3
require_await "swift-os login:" 40; send_line 'root'
require_await "Password:" 30; send_line 'swordfish'
require_await "Welcome to swift-os, root" 40
require_await "built-in shell (ash)" 60
# --insecure: this test exercises the TLS 1.3 record/handshake machinery against a
# throwaway self-signed cert; certificate verification is covered by
# tls_truststore_test.sh / tls_verify_test.sh instead.
send_line "/bin/tlsget --insecure 10.0.2.2 $PORT"
await "HTTP/1.0 200 ok" 90 || true
exec 3>&-
stop_all
QP=""; SPID=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "tlsget: connected" <<<"$clean" || { echo "FAIL: client did not connect (TCP)" >&2; ok=0; }
grep -qF "tlsget: handshake complete" <<<"$clean" \
  || { echo "FAIL: TLS 1.3 handshake did not complete" >&2; ok=0; }
grep -qF "HTTP/1.0 200 ok" <<<"$clean" \
  || { echo "FAIL: guest did not decrypt the HTTP response body" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/tlsget TLS 1.3 handshake + decrypted HTTPS GET to a host server (Track A4 acceptance)"
  exit 0
fi
echo "--- serial (tlsget region) ---" >&2
sed -n '/tlsget:/,$p' <<<"$clean" | head -30 >&2
exit 1
