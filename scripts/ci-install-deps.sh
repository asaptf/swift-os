#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ci-install-deps.sh — install Ubuntu apt packages for swift-os CI.
#
# Idempotent: safe to re-run; only installs packages that are missing or need
# upgrading. Intended for ubuntu24.04 runners (x86_64 or aarch64).

set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
    echo "ci-install-deps.sh: Linux/Ubuntu only (got $(uname -s))" >&2
    exit 2
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "ci-install-deps.sh: apt-get not found — is this an Ubuntu/Debian host?" >&2
    exit 2
fi

# Core build + test dependencies for swift-os on Linux CI.
PACKAGES=(
    build-essential
    ca-certificates
    clang
    curl
    device-tree-compiler   # dtc
    gdisk                    # sgdisk — GPT for make disk / UEFI tests
    git
    libssl-dev             # openssl headers for native tools
    lld
    llvm
    mtools                   # mformat/mcopy/mdir — ESP population (no root mount)
    perl
    python3
    qemu-efi-aarch64         # AAVMF firmware for UEFI boot tests
    # qemu-system-arm ships the qemu-system-aarch64 binary; the
    # "qemu-system-aarch64" name is a virtual package on Ubuntu and never
    # shows as dpkg-installed on its own.
    qemu-system-arm
    ipxe-qemu                # /usr/share/qemu/efi-virtio.rom for virt DTB dump + NIC boot
    tar
    xz-utils
)

# Binaries that must exist after package install (guards virtual packages / provides).
REQUIRED_BINS=(
    clang
    curl
    dtc
    ld.lld
    mcopy
    mformat
    qemu-system-aarch64
    sgdisk
)

export DEBIAN_FRONTEND=noninteractive

# GitHub ubuntu-24.04-arm runners intermittently fail apt over IPv6 to
# ports.ubuntu.com ("Network is unreachable"). Prefer IPv4 for apt.
APT_OPTS=(-o Acquire::ForceIPv4=true -o Acquire::Retries=5)

apt_update() {
    echo "Updating apt indices ..."
    sudo apt-get update -qq "${APT_OPTS[@]}"
}

apt_install() {
    sudo apt-get install -y --no-install-recommends "${APT_OPTS[@]}" "$@"
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

missing=()
for pkg in "${PACKAGES[@]}"; do
    if ! pkg_installed "$pkg"; then
        missing+=("$pkg")
    fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
    echo "ci-install-deps: all packages already installed"
    exit 0
fi

bins_ok() {
    local b
    for b in "${REQUIRED_BINS[@]}"; do
        if ! command -v "$b" >/dev/null 2>&1; then
            return 1
        fi
    done
    return 0
}

# Retry apt-get update + install: ports.ubuntu.com / IPv6 flakes are common.
attempts=3
for attempt in $(seq 1 "$attempts"); do
    # Refresh the missing list each attempt (partial success is possible).
    missing=()
    for pkg in "${PACKAGES[@]}"; do
        if ! pkg_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]] && bins_ok; then
        echo "ci-install-deps: OK"
        exit 0
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Installing (attempt ${attempt}/${attempts}): ${missing[*]}"
        if ! apt_update || ! apt_install "${missing[@]}"; then
            echo "warn: apt install attempt ${attempt} failed" >&2
        fi
    else
        echo "Packages present; checking required binaries (attempt ${attempt}/${attempts})"
    fi

    if bins_ok; then
        echo "ci-install-deps: OK"
        exit 0
    fi

    still_bins=()
    for b in "${REQUIRED_BINS[@]}"; do
        if ! command -v "$b" >/dev/null 2>&1; then
            still_bins+=("$b")
        fi
    done
    echo "warn: still missing binaries: ${still_bins[*]:-none}" >&2

    if [[ "$attempt" -lt "$attempts" ]]; then
        sleep $((attempt * 5))
    fi
done

echo "ci-install-deps: FAILED — required packages/binaries still missing" >&2
exit 100
