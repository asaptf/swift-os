#!/usr/bin/env bash
# pkg_hosted_url_verify_test.sh - host-side verifier smoke against a served publish root.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
PORT="${PORT:-18196}"
REPO_DIR="$ROOT/build/ports-static-host-root"
HTTPLOG="$(mktemp -t swiftos-hosted-verify-http.XXXXXX)"
HTTPPID=""

cleanup() {
  [[ -n "$HTTPPID" ]] && kill "$HTTPPID" 2>/dev/null || true
  rm -f "$HTTPLOG"
}
trap cleanup EXIT

[[ -f "$REPO_DIR/hosted-repo.json" && -f "$REPO_DIR/SHA256SUMS" ]] || {
  ( cd "$ROOT" && make ports-static-host-publish ) >/dev/null 2>&1 || {
    echo "FAIL: cannot publish static host repository" >&2; exit 2;
  }
}
command -v "$PYTHON" >/dev/null 2>&1 || { echo "FAIL: $PYTHON not found" >&2; exit 2; }

( cd "$REPO_DIR" && "$PYTHON" -m http.server "$PORT" --bind 127.0.0.1 >"$HTTPLOG" 2>&1 ) &
HTTPPID=$!
disown "$HTTPPID" 2>/dev/null || true
sleep 0.8
kill -0 "$HTTPPID" 2>/dev/null || {
  echo "FAIL: HTTP server did not start" >&2
  sed -n '1,120p' "$HTTPLOG" >&2 || true
  exit 2
}
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  "$PYTHON" - "$PORT" <<'PY' >/dev/null 2>&1 && { ready=1; break; }
import sys
import urllib.request

port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/hosted-repo.json", timeout=2) as response:
    if response.status != 200:
        raise SystemExit(1)
PY
  sleep 0.2
done
[[ "$ready" -eq 1 ]] || {
  echo "FAIL: HTTP server did not serve hosted-repo.json" >&2
  sed -n '1,120p' "$HTTPLOG" >&2 || true
  exit 2
}

PKGREPO="$ROOT/build/pkgrepo" "$ROOT/scripts/verify-ports-hosted-url.sh" "http://127.0.0.1:$PORT" || {
  echo "--- http log ---" >&2
  cat "$HTTPLOG" >&2 || true
  exit 1
}

grep -qF "GET /hosted-repo.json" "$HTTPLOG" || { echo "FAIL: hosted manifest request missing" >&2; exit 1; }
grep -qF "GET /SHA256SUMS" "$HTTPLOG" || { echo "FAIL: SHA256SUMS request missing" >&2; exit 1; }
grep -qF "GET /aarch64/current/catalog.signed" "$HTTPLOG" || { echo "FAIL: catalog request missing" >&2; exit 1; }
grep -qF "GET /aarch64/current/packages/" "$HTTPLOG" || { echo "FAIL: package request missing" >&2; exit 1; }

echo "PASS: hosted URL verifier checked the served ports static host root"
