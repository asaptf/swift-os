#!/usr/bin/env bash
# build-ca-certificates.sh - package the Mozilla CA certificate bundle.
#
# Produces:
#   build/ca-certificates.swpkg
#   build/ca-certificates-repo-root/aarch64/current/catalog.signed
#   build/ca-certificates-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${CA_CERTIFICATES_VERSION:-2026.05.14}"
DATED_REVISION="${CA_CERTIFICATES_DATED_REVISION:-2026-05-14}"
EXPECTED_CERTS="${CA_CERTIFICATES_EXPECTED_CERTS:-121}"
DISTFILES="${CA_CERTIFICATES_DISTFILES:-$ROOT/build/swport-distfiles}"
STAGE="$ROOT/build/ca-certificates-root"
PACKAGE="$ROOT/build/ca-certificates.swpkg"
REPO_ROOT="$ROOT/build/ca-certificates-repo-root"
REPO_PUB="$ROOT/build/ca-certificates-repo-root.pub"
SOURCE="$DISTFILES/cacert-${DATED_REVISION}.pem"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 2
}

require_exe() {
    command -v "$1" >/dev/null 2>&1 || fail "missing executable: $1"
}

[[ "$VERSION" == "2026.05.14" ]] || fail "unexpected ca-certificates version override: $VERSION"
require_exe grep

[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"

mkdir -p "$DISTFILES" "$ROOT/build"
"$ROOT/build/swport" recipe fetch security/ca-certificates --cache "$DISTFILES"
[[ -f "$SOURCE" ]] || fail "missing fetched bundle $SOURCE"

grep -q 'BEGIN CERTIFICATE' "$SOURCE" || fail "fetched bundle has no certificates"
grep -q 'Certificate data from Mozilla as of: Thu May 14 03:12:02 2026 GMT' "$SOURCE" ||
    fail "fetched bundle is not the expected Mozilla dated revision"
cert_count="$(grep -c 'BEGIN CERTIFICATE' "$SOURCE")"
[[ "$cert_count" == "$EXPECTED_CERTS" ]] ||
    fail "expected $EXPECTED_CERTS certificates, found $cert_count"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/etc/ssl" "$STAGE/usr/share/certs"
cp "$SOURCE" "$STAGE/usr/etc/ssl/cert.pem"
cp "$SOURCE" "$STAGE/usr/share/certs/ca-certificates.crt"
printf 'curl-ca-bundle %s %s certificates\n' "$DATED_REVISION" "$EXPECTED_CERTS" \
    > "$STAGE/usr/share/certs/swiftos-ca-bundle.version"
chmod 0644 "$STAGE/usr/etc/ssl/cert.pem" \
    "$STAGE/usr/share/certs/ca-certificates.crt" \
    "$STAGE/usr/share/certs/swiftos-ca-bundle.version"

"$ROOT/build/swport" recipe package security/ca-certificates \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture security/ca-certificates \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
