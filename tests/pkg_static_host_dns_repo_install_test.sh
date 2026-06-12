#!/usr/bin/env bash
# pkg_static_host_dns_repo_install_test.sh - P9 smoke: install from a hostname repo URL.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
HTTP_PORT="${HTTP_PORT:-18195}"
DNS_PORT="${DNS_PORT:-5355}"
REPO_HOST="${REPO_HOST:-pkg.test.swos}"
REPO_DIR="$ROOT/build/ports-static-host-root"
HTTPLOG="$(mktemp -t swiftos-pkg-dns-http.XXXXXX)"
DNSLOG="$(mktemp -t swiftos-pkg-dns-server.XXXXXX)"
DNSPY="$(mktemp -t swiftos-pkg-dns-server.XXXXXX).py"
HTTPPID=""; DNSPID=""

cleanup() {
  [[ -n "$HTTPPID" ]] && kill "$HTTPPID" 2>/dev/null || true
  [[ -n "$DNSPID" ]] && kill "$DNSPID" 2>/dev/null || true
  rm -f "$HTTPLOG" "$DNSLOG" "$DNSPY"
}
trap cleanup EXIT

[[ -f "$REPO_DIR/hosted-repo.json" && -f "$REPO_DIR/SHA256SUMS" ]] || {
  ( cd "$ROOT" && make ports-static-host-publish ) >/dev/null 2>&1 || {
    echo "FAIL: cannot publish static host repository" >&2; exit 2;
  }
}
command -v "$PYTHON" >/dev/null 2>&1 || { echo "FAIL: $PYTHON not found" >&2; exit 2; }

cat > "$DNSPY" <<'PY'
import socket
import sys

port = int(sys.argv[1])
answer = bytes([10, 0, 2, 2])

def qname(data):
    labels = []
    i = 12
    while i < len(data) and data[i] != 0:
        l = data[i]
        i += 1
        labels.append(data[i:i+l].decode("ascii", "replace"))
        i += l
    return ".".join(labels)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.settimeout(180)
try:
    while True:
        data, addr = s.recvfrom(2048)
        if len(data) < 13:
            continue
        name = qname(data)
        print(name, flush=True)
        tid = data[0:2]
        i = 12
        while i < len(data) and data[i] != 0:
            i += 1 + data[i]
        qend = i + 1 + 4
        question = data[12:qend]
        resp = tid + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" + question
        resp += b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" + answer
        s.sendto(resp, addr)
except socket.timeout:
    pass
PY

( cd "$REPO_DIR" && "$PYTHON" -m http.server "$HTTP_PORT" --bind 0.0.0.0 >"$HTTPLOG" 2>&1 ) &
HTTPPID=$!
disown "$HTTPPID" 2>/dev/null || true
"$PYTHON" "$DNSPY" "$DNS_PORT" >"$DNSLOG" 2>&1 &
DNSPID=$!
disown "$DNSPID" 2>/dev/null || true
sleep 0.8
kill -0 "$HTTPPID" 2>/dev/null || { echo "FAIL: HTTP server did not start" >&2; sed -n '1,120p' "$HTTPLOG" >&2 || true; exit 2; }
kill -0 "$DNSPID" 2>/dev/null || { echo "FAIL: DNS server did not start" >&2; sed -n '1,120p' "$DNSLOG" >&2 || true; exit 2; }

PKG_HOSTED_REPO_URL="http://$REPO_HOST:$HTTP_PORT/aarch64/current" \
PKG_HOSTED_DNS_SERVER="10.0.2.2:$DNS_PORT" \
PKG_HOSTED_BASE_IMG="build/base-ports-static-host-dns.img" \
"$ROOT/tests/pkg_hosted_url_install_test.sh" || {
  echo "--- dns log ---" >&2
  cat "$DNSLOG" >&2 || true
  echo "--- http log ---" >&2
  cat "$HTTPLOG" >&2 || true
  exit 1
}

grep -qF "$REPO_HOST" "$DNSLOG" || { echo "FAIL: DNS server did not resolve $REPO_HOST" >&2; cat "$DNSLOG" >&2 || true; exit 1; }
grep -qF "GET /aarch64/current/catalog.signed" "$HTTPLOG" || { echo "FAIL: catalog request missing" >&2; exit 1; }
grep -qF "GET /aarch64/current/packages/" "$HTTPLOG" || { echo "FAIL: package request missing" >&2; exit 1; }

echo "PASS: /bin/pkg installed Lua, zlib, bzip2, zstd, xz, libarchive, ca-certificates, OpenSSL, pcre2, curl, tzdata, nginx, and sqlite from a DNS-resolved hosted repository URL"
