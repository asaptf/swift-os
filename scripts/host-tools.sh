# SPDX-License-Identifier: Apache-2.0
#
# host-tools.sh — resolve host-side build/test tools across macOS Homebrew and
# Linux distro layouts. Source from scripts and tests:
#   # shellcheck source=scripts/host-tools.sh
#   source "$(cd "$(dirname "$0")/.." && pwd)/scripts/host-tools.sh"
#
# Prefer (1) an explicit env override if it exists, (2) PATH, (3) common
# install prefixes. Does not exit on failure — callers check return status.

# Sanitize the environment for an autoconf `./configure` of a freestanding
# aarch64-elf (or similar) cross build. Two host-side traps without this:
#
# 1. cross_compiling: with only --host, autoconf sets cross_compiling=maybe and
#    AC_PROG_CC *executes* the linked test binary to decide. On a same-arch host
#    (e.g. ubuntu-24.04-arm CI building aarch64-elf) the freestanding guest
#    binary is loadable and never returns — configure hangs until the job
#    ceiling. Always pass --host *and* --build (see autoconf_cross_build_arg).
#
# 2. EXEEXT pollution: with CLICOLOR_FORCE=1 (common on macOS), configure's
#    `ls conftest.*` command substitution embeds ANSI escapes into ac_cv_exeext.
#    Generated Makefiles then fail with "missing separator" (not a BSD-vs-GNU
#    make quirk). Clearing color force-vars makes ls emit bare names.
#
# Call before invoking ./configure. Safe to call multiple times.
# shellcheck disable=SC2034  # exported for child configure
autoconf_cross_prepare() {
    unset CLICOLOR_FORCE
    export CLICOLOR=0
    export LS_COLORS=
    # Freestanding Unix-like target: a.out with no extension (matches aarch64-elf).
    # Pre-seed so a polluted prior shell env cannot leak into config.cache.
    export ac_cv_exeext=
    export ac_cv_objext=o
}

# Print `--build=<canonical>` using the package's config.guess (must be run
# from the directory that contains config.guess, typically the unpacked SRC).
# Usage: ./configure --host=aarch64-elf $(autoconf_cross_build_arg) ...
autoconf_cross_build_arg() {
    local guess
    if [[ -x ./config.guess ]]; then
        guess=$(./config.guess)
    elif [[ -x ./build-aux/config.guess ]]; then
        guess=$(./build-aux/config.guess)
    elif [[ -x ./config/config.guess ]]; then
        guess=$(./config/config.guess)
    else
        printf 'autoconf_cross_build_arg: no config.guess in %s\n' "$PWD" >&2
        return 1
    fi
    printf -- '--build=%s\n' "$guess"
}

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
