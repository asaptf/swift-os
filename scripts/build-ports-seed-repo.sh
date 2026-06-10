#!/usr/bin/env bash
# build-ports-seed-repo.sh - publish the current ready ports into one signed repo.
#
# Produces:
#   build/ports-seed-repo-root/aarch64/current/catalog.signed
#   build/ports-seed-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="${PORTS_SEED_REPO_ROOT:-$ROOT/build/ports-seed-repo-root}"
REPO_PUB="${PORTS_SEED_REPO_PUB:-$ROOT/build/ports-seed-repo-root.pub}"
SEED_HEX="${PORTS_SEED_REPO_SEED_HEX:-000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f}"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 2
}

[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"

"$ROOT/scripts/build-lua.sh"
"$ROOT/scripts/build-zlib.sh"
"$ROOT/scripts/build-ca-certificates.sh"
"$ROOT/scripts/build-pcre2.sh"

rm -rf "$REPO_ROOT" "$REPO_PUB"
"$ROOT/build/pkgrepo" create \
    --package "$ROOT/build/lua.swpkg" \
    --package "$ROOT/build/zlib.swpkg" \
    --package "$ROOT/build/ca-certificates.swpkg" \
    --package "$ROOT/build/pcre2.swpkg" \
    --output "$REPO_ROOT" \
    --seed-hex "$SEED_HEX" \
    --generation 1
"$ROOT/build/pkgrepo" pubkey --seed-hex "$SEED_HEX" --output "$REPO_PUB"
"$ROOT/build/pkgrepo" verify \
    --catalog-signed "$REPO_ROOT/aarch64/current/catalog.signed" \
    --pubkey "$REPO_PUB"
"$ROOT/build/pkgrepo" inspect "$REPO_ROOT/aarch64/current/catalog.signed"

printf 'Published seed ports repo fixture %s\n' "$REPO_ROOT/aarch64/current"
