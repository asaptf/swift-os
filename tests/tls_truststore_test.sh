#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tls_truststore_test.sh — /bin/tlsget verifies by default against the system
# trust store (/etc/ssl/cert.pem, shipped in the base image).
#
# A host openssl s_server presents a leaf signed by a TEST CA (SAN IP:10.0.2.2),
# reachable from the guest at the slirp host alias 10.0.2.2. In the guest:
#   A) default verify uses the system store (the 2 ISRG roots) -> the test leaf
#      does NOT chain to them, so the handshake is REJECTED (proves verify is on
#      by default AND the embedded store actually loaded — "2 trust root(s)").
#   B) --cafile <test CA> -> the leaf chains to the trusted root, SAN matches the
#      connected IP, validity OK -> handshake COMPLETES.
#   C) --insecure -> verification skipped -> handshake COMPLETES (opt-out works).
#
# SKIPs if openssl is unavailable.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"; DTB="$ROOT/build/virt.dtb"; DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
OPENSSL="${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}"
PORT="${TLS_TS_PORT:-44381}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }
if [[ ! -x "$OPENSSL" ]]; then
  command -v openssl >/dev/null 2>&1 && OPENSSL="$(command -v openssl)" || { echo "SKIP: openssl" >&2; exit 0; }
fi

W="$(mktemp -d -t swiftos-tlsts.XXXXXX)"; LOG="$(mktemp -t swiftos-tlsts-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-tlsts-pid.XXXXXX)"; INFIFO="$(mktemp -u -t swiftos-tlsts-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""; SPID=""
stop_all() {
  if [[ -f "$PIDFILE" ]]; then local p; p="$(cat "$PIDFILE" 2>/dev/null||true)"; [[ -n "$p" ]] && { kill "$p" 2>/dev/null||true; sleep 0.2; kill -9 "$p" 2>/dev/null||true; }; fi
  [[ -n "$SPID" ]] && kill "$SPID" 2>/dev/null||true
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null||true
}
trap 'stop_all; exec 3>&- 2>/dev/null; rm -rf "$W" "$LOG" "$PIDFILE" "$INFIFO"' EXIT

# Test CA (CA:TRUE) + a leaf it signs with SAN IP:10.0.2.2, both P-256.
"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$W/ca.key" -out "$W/ca.pem" -days 3650 -subj '/CN=SwiftOS truststore test CA' \
  -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1 || { echo "SKIP: openssl ca" >&2; exit 0; }
"$OPENSSL" req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$W/leaf.key" -out "$W/leaf.csr" -subj '/CN=10.0.2.2' >/dev/null 2>&1
printf 'basicConstraints=CA:FALSE\nsubjectAltName=IP:10.0.2.2\n' > "$W/leaf.ext"
"$OPENSSL" x509 -req -in "$W/leaf.csr" -CA "$W/ca.pem" -CAkey "$W/ca.key" -CAcreateserial \
  -out "$W/leaf.pem" -days 3650 -extfile "$W/leaf.ext" -sha256 >/dev/null 2>&1 \
  || { echo "SKIP: openssl leaf" >&2; exit 0; }

# Single TLS 1.3 server (IPv4, ChaCha20-Poly1305 — the one suite our client offers).
"$OPENSSL" s_server -accept "$PORT" -4 -cert "$W/leaf.pem" -key "$W/leaf.key" \
  -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 -www -quiet >/dev/null 2>&1 &
SPID=$!; disown "$SPID" 2>/dev/null||true
listening=0
for _ in $(seq 1 30); do if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3>&- 3<&-; listening=1; break; fi; sleep 0.2; done
[[ "$listening" -eq 1 ]] || { echo "SKIP: s_server did not start" >&2; exit 0; }

dtb_args=(); [[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
await(){ local m="$1" mx="${2:-30}" n=0; while ((n<mx*10)); do grep -qF "$m" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
await_count(){ local m="$1" want="$2" mx="${3:-30}" n=0 got; while ((n<mx*10)); do got="$(sed 's/\r//' "$LOG" 2>/dev/null|grep -cF "$m"||true)"; ((got>=want)) && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
require_await(){ await "$1" "$2" || { echo "FAIL: timeout: $1" >&2; sed 's/\r//' "$LOG"|tail -60 >&2; exit 1; }; }
send_line(){ local l="$1" d="${TLS_TS_CHAR_DELAY:-0.008}" i; for ((i=0;i<${#l};i++)); do printf '%s' "${l:i:1}" >&3; sleep "$d"; done; printf '\n' >&3; sleep "${TLS_TS_SEND_DELAY:-0.06}"; }
paste_pem(){ send_line "cat > $1 <<'PEMEOF'"; while IFS= read -r ln; do send_line "$ln"; done < "$2"; send_line "PEMEOF"; }

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

require_await "M7 tty: type a line then Enter" 60; send_line 'tty-line'
require_await "M7 tty: running; press Ctrl-C" 40; printf '\003' >&3
require_await "swift-os login:" 40; send_line 'root'
require_await "Password:" 30; send_line 'swordfish'
require_await "M12c: shell ready" 60

paste_pem /tmp/testca.pem "$W/ca.pem"

# A) Default: system trust store (2 ISRG roots) — the test leaf does not chain to
#    them, so verification rejects the server.
send_line "/bin/tlsget 10.0.2.2 $PORT 10.0.2.2"
await "verifying against 2 trust root(s)" 40 || true
await "handshake failed" 40 || true

# B) Trust the test CA explicitly: chain + SAN + validity all pass.
send_line "/bin/tlsget --cafile /tmp/testca.pem 10.0.2.2 $PORT 10.0.2.2"
await "verifying against 1 trust root(s)" 40 || true
await "handshake complete" 40 || true

# C) Insecure: verification skipped.
send_line "/bin/tlsget --insecure 10.0.2.2 $PORT 10.0.2.2"
await "insecure mode" 40 || true
await_count "handshake complete" 2 40 || true

exec 3>&-; stop_all; QP=""; SPID=""

clean="$(sed 's/\r//' "$LOG")"; ok=1
fail(){ echo "FAIL: $1" >&2; ok=0; }
grep -qF "verifying against 2 trust root(s)" <<<"$clean" || fail "system trust store (2 ISRG roots) did not load by default"
grep -qF "handshake failed" <<<"$clean"               || fail "default verify did NOT reject a leaf outside the system store"
grep -qF "verifying against 1 trust root(s)" <<<"$clean" || fail "--cafile did not load the test root"
[[ "$(grep -cF 'handshake complete' <<<"$clean")" -ge 2 ]] || fail "verified (--cafile) and/or insecure handshake did not complete"
grep -qF "insecure mode" <<<"$clean"                  || fail "--insecure was not honored"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/tlsget verifies by default against the system trust store; --cafile and --insecure work"
  exit 0
fi
echo "--- tlsget region ---" >&2; sed -n '/tlsget:/,$p' <<<"$clean" | head -40 >&2
exit 1
