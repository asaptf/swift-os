#!/usr/bin/env bash
# build-tzdata.sh - package the IANA time zone database.
#
# Produces:
#   build/tzdata.swpkg
#   build/tzdata-repo-root/aarch64/current/catalog.signed
#   build/tzdata-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${TZDATA_VERSION:-2026b}"
EXPECTED_ZONE_FILES="${TZDATA_EXPECTED_ZONE_FILES:-598}"
DISTFILES="${TZDATA_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/tzdata-port-work"
SRC="$WORK/tzdata-${VERSION}"
STAGE="$ROOT/build/tzdata-root"
ZONEINFO="$STAGE/usr/share/zoneinfo"
PACKAGE="$ROOT/build/tzdata.swpkg"
REPO_ROOT="$ROOT/build/tzdata-repo-root"
REPO_PUB="$ROOT/build/tzdata-repo-root.pub"
SOURCE="$DISTFILES/tzdata${VERSION}.tar.gz"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 2
}

require_exe() {
    command -v "$1" >/dev/null 2>&1 || fail "missing executable: $1"
}

require_exe find
require_exe grep
require_exe tar
require_exe zic

[[ "$VERSION" == "2026b" ]] || fail "unexpected tzdata version override: $VERSION"
[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"

mkdir -p "$DISTFILES" "$WORK" "$ROOT/build"
"$ROOT/build/swport" recipe fetch sysutils/tzdata --cache "$DISTFILES"
[[ -f "$SOURCE" ]] || fail "missing fetched tzdata tarball $SOURCE"

rm -rf "$SRC"
mkdir -p "$SRC"
tar xzf "$SOURCE" -C "$SRC"
[[ "$(cat "$SRC/version")" == "$VERSION" ]] || fail "source version marker is not $VERSION"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$ZONEINFO"
zic -d "$ZONEINFO" -L /dev/null -p UTC \
    "$SRC/africa" \
    "$SRC/antarctica" \
    "$SRC/asia" \
    "$SRC/australasia" \
    "$SRC/europe" \
    "$SRC/northamerica" \
    "$SRC/southamerica" \
    "$SRC/etcetera" \
    "$SRC/backward"

zone_file_count="$(find "$ZONEINFO" -type f | wc -l | tr -d ' ')"
[[ "$zone_file_count" == "$EXPECTED_ZONE_FILES" ]] ||
    fail "expected $EXPECTED_ZONE_FILES compiled zone files, found $zone_file_count"
[[ -f "$ZONEINFO/UTC" ]] || fail "missing UTC zoneinfo file"
[[ -f "$ZONEINFO/Europe/Madrid" ]] || fail "missing Europe/Madrid zoneinfo file"
[[ -f "$ZONEINFO/America/Vancouver" ]] || fail "missing America/Vancouver zoneinfo file"
grep -q 'America/Vancouver' "$SRC/zone1970.tab" ||
    fail "source zone1970.tab does not include America/Vancouver"

cp "$SRC/iso3166.tab" \
   "$SRC/leap-seconds.list" \
   "$SRC/zone.tab" \
   "$SRC/zone1970.tab" \
   "$SRC/zonenow.tab" \
   "$ZONEINFO/"
printf 'iana-tzdata %s %s compiled-zone-files\n' "$VERSION" "$EXPECTED_ZONE_FILES" \
    > "$ZONEINFO/swiftos-tzdata.version"
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +

"$ROOT/build/swport" recipe package sysutils/tzdata \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture sysutils/tzdata \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
