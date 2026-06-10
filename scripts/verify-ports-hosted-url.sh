#!/usr/bin/env bash
# verify-ports-hosted-url.sh - verify a deployed SwiftOS static package repo URL.
#
# Usage:
#   PKGREPO=build/pkgrepo scripts/verify-ports-hosted-url.sh http://host[/aarch64/current]

set -euo pipefail

URL="${1:-${PKG_HOSTED_REPO_URL:-}}"
PYTHON="${PYTHON:-python3}"
PKGREPO="${PKGREPO:-build/pkgrepo}"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 2
}

[[ -n "$URL" ]] || fail "usage: $0 http://host[/aarch64/current]"
command -v "$PYTHON" >/dev/null 2>&1 || fail "$PYTHON not found"
command -v shasum >/dev/null 2>&1 || fail "shasum not found"
[[ -x "$PKGREPO" ]] || fail "missing executable pkgrepo at $PKGREPO"

TMP="$(mktemp -d -t swiftos-hosted-repo.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

"$PYTHON" - "$URL" "$TMP" <<'PY'
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import urllib.request

url = sys.argv[1].rstrip("/")
tmp = Path(sys.argv[2])
channel_suffix = "/aarch64/current"
if url.endswith(channel_suffix):
    root_url = url[:-len(channel_suffix)]
    repo_url = url
else:
    root_url = url
    repo_url = f"{url}{channel_suffix}"

def fetch(url_text: str) -> bytes:
    with urllib.request.urlopen(url_text, timeout=20) as response:
        if response.status != 200:
            raise SystemExit(f"{url_text}: HTTP {response.status}")
        return response.read()

def safe_rel(path: str) -> PurePosixPath:
    rel = PurePosixPath(path)
    if rel.is_absolute() or ".." in rel.parts:
        raise SystemExit(f"unsafe SHA256SUMS path: {path}")
    return rel

manifest = json.loads(fetch(f"{root_url}/hosted-repo.json"))
if manifest.get("kind") != "swift-os-static-host-repository":
    raise SystemExit("hosted-repo.json has unexpected kind")
if manifest.get("catalog") != "aarch64/current/catalog.signed":
    raise SystemExit("hosted-repo.json points at an unexpected catalog path")
names = {package.get("name") for package in manifest.get("packages", [])}
if not {"lua", "zlib", "ca-certificates"}.issubset(names):
    raise SystemExit(f"hosted-repo.json missing seed packages: {sorted(names)}")

sum_bytes = fetch(f"{root_url}/SHA256SUMS")
(tmp / "SHA256SUMS").write_bytes(sum_bytes)
for raw in sum_bytes.decode("utf-8").splitlines():
    line = raw.strip()
    if not line:
        continue
    parts = line.split()
    if len(parts) != 2 or len(parts[0]) != 64:
        raise SystemExit(f"bad SHA256SUMS line: {raw}")
    expected, rel_text = parts
    rel = safe_rel(rel_text)
    data = fetch(f"{root_url}/{rel.as_posix()}")
    got = hashlib.sha256(data).hexdigest()
    if got != expected:
        raise SystemExit(f"hash mismatch for {rel}: {got} != {expected}")
    out = tmp / Path(str(rel))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)

catalog_signed = tmp / "aarch64/current/catalog.signed"
repo_pub = tmp / "repo-root.pub"
if not catalog_signed.is_file() or not repo_pub.is_file():
    raise SystemExit("SHA256SUMS did not include catalog.signed and repo-root.pub")

print(f"root_url={root_url}")
print(f"repo_url={repo_url}")
print("packages=" + ",".join(sorted(names)))
PY

( cd "$TMP" && shasum -a 256 -c SHA256SUMS >/dev/null )
"$PKGREPO" verify \
    --catalog-signed "$TMP/aarch64/current/catalog.signed" \
    --pubkey "$TMP/repo-root.pub" >/dev/null

printf 'PASS: hosted SwiftOS package repository verified at %s\n' "$URL"
