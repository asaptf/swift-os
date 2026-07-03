#!/usr/bin/env bash
# ci-install-toolchain.sh — download Embedded Swift + ARM GNU toolchain for CI.
#
# Sources ci/toolchain.env, installs into $HOME/.swift/toolchains and
# $HOME/.local/arm-gnu-toolchain, and creates aarch64-elf-* symlinks expected by
# newlib/busybox scripts. Works on x86_64 and aarch64 Ubuntu runners.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=ci/toolchain.env
source "$ROOT/ci/toolchain.env"

SWIFT_DIR="${SWIFT_INSTALL_DIR:-$HOME/.swift/toolchains/swift-$SWIFT_VERSION}"
ARM_GNU_DIR="${ARM_GNU_INSTALL_DIR:-$HOME/.local/arm-gnu-toolchain}"
LOCAL_BIN="${LOCAL_BIN_DIR:-$HOME/.local/bin}"
WORK="${TMPDIR:-/tmp}/swiftos-ci-toolchain"

host_arch="$(uname -m)"
case "$host_arch" in
    x86_64|amd64)
        swift_url="https://download.swift.org/swift-${SWIFT_VERSION%%-*}-release/ubuntu2404/x86_64/swift-${SWIFT_VERSION}/swift-${SWIFT_VERSION}-${UBUNTU_CODENAME}.tar.gz"
        arm_gnu_url="https://developer.arm.com/-/media/Files/downloads/gnu/${ARM_GNU_VERSION}/binrel/arm-gnu-toolchain-${ARM_GNU_VERSION}-x86_64-aarch64-none-elf.tar.xz"
        ;;
    aarch64|arm64)
        swift_url="https://download.swift.org/swift-${SWIFT_VERSION%%-*}-release/ubuntu2404-aarch64/swift-${SWIFT_VERSION}/swift-${SWIFT_VERSION}-${UBUNTU_CODENAME}-aarch64.tar.gz"
        arm_gnu_url="https://developer.arm.com/-/media/Files/downloads/gnu/${ARM_GNU_VERSION}/binrel/arm-gnu-toolchain-${ARM_GNU_VERSION}-aarch64-aarch64-none-elf.tar.xz"
        ;;
    *)
        echo "ci-install-toolchain.sh: unsupported host arch: $host_arch" >&2
        exit 2
        ;;
esac

mkdir -p "$WORK" "$LOCAL_BIN"

install_swift() {
    if [[ -x "$SWIFT_DIR/usr/bin/swiftc" ]]; then
        echo "Swift toolchain already present: $SWIFT_DIR"
        return 0
    fi

    local tarball="$WORK/swift-${SWIFT_VERSION}.tar.gz"
    echo "Fetching Swift $SWIFT_VERSION ($host_arch) ..."
    curl -fsSL -o "$tarball" "$swift_url"

    local extract="$WORK/swift-extract"
    rm -rf "$extract"
    mkdir -p "$extract"
    tar xzf "$tarball" -C "$extract"

    local payload
    payload="$(find "$extract" -mindepth 1 -maxdepth 1 -type d | head -1)"
    if [[ -z "$payload" || ! -x "$payload/usr/bin/swiftc" ]]; then
        echo "FAIL: could not locate swiftc in Swift tarball" >&2
        exit 1
    fi

    rm -rf "$SWIFT_DIR"
    mkdir -p "$(dirname "$SWIFT_DIR")"
    mv "$payload" "$SWIFT_DIR"
    echo "Swift installed -> $SWIFT_DIR"
}

install_arm_gnu() {
    if command -v aarch64-elf-gcc >/dev/null 2>&1; then
        echo "aarch64-elf-gcc already on PATH: $(command -v aarch64-elf-gcc)"
        return 0
    fi

    if [[ -x "$ARM_GNU_DIR/bin/aarch64-none-elf-gcc" ]]; then
        echo "ARM GNU toolchain already present: $ARM_GNU_DIR"
    else
        local tarball="$WORK/arm-gnu-toolchain-${ARM_GNU_VERSION}.tar.xz"
        echo "Fetching ARM GNU toolchain ${ARM_GNU_VERSION} ($host_arch) ..."
        curl -fsSL -o "$tarball" "$arm_gnu_url"

        local extract="$WORK/arm-gnu-extract"
        rm -rf "$extract"
        mkdir -p "$extract"
        tar xJf "$tarball" -C "$extract"

        local payload
        payload="$(find "$extract" -mindepth 1 -maxdepth 1 -type d | head -1)"
        if [[ -z "$payload" || ! -x "$payload/bin/aarch64-none-elf-gcc" ]]; then
            echo "FAIL: could not locate aarch64-none-elf-gcc in ARM GNU tarball" >&2
            exit 1
        fi

        rm -rf "$ARM_GNU_DIR"
        mkdir -p "$(dirname "$ARM_GNU_DIR")"
        mv "$payload" "$ARM_GNU_DIR"
        echo "ARM GNU installed -> $ARM_GNU_DIR"
    fi

    mkdir -p "$LOCAL_BIN"
    for tool in "$ARM_GNU_DIR/bin/aarch64-none-elf-"*; do
        [[ -f "$tool" ]] || continue
        base="$(basename "$tool")"
        link_name="${base/aarch64-none-elf-/aarch64-elf-}"
        ln -sf "$tool" "$LOCAL_BIN/$link_name"
    done
    echo "aarch64-elf-* symlinks -> $LOCAL_BIN"
}

install_swift
install_arm_gnu

echo ""
echo "=== CI toolchain paths ==="
echo "SWIFT_DIR=$SWIFT_DIR"
echo "SWIFTC=$SWIFT_DIR/usr/bin/swiftc"
echo "ARM_GNU_DIR=$ARM_GNU_DIR"
echo "LOCAL_BIN=$LOCAL_BIN"
echo "PATH additions: $SWIFT_DIR/usr/bin:$ARM_GNU_DIR/bin:$LOCAL_BIN"