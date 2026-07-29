#!/usr/bin/env bash
# build-curl.sh - cross-build HTTP-only curl and publish a signed package repo.
#
# Produces:
#   build/curl.swpkg
#   build/curl-repo-root/aarch64/current/catalog.signed
#   build/curl-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
VERSION="${CURL_VERSION:-8.20.0}"
DISTFILES="${CURL_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/curl-port-work"
SRC="$WORK/curl-${VERSION}"
RUNTIME="$ROOT/build/curl-port-runtime"
STAGE="$ROOT/build/curl-root"
PACKAGE="$ROOT/build/curl.swpkg"
REPO_ROOT="$ROOT/build/curl-repo-root"
REPO_PUB="$ROOT/build/curl-repo-root.pub"
SYSROOT="${CURL_SYSROOT:-$ROOT/sysroot/aarch64-elf}"
COMPAT="$ROOT/userland/compat"
CC="${CURL_CC:-aarch64-elf-gcc}"
AR="${CURL_AR:-aarch64-elf-ar}"
RANLIB="${CURL_RANLIB:-aarch64-elf-ranlib}"
READELF="${CURL_READELF:-aarch64-elf-readelf}"
NM="${CURL_NM:-aarch64-elf-nm}"
STRIP="${CURL_STRIP:-aarch64-elf-strip}"
JOBS="${JOBS:-4}"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 2
}

require_exe() {
    command -v "$1" >/dev/null 2>&1 || fail "missing executable: $1"
}

require_exe "$CC"
require_exe "$AR"
require_exe "$RANLIB"
require_exe "$READELF"
require_exe "$NM"
require_exe "$STRIP"
require_exe make
require_exe tar

[[ "$VERSION" == "8.20.0" ]] || fail "unexpected curl version override: $VERSION"
[[ -x "$ROOT/build/swport" ]] || fail "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail "missing build/pkgrepo; run make pkgrepo"
[[ -f "$SYSROOT/lib/libc.a" ]] || fail "newlib sysroot missing. Run: make newlib"

rm -rf "$SRC" "$RUNTIME"
mkdir -p "$DISTFILES" "$WORK" "$RUNTIME" "$ROOT/build"
"$ROOT/build/swport" recipe fetch net/curl --cache "$DISTFILES"
tar xJf "$DISTFILES/curl-${VERSION}.tar.xz" -C "$WORK"

inc_flags=(-isystem "$COMPAT" -isystem "$SYSROOT/include")
runtime_cflags=(-ffreestanding -Os "${inc_flags[@]}")

"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$RUNTIME/crt0_newlib.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$RUNTIME/newlib_syscalls.o"
"$CC" "${runtime_cflags[@]}" -c "$ROOT/userland/compat/stubs.c" \
    -o "$RUNTIME/compat_stubs.o"

cc_wrapper="$RUNTIME/swiftos-cc"
cat >"$cc_wrapper" <<EOF
#!/usr/bin/env bash
real_cc="$CC"
root="$ROOT"
sysroot="$SYSROOT"
compat="$COMPAT"
runtime="$RUNTIME"
compile_flags=(-ffreestanding -Os -isystem "\$compat" -isystem "\$sysroot/include")
link_flags=(-static -nostartfiles -nostdlib -T "\$root/userland/user_newlib.ld" -Wl,-z,max-page-size=4096
            "\$runtime/crt0_newlib.o"
            "\$runtime/newlib_syscalls.o"
            "\$runtime/compat_stubs.o"
            -L"\$sysroot/lib"
            -Wl,--start-group -lc -lgcc -Wl,--end-group)
mode=link
out=""
prev=""
for arg in "\$@"; do
    case "\$arg" in
        -c|-E|-S) mode=compile ;;
    esac
    if [[ "\$prev" = "-o" ]]; then out="\$arg"; fi
    prev="\$arg"
done
if [[ "\$mode" = compile ]]; then
    exec "\$real_cc" "\${compile_flags[@]}" "\$@"
fi
case "\$out" in
    *.la|*.lo|*.o) exec "\$real_cc" "\${compile_flags[@]}" "\$@" ;;
esac
exec "\$real_cc" "\${compile_flags[@]}" "\$@" "\${link_flags[@]}"
EOF
chmod +x "$cc_wrapper"

(
    cd "$SRC"
    export CC="$cc_wrapper" AR RANLIB
    export CFLAGS="-ffreestanding -Os"
    export CPPFLAGS="-isystem $COMPAT -isystem $SYSROOT/include"
    export LDFLAGS="-L$SYSROOT/lib"
    # Already had --build; still sanitize CLICOLOR_FORCE so ac_cv_exeext stays clean.
    autoconf_cross_prepare
    ./configure \
        --host=aarch64-elf \
        "$(autoconf_cross_build_arg)" \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        --without-ssl \
        --without-zlib \
        --without-brotli \
        --without-zstd \
        --without-libpsl \
        --without-libidn2 \
        --without-nghttp2 \
        --without-nghttp3 \
        --without-ngtcp2 \
        --without-quiche \
        --without-gssapi \
        --disable-dict \
        --disable-file \
        --disable-ftp \
        --disable-gopher \
        --disable-imap \
        --disable-ldap \
        --disable-ldaps \
        --disable-mqtt \
        --disable-pop3 \
        --disable-rtsp \
        --disable-smb \
        --disable-smtp \
        --disable-telnet \
        --disable-tftp \
        --disable-ipfs \
        --disable-websockets \
        --disable-manual \
        --disable-docs \
        --disable-threaded-resolver \
        --disable-ipv6
    make -j"$JOBS"
)

undefined="$("$NM" -u "$SRC/src/curl")"
[[ -z "$undefined" ]] || fail "curl has undefined symbols: $undefined"
"$READELF" -h "$SRC/src/curl" | grep -q 'Machine:[[:space:]]*AArch64' ||
    fail "curl is not an AArch64 ELF"
"$STRIP" "$SRC/src/curl"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/include/curl" \
    "$STAGE/usr/lib/pkgconfig" "$STAGE/usr/share/curl"
cp "$SRC/src/curl" "$STAGE/usr/bin/curl"
cp "$SRC/lib/.libs/libcurl.a" "$STAGE/usr/lib/libcurl.a"
cp "$SRC/include/curl/"*.h "$STAGE/usr/include/curl/"
cat >"$STAGE/usr/lib/pkgconfig/libcurl.pc" <<EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include
supported_protocols="HTTP"
supported_features="alt-svc Largefile UnixSockets"

Name: libcurl
URL: https://curl.se/
Description: Library to transfer files with HTTP
Version: ${VERSION}
Requires:
Requires.private:
Libs: -L\${libdir} -lcurl
Libs.private:
Cflags: -I\${includedir} -DCURL_STATICLIB
Cflags.private: -DCURL_STATICLIB
EOF
printf 'curl %s swift-os static-http-no-tls\n' "$VERSION" \
    >"$STAGE/usr/share/curl/swiftos-curl.version"

chmod 0755 "$STAGE/usr/bin/curl"
chmod 0644 "$STAGE/usr/include/curl/"*.h "$STAGE/usr/lib/libcurl.a" \
    "$STAGE/usr/lib/pkgconfig/libcurl.pc" \
    "$STAGE/usr/share/curl/swiftos-curl.version"

"$ROOT/build/swport" recipe package net/curl \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture net/curl \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
