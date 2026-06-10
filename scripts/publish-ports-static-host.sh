#!/usr/bin/env bash
# publish-ports-static-host.sh - create a static-hostable ports repository root.
#
# Produces by default:
#   build/ports-static-host-root/aarch64/current/catalog.signed
#   build/ports-static-host-root/aarch64/current/packages/*.swpkg
#   build/ports-static-host-root/repo-root.pub
#   build/ports-static-host-root/hosted-repo.json
#   build/ports-static-host-root/SHA256SUMS

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="${PORTS_STATIC_REPO_SOURCE:-$ROOT/build/ports-seed-repo-root}"
SOURCE_PUB="${PORTS_STATIC_REPO_PUB:-$ROOT/build/ports-seed-repo-root.pub}"
HOST_ROOT="${PORTS_STATIC_HOST_ROOT:-$ROOT/build/ports-static-host-root}"
BASE_URL="${PORTS_STATIC_HOST_BASE_URL:-}"
PYTHON="${PYTHON:-python3}"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 2
}

command -v "$PYTHON" >/dev/null 2>&1 || fail "$PYTHON not found"
command -v shasum >/dev/null 2>&1 || fail "shasum not found"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"

if [[ ! -f "$SOURCE_ROOT/aarch64/current/catalog.signed" || ! -f "$SOURCE_PUB" ]]; then
    "$ROOT/scripts/build-ports-seed-repo.sh"
fi

[[ -f "$SOURCE_ROOT/aarch64/current/catalog.json" ]] || fail "missing $SOURCE_ROOT/aarch64/current/catalog.json"
[[ -f "$SOURCE_ROOT/aarch64/current/catalog.signed" ]] || fail "missing $SOURCE_ROOT/aarch64/current/catalog.signed"
[[ -f "$SOURCE_PUB" ]] || fail "missing $SOURCE_PUB"

rm -rf "$HOST_ROOT"
mkdir -p "$HOST_ROOT"
cp -R "$SOURCE_ROOT/aarch64" "$HOST_ROOT/"
cp "$SOURCE_PUB" "$HOST_ROOT/repo-root.pub"

"$ROOT/build/pkgrepo" verify \
    --catalog-signed "$HOST_ROOT/aarch64/current/catalog.signed" \
    --pubkey "$HOST_ROOT/repo-root.pub"

"$PYTHON" - "$HOST_ROOT" "$BASE_URL" <<'PY'
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import sys
import time

host = Path(sys.argv[1])
base_url = sys.argv[2].strip().rstrip("/")
channel_rel = PurePosixPath("aarch64/current")
channel = host / Path(str(channel_rel))
catalog_path = channel / "catalog.json"
catalog = json.loads(catalog_path.read_text())

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def rel_url(rel: PurePosixPath) -> str:
    if base_url:
        return f"{base_url}/{rel.as_posix()}"
    return rel.as_posix()

packages = []
for package in catalog.get("packages", []):
    package_rel = channel_rel / package["url"]
    package_path = host / Path(str(package_rel))
    if not package_path.is_file():
        raise SystemExit(f"missing package blob {package_rel}")
    digest = sha256_file(package_path)
    if digest != package["sha256"]:
        raise SystemExit(f"package hash mismatch for {package['name']}: {digest} != {package['sha256']}")
    packages.append({
        "name": package["name"],
        "version": package["version"],
        "revision": package["revision"],
        "arch": package["arch"],
        "target": package["target"],
        "abi": package["abi"],
        "linkage": package["linkage"],
        "sha256": package["sha256"],
        "size": package["size"],
        "path": package_rel.as_posix(),
        "url": rel_url(package_rel),
        "depends": package.get("depends", []),
    })

install_rel = channel_rel.as_posix()
manifest = {
    "format": 1,
    "kind": "swift-os-static-host-repository",
    "repository": catalog["repository"],
    "channel": catalog["channel"],
    "generation": catalog["generation"],
    "expires": catalog["expires"],
    "rootKeyId": catalog["root_key_id"],
    "arch": "aarch64",
    "target": "swift-os",
    "abi": "swos-0",
    "linkage": "static",
    "baseURL": base_url,
    "pkgRepositoryURL": f"{base_url}/{install_rel}" if base_url else install_rel,
    "catalog": f"{install_rel}/catalog.signed",
    "catalogJSON": f"{install_rel}/catalog.json",
    "publicKey": "repo-root.pub",
    "generatedAtUnix": int(os.environ.get("SOURCE_DATE_EPOCH", time.time())),
    "packages": packages,
}

manifest_path = host / "hosted-repo.json"
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")

sum_rels = [
    PurePosixPath("repo-root.pub"),
    PurePosixPath("hosted-repo.json"),
    channel_rel / "catalog.json",
    channel_rel / "catalog.signed",
]
sum_rels.extend(PurePosixPath(pkg["path"]) for pkg in packages)
sum_rels = sorted(set(sum_rels), key=lambda p: p.as_posix())

with (host / "SHA256SUMS").open("w") as f:
    for rel in sum_rels:
        digest = sha256_file(host / Path(str(rel)))
        f.write(f"{digest}  {rel.as_posix()}\n")

if not packages:
    raise SystemExit("catalog has no packages")
PY

( cd "$HOST_ROOT" && shasum -a 256 -c SHA256SUMS )

if [[ -n "$BASE_URL" ]]; then
    printf 'Published ports static host root %s\n' "$HOST_ROOT"
    printf 'SwiftOS pkg repository URL: %s/aarch64/current\n' "${BASE_URL%/}"
else
    printf 'Published ports static host root %s\n' "$HOST_ROOT"
    printf 'Serve it and point SwiftOS pkg at http://<host>/aarch64/current\n'
fi
