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
    gettext                  # msgfmt — GLib's configure requires it (ci · ports)
    git
    libssl-dev             # openssl headers for native tools
    lld
    llvm
    mtools                   # mformat/mcopy/mdir — ESP population (no root mount)
    openssl                  # CLI for TLS/ACME host-side test helpers
    perl
    python3
    qemu-efi-aarch64         # AAVMF firmware for UEFI boot tests
    ripgrep                  # rg — used by smp_release_guard_test and friends
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
    llvm-objdump
    mcopy
    mformat
    msgfmt
    openssl
    qemu-system-aarch64
    sgdisk
)

export DEBIAN_FRONTEND=noninteractive

# GitHub ubuntu-24.04-arm runners intermittently fail apt over IPv6 to
# ports.ubuntu.com ("Network is unreachable") and sometimes time out on IPv4.
# Force IPv4 and fall back to a kernel.org ubuntu-ports mirror when needed.
APT_OPTS=(-o Acquire::ForceIPv4=true -o Acquire::Retries=5)

# Ordered ubuntu-ports mirrors (arm64 lives under ports, not archive.ubuntu.com).
PORTS_MIRRORS=(
    http://ports.ubuntu.com/ubuntu-ports
    http://mirrors.kernel.org/ubuntu-ports
    http://mirror.math.princeton.edu/pub/ubuntu-ports
)

rewrite_ports_mirror() {
    local mirror="$1"
    local f
    shopt -s nullglob
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        # Rewrite both classic .list and deb822 .sources URI forms.
        sudo sed -i \
            -e "s|https\\?://ports\\.ubuntu\\.com/ubuntu-ports|${mirror}|g" \
            -e "s|https\\?://mirrors\\.kernel\\.org/ubuntu-ports|${mirror}|g" \
            -e "s|https\\?://mirror\\.math\\.princeton\\.edu/pub/ubuntu-ports|${mirror}|g" \
            "$f" 2>/dev/null || true
    done
    shopt -u nullglob
}

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

bins_ok() {
    local b
    for b in "${REQUIRED_BINS[@]}"; do
        if ! command -v "$b" >/dev/null 2>&1; then
            return 1
        fi
    done
    return 0
}

missing_packages() {
    local pkg
    missing=()
    for pkg in "${PACKAGES[@]}"; do
        if ! pkg_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done
}

missing_packages
if [[ ${#missing[@]} -eq 0 ]] && bins_ok; then
    echo "ci-install-deps: all packages already installed"
    exit 0
fi

# Up to 2 full passes over the mirror list (each mirror gets a couple tries).
pass=0
for mirror in "${PORTS_MIRRORS[@]}" "${PORTS_MIRRORS[@]}"; do
    pass=$((pass + 1))
    echo "==> apt mirror [$pass]: $mirror"
    rewrite_ports_mirror "$mirror"

    missing_packages
    if [[ ${#missing[@]} -eq 0 ]] && bins_ok; then
        echo "ci-install-deps: OK"
        exit 0
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Installing: ${missing[*]}"
        if ! apt_update; then
            echo "warn: apt-get update failed for $mirror" >&2
            continue
        fi
        if ! apt_install "${missing[@]}"; then
            echo "warn: apt-get install failed for $mirror" >&2
        fi
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
    sleep 3
done

echo "ci-install-deps: FAILED — required packages/binaries still missing after mirror fallbacks" >&2
exit 100
