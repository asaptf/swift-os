#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# artifact-inputs-hash.sh — content fingerprint of every tree-owned input that
# ends up inside a CI-cached binary / port root that embeds our newlib runtime
# (crt0_newlib.S, newlib_syscalls.c, stubs.c, user_newlib.ld).
#
# Mtimes are intentionally ignored: GitHub Actions cache restore rewrites them,
# so a content hash is the only reliable staleness signal in CI. restore-keys
# prefix fallback can rehydrate an older artifact whose mtime looks fresh; the
# stamp written next to the artifact must still match the current tree.
#
# Artifacts covered (the ones Actions caches under build/):
#   busybox  → build/busybox.elf
#   sqlite   → build/sqlite-root (sqlite3 embeds the runtime)
#   nginx    → build/nginx-root  (nginx embeds the runtime)
#   openssl  → build/openssl-root (openssl CLI embeds the runtime; libssl.a is
#              the make target that stages the whole root)
#
# Usage:
#   ./scripts/artifact-inputs-hash.sh <name>            # print sha256 hex
#   ./scripts/artifact-inputs-hash.sh <name> --list     # tracked paths
#   ./scripts/artifact-inputs-hash.sh <name> --check    # 0 if artifact+stamp match
#   ./scripts/artifact-inputs-hash.sh --names            # list known <name>s
#
# When adding a tree-owned compile/link input to a build script, register it in
# list_file_inputs for that artifact (or under a tracked directory tree). The
# guard test tests/busybox_inputs_guard_test.sh fails if a covered build script
# gains an input this list does not track.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/ci/toolchain.env" ]]; then
    # shellcheck source=ci/toolchain.env
    source "$ROOT/ci/toolchain.env"
fi

# Shared runtime linked into every freestanding port binary. Keep in sync with
# the -c / -T / -isystem paths in scripts/build-{busybox,sqlite,nginx,openssl}.sh.
list_runtime_inputs() {
    echo "scripts/artifact-inputs-hash.sh"
    echo "userland/lib/crt0_newlib.S"
    echo "userland/lib/newlib_syscalls.c"
    echo "userland/user_newlib.ld"
    # -isystem userland/compat: every header/source under the tree is an input.
    find userland/compat -type f | LC_ALL=C sort
}

list_file_inputs() {
    local name="$1"
    list_runtime_inputs
    case "$name" in
        busybox)
            echo "scripts/build-busybox.sh"
            echo "scripts/busybox-inputs-hash.sh"
            ;;
        sqlite)
            echo "scripts/build-sqlite.sh"
            echo "ports/databases/sqlite/Port.json"
            ;;
        nginx)
            echo "scripts/build-nginx.sh"
            echo "ports/www/nginx/Port.json"
            # Overlay headers (-isystem) + crossbuild patch applied to the tarball.
            find userland/nginx/swiftos -type f | LC_ALL=C sort
            ;;
        openssl)
            echo "scripts/build-openssl.sh"
            echo "ports/security/openssl/Port.json"
            ;;
        *)
            echo "FAIL: unknown artifact name: $name" >&2
            echo "known: busybox sqlite nginx openssl" >&2
            exit 2
            ;;
    esac
}

version_line() {
    local name="$1"
    case "$name" in
        busybox)
            printf 'BUSYBOX_VERSION=%s\n' "${BUSYBOX_VERSION:-1.38.0}"
            ;;
        sqlite)
            printf 'SQLITE_VERSION=%s\n' "${SQLITE_VERSION:-3.53.2}"
            printf 'SQLITE_DIST_VERSION=%s\n' "${SQLITE_DIST_VERSION:-3530200}"
            ;;
        nginx)
            printf 'NGINX_VERSION=%s\n' "${NGINX_VERSION:-1.30.2}"
            ;;
        openssl)
            printf 'OPENSSL_VERSION=%s\n' "${OPENSSL_VERSION:-3.5.7}"
            ;;
    esac
}

artifact_path() {
    local name="$1"
    case "$name" in
        busybox)  echo "$ROOT/build/busybox.elf" ;;
        sqlite)   echo "$ROOT/build/sqlite-root/usr/bin/sqlite3" ;;
        nginx)    echo "$ROOT/build/nginx-root/usr/sbin/nginx" ;;
        openssl)  echo "$ROOT/build/openssl-root/usr/lib/libssl.a" ;;
    esac
}

stamp_path() {
    local name="$1"
    echo "$ROOT/build/${name}.inputs-hash"
}

sha256_file() {
    local path="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    else
        echo "FAIL: neither shasum nor sha256sum found" >&2
        exit 2
    fi
}

compute_hash() {
    local name="$1"
    local tmp path
    tmp="$(mktemp "${TMPDIR:-/tmp}/${name}-inputs.XXXXXX")"
    {
        version_line "$name"
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            if [[ ! -f "$path" ]]; then
                echo "FAIL: $name input missing: $path" >&2
                rm -f "$tmp"
                exit 2
            fi
            printf '%s  %s\n' "$(sha256_file "$path")" "$path"
        done < <(list_file_inputs "$name" | LC_ALL=C sort -u)
    } | LC_ALL=C sort >"$tmp"
    sha256_file "$tmp"
    rm -f "$tmp"
}

do_check() {
    local name="$1"
    local artifact stamp expected recorded
    artifact="$(artifact_path "$name")"
    stamp="$(stamp_path "$name")"
    if [[ ! -f "$artifact" ]]; then
        echo "$name artifact missing: $artifact" >&2
        exit 1
    fi
    if [[ ! -f "$stamp" ]]; then
        echo "$name.inputs-hash missing (unstamped artifact)" >&2
        exit 1
    fi
    expected="$(compute_hash "$name")"
    recorded="$(tr -d '[:space:]' <"$stamp")"
    if [[ "$expected" != "$recorded" ]]; then
        echo "$name inputs-hash mismatch" >&2
        echo "  expected: $expected" >&2
        echo "  recorded: $recorded" >&2
        exit 1
    fi
    exit 0
}

usage() {
    echo "usage: $0 <busybox|sqlite|nginx|openssl> [--list|--check]" >&2
    echo "       $0 --names" >&2
    exit 2
}

if [[ "${1:-}" == "--names" ]]; then
    printf '%s\n' busybox sqlite nginx openssl
    exit 0
fi

name="${1:-}"
[[ -n "$name" ]] || usage
shift || true

case "$name" in
    busybox|sqlite|nginx|openssl) ;;
    *) usage ;;
esac

cmd="${1:-}"
case "$cmd" in
    --list)
        list_file_inputs "$name" | LC_ALL=C sort -u
        ;;
    --check)
        do_check "$name"
        ;;
    "")
        compute_hash "$name"
        ;;
    *)
        usage
        ;;
esac
