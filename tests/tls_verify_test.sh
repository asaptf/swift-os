#!/usr/bin/env bash
# tls_verify_test.sh — V2b acceptance: tls13.swift authenticates a TLS 1.3
# server when verification is enabled. The same sans-IO engine the guest runs is
# driven on the host (tls_verify_driver) over a POSIX socket against openssl
# s_server, so the cert-verification path is exercised without QEMU.
#
# Cases:
#   1. trusted CA, matching SAN host          -> VERIFY-OK   (handshake authenticated)
#   2. untrusted (self-signed) server cert     -> VERIFY-FAIL (chain not anchored)
#   3. trusted CA but wrong expected hostname  -> VERIFY-FAIL (SAN mismatch)
#
# SKIPs if openssl/swiftc are unavailable.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_SWIFTC="${HOST_SWIFTC:-/usr/bin/swiftc}"
OPENSSL="${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}"
BUILD="$ROOT/build"
PORT_OK="${TLSV_PORT_OK:-44360}"
PORT_BAD="${TLSV_PORT_BAD:-44361}"
HOSTNAME_OK="test.swiftos"

command -v "$HOST_SWIFTC" >/dev/null 2>&1 || { echo "SKIP: swiftc not found" >&2; exit 0; }
if [[ ! -x "$OPENSSL" ]]; then
  command -v openssl >/dev/null 2>&1 && OPENSSL="$(command -v openssl)" \
    || { echo "SKIP: openssl not found" >&2; exit 0; }
fi

W="$(mktemp -d -t swiftos-tlsv.XXXXXX)"
SPID_OK=""; SPID_BAD=""
cleanup() {
  [[ -n "$SPID_OK" ]] && kill "$SPID_OK" 2>/dev/null
  [[ -n "$SPID_BAD" ]] && kill "$SPID_BAD" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT

# Trusted CA (CA:TRUE) + a leaf it signs (SAN matches HOSTNAME_OK), both P-256.
"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$W/ca.key" -out "$W/ca.crt" -days 3650 -subj '/CN=SwiftOS V2b CA' \
  -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1 || { echo "SKIP: openssl ca" >&2; exit 0; }
"$OPENSSL" req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$W/leaf.key" -out "$W/leaf.csr" -subj "/CN=$HOSTNAME_OK" >/dev/null 2>&1
printf 'basicConstraints=CA:FALSE\nsubjectAltName=DNS:%s\n' "$HOSTNAME_OK" > "$W/leaf.ext"
"$OPENSSL" x509 -req -in "$W/leaf.csr" -CA "$W/ca.crt" -CAkey "$W/ca.key" -CAcreateserial \
  -out "$W/leaf.crt" -days 3650 -extfile "$W/leaf.ext" -sha256 >/dev/null 2>&1

# Untrusted self-signed cert with the SAME SAN (so case 2 isolates the trust check).
"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$W/evil.key" -out "$W/evil.crt" -days 3650 -subj "/CN=$HOSTNAME_OK" \
  -addext "subjectAltName=DNS:$HOSTNAME_OK" >/dev/null 2>&1

"$OPENSSL" x509 -in "$W/ca.crt" -outform DER -out "$W/ca.der"

# Two TLS 1.3 servers (single ciphersuite, IPv4).
"$OPENSSL" s_server -accept "$PORT_OK" -4 -cert "$W/leaf.crt" -key "$W/leaf.key" \
  -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 -www -quiet >/dev/null 2>&1 &
SPID_OK=$!; disown "$SPID_OK" 2>/dev/null || true
"$OPENSSL" s_server -accept "$PORT_BAD" -4 -cert "$W/evil.crt" -key "$W/evil.key" \
  -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 -www -quiet >/dev/null 2>&1 &
SPID_BAD=$!; disown "$SPID_BAD" 2>/dev/null || true

wait_listen() {
  for _ in $(seq 1 30); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then exec 3>&- 3<&-; return 0; fi
    sleep 0.2
  done
  return 1
}
wait_listen "$PORT_OK"  || { echo "SKIP: s_server(ok) did not start" >&2; exit 0; }
wait_listen "$PORT_BAD" || { echo "SKIP: s_server(bad) did not start" >&2; exit 0; }

SRCS="userland/lib/tls13.swift userland/lib/x509.swift userland/lib/x509_verify.swift userland/lib/rsa.swift kernel/crypto/p256.swift kernel/crypto/sha256.swift kernel/crypto/x25519.swift kernel/crypto/chacha20poly1305.swift"
( cd "$ROOT" && $HOST_SWIFTC tests/tls_verify_driver.swift $SRCS -o "$BUILD/tls_verify_driver" ) \
  || { echo "FAIL: driver did not compile" >&2; exit 1; }

NOW="$(date -u +%Y%m%d%H%M%S)"
ok=1

out1="$("$BUILD/tls_verify_driver" "$HOSTNAME_OK" "$PORT_OK" "$W/ca.der" "$NOW")"; rc1=$?
[[ "$rc1" -eq 0 && "$out1" == "VERIFY-OK" ]] || { echo "FAIL: trusted CA + matching host should verify (got '$out1' rc=$rc1)" >&2; ok=0; }

out2="$("$BUILD/tls_verify_driver" "$HOSTNAME_OK" "$PORT_BAD" "$W/ca.der" "$NOW")"; rc2=$?
[[ "$rc2" -ne 0 && "$out2" == VERIFY-FAIL* ]] || { echo "FAIL: untrusted cert should be rejected (got '$out2' rc=$rc2)" >&2; ok=0; }

out3="$("$BUILD/tls_verify_driver" "wrong.host" "$PORT_OK" "$W/ca.der" "$NOW")"; rc3=$?
[[ "$rc3" -ne 0 && "$out3" == VERIFY-FAIL* ]] || { echo "FAIL: wrong hostname should be rejected (got '$out3' rc=$rc3)" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: tls13 verifies a trusted server ($out1), rejects an untrusted cert and a hostname mismatch"
  exit 0
fi
exit 1
