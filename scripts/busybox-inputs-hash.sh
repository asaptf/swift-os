#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# busybox-inputs-hash.sh — content fingerprint of every tree-owned input that
# ends up inside build/busybox.elf (see scripts/build-busybox.sh).
#
# Mtimes are intentionally ignored: GitHub Actions cache restore rewrites them,
# so a content hash is the only reliable staleness signal in CI.
#
# Usage:
#   ./scripts/busybox-inputs-hash.sh            # print sha256 hex of the manifest
#   ./scripts/busybox-inputs-hash.sh --list     # print tracked repo-relative paths
#   ./scripts/busybox-inputs-hash.sh --check    # 0 if build/busybox.elf + stamp match
#
# When adding a source compile/link input to build-busybox.sh, register it in
# list_file_inputs below (or under a tracked directory tree). The guard test
# tests/busybox_inputs_guard_test.sh fails if the build script gains an input
# this list does not cover.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/ci/toolchain.env" ]]; then
    # shellcheck source=ci/toolchain.env
    source "$ROOT/ci/toolchain.env"
fi
VERSION="${BUSYBOX_VERSION:-1.38.0}"

# Real files whose bytes feed build/busybox.elf (compile, link script, isystem
# headers, the build recipe itself, and this tracker so algorithm changes bust
# the stamp). Keep in sync with scripts/build-busybox.sh.
list_file_inputs() {
    echo "scripts/build-busybox.sh"
    echo "scripts/busybox-inputs-hash.sh"
    echo "userland/lib/crt0_newlib.S"
    echo "userland/lib/newlib_syscalls.c"
    echo "userland/compat/stubs.c"
    echo "userland/user_newlib.ld"
    # -isystem userland/compat: every header/source under the tree is an input.
    find userland/compat -type f | LC_ALL=C sort
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
    local tmp path
    tmp="$(mktemp "${TMPDIR:-/tmp}/busybox-inputs.XXXXXX")"
    {
        printf 'BUSYBOX_VERSION=%s\n' "$VERSION"
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            if [[ ! -f "$path" ]]; then
                echo "FAIL: busybox input missing: $path" >&2
                rm -f "$tmp"
                exit 2
            fi
            printf '%s  %s\n' "$(sha256_file "$path")" "$path"
        done < <(list_file_inputs | LC_ALL=C sort -u)
    } | LC_ALL=C sort >"$tmp"
    sha256_file "$tmp"
    rm -f "$tmp"
}

stamp_path() {
    echo "$ROOT/build/busybox.inputs-hash"
}

cmd="${1:-}"
case "$cmd" in
    --list)
        list_file_inputs | LC_ALL=C sort -u
        ;;
    --check)
        elf="$ROOT/build/busybox.elf"
        stamp="$(stamp_path)"
        if [[ ! -f "$elf" ]]; then
            echo "busybox.elf missing" >&2
            exit 1
        fi
        if [[ ! -f "$stamp" ]]; then
            echo "busybox.inputs-hash missing (unstamped binary)" >&2
            exit 1
        fi
        expected="$(compute_hash)"
        recorded="$(tr -d '[:space:]' <"$stamp")"
        if [[ "$expected" != "$recorded" ]]; then
            echo "busybox inputs-hash mismatch" >&2
            echo "  expected: $expected" >&2
            echo "  recorded: $recorded" >&2
            exit 1
        fi
        exit 0
        ;;
    "")
        compute_hash
        ;;
    *)
        echo "usage: $0 [--list|--check]" >&2
        exit 2
        ;;
esac
