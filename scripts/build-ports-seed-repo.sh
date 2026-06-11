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
[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"

package_args=()
packaged_count=0
while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    packaged_count=$((packaged_count + 1))
    name="${entry%% *}"
    port_path="${entry#* }"
    [[ -n "$name" && "$port_path" != "$entry" ]] ||
        fail "invalid packaged catalog entry: $entry"

    build_script="$ROOT/scripts/build-$name.sh"
    [[ -x "$build_script" ]] ||
        fail "missing build script for packaged port $name ($port_path): $build_script"

    "$build_script"

    package="$ROOT/build/$name.swpkg"
    [[ -f "$package" ]] ||
        fail "build script for $name did not produce $package"
    package_args+=(--package "$package")
done < <("$ROOT/build/swport" catalog packaged "$ROOT/ports/catalog.json")
[[ "$packaged_count" -gt 0 ]] || fail "catalog has no packages with status=packages"

rm -rf "$REPO_ROOT" "$REPO_PUB"
"$ROOT/build/pkgrepo" create \
    "${package_args[@]}" \
    --output "$REPO_ROOT" \
    --seed-hex "$SEED_HEX" \
    --generation 1
"$ROOT/build/pkgrepo" pubkey --seed-hex "$SEED_HEX" --output "$REPO_PUB"
"$ROOT/build/pkgrepo" verify \
    --catalog-signed "$REPO_ROOT/aarch64/current/catalog.signed" \
    --pubkey "$REPO_PUB"
"$ROOT/build/pkgrepo" inspect "$REPO_ROOT/aarch64/current/catalog.signed"

printf 'Published seed ports repo fixture %s\n' "$REPO_ROOT/aarch64/current"
