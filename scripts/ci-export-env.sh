#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ci-export-env.sh — append swift-os Linux CI environment to GITHUB_ENV.
#
# Usage (GitHub Actions step):
#   ./scripts/ci-export-env.sh
#   make ci-test
#
# Local usage:
#   eval "$(./scripts/ci-export-env.sh --print)"

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=ci/toolchain.env
source "$ROOT/ci/toolchain.env"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"

SWIFT_DIR="${SWIFT_INSTALL_DIR:-$HOME/.swift/toolchains/swift-$SWIFT_VERSION}"
ARM_GNU_DIR="${ARM_GNU_INSTALL_DIR:-$HOME/.local/arm-gnu-toolchain}"
LOCAL_BIN="${LOCAL_BIN_DIR:-$HOME/.local/bin}"

export_path="$SWIFT_DIR/usr/bin:$ARM_GNU_DIR/bin:$LOCAL_BIN:${PATH:-}"

llvm_bin=/usr/bin
if [[ -x /usr/lib/llvm-18/bin/clang ]]; then
    llvm_bin=/usr/lib/llvm-18/bin
fi

# Resolve firmware/tools so Make recipes and test scripts share one path.
aavmf_code="$(host_aavmf_code || true)"
sgdisk_bin="$(host_tool sgdisk "${SGDISK:-}" || true)"
mcopy_bin="$(host_tool mcopy "${MCOPY:-}" || true)"
mformat_bin="$(host_tool mformat "${MFORMAT:-}" || true)"
mmd_bin="$(host_tool mmd "${MMD:-}" || true)"
mdir_bin="$(host_tool mdir "${MDIR:-}" || true)"
mdel_bin="$(host_tool mdel "${MDEL:-}" || true)"

emit() {
    printf '%s=%s\n' "$1" "$2"
}

lines=(
    "PATH=$export_path"
    "TOOLCHAIN=$SWIFT_DIR"
    "SWIFTC=$SWIFT_DIR/usr/bin/swiftc"
    "HOST_SWIFTC=$SWIFT_DIR/usr/bin/swiftc"
    "LLVM=$llvm_bin"
    "CLANG=$llvm_bin/clang"
    "LDBIN=$(command -v ld.lld)"
    "OBJCOPY=$(command -v llvm-objcopy || command -v llvm-objcopy-18 || true)"
    "SWOS_SIGNING_PROFILE=${SWOS_SIGNING_PROFILE:-dev}"
)
if [[ -n "$aavmf_code" ]]; then
    lines+=("AAVMF_CODE=$aavmf_code")
fi
if [[ -n "$sgdisk_bin" ]]; then
    lines+=("SGDISK=$sgdisk_bin")
fi
if [[ -n "$mcopy_bin" ]]; then
    lines+=("MCOPY=$mcopy_bin")
fi
if [[ -n "$mformat_bin" ]]; then
    lines+=("MFORMAT=$mformat_bin")
fi
if [[ -n "$mmd_bin" ]]; then
    lines+=("MMD=$mmd_bin")
fi
if [[ -n "$mdir_bin" ]]; then
    lines+=("MDIR=$mdir_bin")
fi
if [[ -n "$mdel_bin" ]]; then
    lines+=("MDEL=$mdel_bin")
fi

if [[ "${1:-}" == "--print" ]]; then
    for line in "${lines[@]}"; do
        printf 'export %s\n' "$line"
    done
    exit 0
fi

if [[ -z "${GITHUB_ENV:-}" ]]; then
    echo "ci-export-env.sh: GITHUB_ENV is not set (use --print for local shells)" >&2
    exit 2
fi

for line in "${lines[@]}"; do
    echo "$line" >>"$GITHUB_ENV"
done