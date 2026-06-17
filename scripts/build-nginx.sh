#!/usr/bin/env bash
# build-nginx.sh - cross-build minimal static nginx and publish a package.
#
# Produces:
#   build/nginx.swpkg
#   build/nginx-repo-root/aarch64/current/catalog.signed
#   build/nginx-repo-root.pub

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${NGINX_VERSION:-1.30.2}"
DISTFILES="${NGINX_DISTFILES:-$ROOT/build/swport-distfiles}"
WORK="$ROOT/build/nginx-port-work"
SRC="$WORK/nginx-${VERSION}"
TARBALL="$DISTFILES/nginx-${VERSION}.tar.gz"
LOG="$ROOT/build/nginx-build.log"
BUILD_DIR="$ROOT/build/nginx"
OBJS="$BUILD_DIR/objs"
OVERLAY="$ROOT/userland/nginx/swiftos"
COMPAT="$ROOT/userland/compat"
STAGE="$ROOT/build/nginx-root"
PACKAGE="$ROOT/build/nginx.swpkg"
REPO_ROOT="$ROOT/build/nginx-repo-root"
REPO_PUB="$ROOT/build/nginx-repo-root.pub"
CC="${NGINX_CC:-aarch64-elf-gcc}"
JOBS="${NGINX_JOBS:-${JOBS:-4}}"

if [[ -n "${NGINX_SYSROOT:-}" ]]; then
    SYSROOT="$NGINX_SYSROOT"
elif [[ -f "$ROOT/sysroot/newlib/aarch64-elf/lib/libc.a" ]]; then
    SYSROOT="$ROOT/sysroot/newlib/aarch64-elf"
elif [[ -f "$ROOT/sysroot/aarch64-elf/lib/libc.a" ]]; then
    # Older notes/scripts install newlib here.  Keep the nginx probe usable
    # until the sysroot layout is unified.
    SYSROOT="$ROOT/sysroot/aarch64-elf"
else
    SYSROOT="$ROOT/sysroot/newlib/aarch64-elf"
fi

mkdir -p "$DISTFILES" "$WORK" "$ROOT/build" "$BUILD_DIR"
: >"$LOG"

log() {
    printf '%s\n' "$*" | tee -a "$LOG"
}

fail() {
    local code="$1"
    shift
    {
        printf 'FAIL: %s\n' "$*"
        printf 'Log: %s\n' "$LOG"
        printf '%s\n' '--- last 80 log lines ---'
        tail -80 "$LOG" 2>/dev/null || true
    } >&2
    exit "$code"
}

run() {
    log "+ $*"
    "$@" >>"$LOG" 2>&1
    local code=$?
    if [[ "$code" -ne 0 ]]; then
        fail "$code" "command failed: $*"
    fi
}

run_in_src() {
    log "+ (cd $SRC && $*)"
    (cd "$SRC" && "$@") >>"$LOG" 2>&1
    local code=$?
    if [[ "$code" -ne 0 ]]; then
        fail "$code" "command failed in nginx source: $*"
    fi
}

if [[ "${NGINX_CLEAN:-0}" = "1" ]]; then
    log "Cleaning nginx source/build artifacts for ${VERSION}"
    rm -rf "$SRC" "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
fi

log "nginx package version: $VERSION"
log "sysroot: $SYSROOT"

command -v tar >/dev/null 2>&1 || fail 2 "missing tar"
command -v patch >/dev/null 2>&1 || fail 2 "missing patch"
command -v "$CC" >/dev/null 2>&1 || fail 2 "missing compiler: $CC"
[[ -x "$ROOT/build/swport" ]] || fail 2 "missing build/swport; run make swport"
[[ -x "$ROOT/build/swpkg" ]] || fail 2 "missing build/swpkg; run make swpkg"
[[ -x "$ROOT/build/pkgrepo" ]] || fail 2 "missing build/pkgrepo; run make pkgrepo"

run "$ROOT/build/swport" recipe fetch www/nginx --cache "$DISTFILES"

if [[ ! -d "$SRC" ]]; then
    run tar -xzf "$TARBALL" -C "$WORK"
fi

if [[ ! -f "$OVERLAY/crossbuild-machine.patch" ]]; then
    fail 2 "missing nginx swift-os overlay: $OVERLAY"
fi

if ! grep -q 'swift-os crossbuild machine overlay' "$SRC/configure"; then
    log "Applying swift-os crossbuild overlay"
    (cd "$SRC" && patch -p1 <"$OVERLAY/crossbuild-machine.patch") >>"$LOG" 2>&1
    code=$?
    if [[ "$code" -ne 0 ]]; then
        fail "$code" "failed to apply swift-os nginx overlay"
    fi
else
    log "swift-os crossbuild overlay already applied"
fi

if [[ ! -f "$SYSROOT/lib/libc.a" ]]; then
    fail 2 "newlib sysroot missing. Run scripts/build-newlib.sh, or set NGINX_SYSROOT to the installed aarch64-elf sysroot."
fi

rm -rf "$BUILD_DIR"
mkdir -p "$OBJS" "$BUILD_DIR/runtime"

INC="-isystem $OVERLAY/include -isystem $COMPAT -isystem $SYSROOT/include"
RUNTIME_CFLAGS="-ffreestanding -Os $INC"

run "$CC" $RUNTIME_CFLAGS -c "$ROOT/userland/lib/crt0_newlib.S" \
    -o "$BUILD_DIR/runtime/crt0_newlib.o"
run "$CC" $RUNTIME_CFLAGS -c "$ROOT/userland/lib/newlib_syscalls.c" \
    -o "$BUILD_DIR/runtime/newlib_syscalls.o"
run "$CC" $RUNTIME_CFLAGS -c "$ROOT/userland/compat/stubs.c" \
    -o "$BUILD_DIR/runtime/compat_stubs.o"

CC_WRAPPER="$BUILD_DIR/swiftos-cc"
cat >"$CC_WRAPPER" <<EOF
#!/usr/bin/env bash
real_cc="$CC"
compile_flags=(-ffreestanding -Os -Wno-error -isystem "$OVERLAY/include" -isystem "$COMPAT" -isystem "$SYSROOT/include")
link_flags=(-static -nostartfiles -nostdlib -T "$ROOT/userland/user_newlib.ld" -Wl,-z,max-page-size=4096
            "$BUILD_DIR/runtime/crt0_newlib.o"
            "$BUILD_DIR/runtime/newlib_syscalls.o"
            "$BUILD_DIR/runtime/compat_stubs.o"
            -Wl,--start-group -L "$SYSROOT/lib" -lc -lm -lgcc -Wl,--end-group)
mode=link
for arg in "\$@"; do
    case "\$arg" in
        -c|-E|-S) mode=compile ;;
    esac
done
if [[ "\$mode" = compile ]]; then
    exec "\$real_cc" "\${compile_flags[@]}" "\$@"
fi
exec "\$real_cc" "\${compile_flags[@]}" "\$@" "\${link_flags[@]}"
EOF
chmod +x "$CC_WRAPPER"

# W3: link against the swift-os openssl port (static) for TLS.
OPENSSL_ROOT="${NGINX_OPENSSL_ROOT:-$ROOT/build/openssl-root/usr}"
CC_OPT="-I $OPENSSL_ROOT/include"
LD_OPT="-L $OPENSSL_ROOT/lib"

CONFIGURE_ARGS=(
    "--build=swift-os-static-probe"
    "--crossbuild=SwiftOS:0:aarch64"
    "--builddir=$OBJS"
    "--prefix=/usr"
    "--sbin-path=/usr/sbin/nginx"
    "--conf-path=/usr/etc/nginx/nginx.conf"
    "--http-log-path=/tmp/nginx-access.log"
    "--error-log-path=/tmp/nginx-error.log"
    "--pid-path=/tmp/nginx.pid"
    "--lock-path=/tmp/nginx.lock"
    "--user=root"
    "--group=root"
    "--with-cc=$CC_WRAPPER"
    "--with-cc-opt=$CC_OPT"
    "--with-ld-opt=$LD_OPT"
    "--with-http_ssl_module"
    "--with-poll_module"
    "--without-select_module"
    "--without-pcre"
    "--without-pcre2"
    "--without-http-cache"
    "--without-http_charset_module"
    "--without-http_gzip_module"
    "--without-http_ssi_module"
    "--without-http_userid_module"
    "--without-http_access_module"
    "--without-http_auth_basic_module"
    "--without-http_mirror_module"
    "--without-http_autoindex_module"
    "--without-http_geo_module"
    "--without-http_map_module"
    "--without-http_split_clients_module"
    "--without-http_referer_module"
    "--without-http_rewrite_module"
    "--without-http_proxy_module"
    "--without-http_fastcgi_module"
    "--without-http_uwsgi_module"
    "--without-http_scgi_module"
    "--without-http_grpc_module"
    "--without-http_memcached_module"
    "--without-http_limit_conn_module"
    "--without-http_limit_req_module"
    "--without-http_empty_gif_module"
    "--without-http_browser_module"
    "--without-http_upstream_hash_module"
    "--without-http_upstream_ip_hash_module"
    "--without-http_upstream_least_conn_module"
    "--without-http_upstream_random_module"
    "--without-http_upstream_keepalive_module"
    "--without-http_upstream_zone_module"
    "--without-http_upstream_sticky"
    "--without-quic_bpf_module"
)

if [[ -n "${NGINX_CONFIGURE_EXTRA:-}" ]]; then
    # shellcheck disable=SC2206
    EXTRA_ARGS=( $NGINX_CONFIGURE_EXTRA )
    CONFIGURE_ARGS+=("${EXTRA_ARGS[@]}")
fi

run_in_src ./configure "${CONFIGURE_ARGS[@]}"

AUTO_CONFIG="$OBJS/ngx_auto_config.h"
if ! grep -q 'NGX_HAVE_MAP_ANON' "$AUTO_CONFIG"; then
    log "Forcing NGX_HAVE_MAP_ANON for swift-os anonymous mmap"
    {
        printf '\n#ifndef NGX_HAVE_MAP_ANON\n'
        printf '#define NGX_HAVE_MAP_ANON 1\n'
        printf '#endif\n'
    } >>"$AUTO_CONFIG"
fi

run_in_src make -f "$OBJS/Makefile" -j"$JOBS"

run cp "$OBJS/nginx" "$ROOT/build/nginx.elf"
log "Built $ROOT/build/nginx.elf"
run aarch64-elf-readelf -h "$ROOT/build/nginx.elf"

rm -rf "$STAGE" "$PACKAGE" "$REPO_ROOT" "$REPO_PUB"
mkdir -p "$STAGE/usr/sbin" "$STAGE/usr/etc/nginx" \
    "$STAGE/usr/share/nginx/html" "$STAGE/usr/share/nginx"
cp "$ROOT/build/nginx.elf" "$STAGE/usr/sbin/nginx"
cat >"$STAGE/usr/etc/nginx/nginx.conf" <<'EOF'
daemon off;
master_process off;
error_log /tmp/nginx-error.log info;
pid /tmp/nginx.pid;

events {
    worker_connections 16;
}

http {
    access_log off;
    server {
        listen 8080;
        root /usr/share/nginx/html;
        index index.html;
    }
}
EOF
cat >"$STAGE/usr/share/nginx/html/index.html" <<'EOF'
swift-os nginx package
EOF
printf 'nginx %s swift-os minimal-http\n' "$VERSION" \
    >"$STAGE/usr/share/nginx/swiftos-nginx.version"
chmod 0755 "$STAGE/usr/sbin/nginx"
chmod 0644 "$STAGE/usr/etc/nginx/nginx.conf" \
    "$STAGE/usr/share/nginx/html/index.html" \
    "$STAGE/usr/share/nginx/swiftos-nginx.version"

"$ROOT/build/swport" recipe package www/nginx \
    --root "$STAGE" \
    --output "$PACKAGE" \
    --swpkg "$ROOT/build/swpkg"

"$ROOT/build/swport" recipe repo-fixture www/nginx \
    --root "$STAGE" \
    --output "$REPO_ROOT" \
    --pubkey "$REPO_PUB" \
    --swpkg "$ROOT/build/swpkg" \
    --pkgrepo "$ROOT/build/pkgrepo"

printf 'Built %s\n' "$PACKAGE"
printf 'Published signed repo fixture %s\n' "$REPO_ROOT/aarch64/current"
