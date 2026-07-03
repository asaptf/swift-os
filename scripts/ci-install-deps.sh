#!/usr/bin/env bash
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
    git
    libssl-dev             # openssl headers for native tools
    lld
    llvm
    perl
    python3
    qemu-system-aarch64
    qemu-system-arm
    tar
    xz-utils
)

export DEBIAN_FRONTEND=noninteractive

need_update=0
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        need_update=1
        break
    fi
done

if [[ "$need_update" -eq 1 ]]; then
    echo "Updating apt indices ..."
    sudo apt-get update -qq
fi

missing=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        missing+=("$pkg")
    fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
    echo "ci-install-deps: all packages already installed"
    exit 0
fi

echo "Installing: ${missing[*]}"
sudo apt-get install -y --no-install-recommends "${missing[@]}"
echo "ci-install-deps: OK"