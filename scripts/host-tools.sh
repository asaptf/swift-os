# SPDX-License-Identifier: Apache-2.0
#
# host-tools.sh — resolve host-side build/test tools across macOS Homebrew and
# Linux distro layouts. Source from scripts and tests:
#   # shellcheck source=scripts/host-tools.sh
#   source "$(cd "$(dirname "$0")/.." && pwd)/scripts/host-tools.sh"
#
# Prefer (1) an explicit env override if it exists, (2) PATH, (3) common
# install prefixes. Does not exit on failure — callers check return status.

# Resolve an executable by name.
# Usage: host_tool NAME [OVERRIDE_PATH]
# Prints the absolute path on success.
host_tool() {
    local name="$1"
    local override="${2:-}"
    local candidate

    if [[ -n "$override" && -x "$override" ]]; then
        printf '%s\n' "$override"
        return 0
    fi
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    for candidate in \
        "/opt/homebrew/bin/$name" \
        "/opt/homebrew/opt/llvm/bin/$name" \
        "/opt/homebrew/opt/openssl@3/bin/$name" \
        "/usr/local/bin/$name" \
        "/usr/lib/llvm-18/bin/$name" \
        "/usr/lib/llvm-17/bin/$name" \
        "/usr/bin/$name" \
        "/bin/$name" \
        "/usr/sbin/$name" \
        "/sbin/$name"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# Resolve a data file (firmware, etc.) from an ordered candidate list.
# Usage: host_file [OVERRIDE] CANDIDATE...
host_file() {
    local override="${1:-}"
    shift || true
    local candidate

    if [[ -n "$override" && -f "$override" ]]; then
        printf '%s\n' "$override"
        return 0
    fi
    for candidate in "$@"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# QEMU AAVMF / EDK2 aarch64 firmware (UEFI boot tests + disk-run).
# macOS: Homebrew qemu. Linux: qemu-efi-aarch64 (AAVMF) or qemu edk2 blobs.
host_aavmf_code() {
    host_file "${AAVMF_CODE:-}" \
        /opt/homebrew/share/qemu/edk2-aarch64-code.fd \
        /usr/local/share/qemu/edk2-aarch64-code.fd \
        /usr/share/qemu/edk2-aarch64-code.fd \
        /usr/share/AAVMF/AAVMF_CODE.fd \
        /usr/share/AAVMF/AAVMF_CODE.no-secboot.fd \
        /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
}
