#!/usr/bin/env bash
# run_in_virtual_box.sh — build the swift-os UEFI disk image and convert it to a
# VirtualBox VDI, after verifying (and offering to install) every dependency.
#
#   1. checks the host tooling needed to build the image and run VirtualBox,
#      plus the one-time userland cross-builds (newlib sysroot + busybox.elf);
#   2. offers to install anything missing (Homebrew formulae + the VirtualBox
#      cask automatically; the Swift Embedded toolchain with confirmation) and
#      runs the one-time `make newlib` / `make busybox` builds if absent;
#   3. runs:  make disk
#             VBoxManage convertfromraw build/swift-os.img build/swift-os.vdi --format VDI
#
# Target host: macOS on Apple Silicon (VirtualBox ARM is the M10.5 validation
# target). See docs/VIRTUALBOX.md for creating the VM and capturing the console.
#
# Flags:
#   --check   only check dependencies and report; install nothing, build nothing
#   -y|--yes  assume "yes" to every install prompt (non-interactive)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

CHECK_ONLY=0
AUTO_YES=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        -y|--yes) AUTO_YES=1 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# ---- pretty output ---------------------------------------------------------
if [[ -t 1 ]]; then
    B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
    B=""; G=""; Y=""; R=""; N=""
fi
say()  { echo "${B}==>${N} $*"; }
ok()   { echo "  ${G}ok${N}   $*"; }
miss() { echo "  ${Y}need${N} $*"; }
err()  { echo "${R}error:${N} $*" >&2; }

confirm() {
    # confirm "question" -> 0 if yes
    [[ "$AUTO_YES" -eq 1 ]] && return 0
    local reply
    read -r -p "  install $1? [Y/n] " reply || return 1
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# ---- platform guard --------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    err "this script targets macOS (Apple Silicon + VirtualBox ARM)."
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "${Y}warning:${N} VirtualBox ARM guests need an Apple Silicon host; continuing anyway."
fi

# ---- Homebrew --------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    miss "Homebrew (package manager)"
    if [[ "$CHECK_ONLY" -eq 1 ]]; then
        err "Homebrew is required; install from https://brew.sh"
        exit 1
    fi
    if confirm "Homebrew"; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        err "Homebrew is required to install the remaining dependencies."
        exit 1
    fi
fi
BREW_PREFIX="$(brew --prefix)"

# ---- Homebrew formulae -----------------------------------------------------
# Required to build the image: clang/llvm-objcopy (llvm), ld.lld + lld-link
# (lld), mformat/mcopy (mtools), sgdisk (gptfdisk).
# Recommended (only needed to rebuild from a clean tree): qemu, aarch64-elf-gcc.
declare -a MISSING_REQ=()
declare -a MISSING_OPT=()

check_formula() { # name  test-binary  required(1/0)
    local name="$1" probe="$2" required="$3"
    if [[ -x "$probe" ]] || command -v "$probe" >/dev/null 2>&1; then
        ok "$name"
    else
        miss "$name"
        if [[ "$required" -eq 1 ]]; then MISSING_REQ+=("$name"); else MISSING_OPT+=("$name"); fi
    fi
}

say "Checking build tools"
check_formula llvm           "$BREW_PREFIX/opt/llvm/bin/clang"     1
check_formula lld            "$BREW_PREFIX/opt/lld/bin/lld-link"   1
check_formula mtools         "mformat"                            1
check_formula gptfdisk       "sgdisk"                             1
check_formula qemu           "qemu-system-aarch64"                0
check_formula aarch64-elf-gcc "aarch64-elf-gcc"                   0

install_formulae() {
    local -a list=("$@")
    [[ ${#list[@]} -eq 0 ]] && return 0
    say "Installing: ${list[*]}"
    brew install "${list[@]}"
}

if [[ ${#MISSING_REQ[@]} -gt 0 || ${#MISSING_OPT[@]} -gt 0 ]]; then
    if [[ "$CHECK_ONLY" -eq 0 ]]; then
        if [[ ${#MISSING_REQ[@]} -gt 0 ]]; then
            if confirm "required formulae (${MISSING_REQ[*]})"; then
                install_formulae "${MISSING_REQ[@]}"
            else
                err "cannot build the image without: ${MISSING_REQ[*]}"
                exit 1
            fi
        fi
        if [[ ${#MISSING_OPT[@]} -gt 0 ]]; then
            if confirm "recommended formulae (${MISSING_OPT[*]}, needed only for a clean rebuild)"; then
                install_formulae "${MISSING_OPT[@]}"
            fi
        fi
    fi
fi

# ---- Swift Embedded toolchain ---------------------------------------------
# Not a Homebrew package; pinned at swift.org 6.3.2-RELEASE (see docs/NOTES.md).
# The Makefile (TOOLCHAIN ?=) looks user-locally in ~/Library, but swift.org's
# installer also offers "for all users" -> /Library. Accept either; if only the
# system copy exists, symlink it into the user-local path the build expects.
SWIFT_TC="$HOME/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain"
SWIFT_TC_SYS="/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain"
SWIFT_PKG_URL="https://download.swift.org/swift-6.3.2-release/xcode/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE-osx.pkg"
SWIFT_OK=0

say "Checking Swift Embedded toolchain"
if [[ -x "$SWIFT_TC/usr/bin/swiftc" ]]; then
    ok "swift-6.3.2-RELEASE toolchain"
    SWIFT_OK=1
elif [[ -x "$SWIFT_TC_SYS/usr/bin/swiftc" ]]; then
    # Installed "for all users"; link it where the Makefile looks.
    if [[ "$CHECK_ONLY" -eq 0 ]]; then
        mkdir -p "$(dirname "$SWIFT_TC")"
        ln -snf "$SWIFT_TC_SYS" "$SWIFT_TC"
        ok "swift-6.3.2-RELEASE toolchain (linked $SWIFT_TC -> /Library)"
    else
        ok "swift-6.3.2-RELEASE toolchain (in /Library; will link on build)"
    fi
    SWIFT_OK=1
else
    miss "swift-6.3.2-RELEASE Embedded toolchain ($SWIFT_TC)"
    if [[ "$CHECK_ONLY" -eq 0 ]]; then
        if confirm "the Swift toolchain (downloads the official ~700MB pkg and extracts it user-locally)"; then
            tmp_pkg="$(mktemp -t swift-tc).pkg"
            tmp_dir="$(mktemp -d -t swift-tc-expand)"
            say "Downloading $SWIFT_PKG_URL"
            curl -fL --progress-bar -o "$tmp_pkg" "$SWIFT_PKG_URL"
            say "Expanding to $SWIFT_TC"
            rm -rf "$tmp_dir"
            pkgutil --expand-full "$tmp_pkg" "$tmp_dir"
            mkdir -p "$(dirname "$SWIFT_TC")"
            # The xctoolchain payload is the directory containing usr/bin. We key
            # off swift-driver (a real file) rather than swiftc, which ships as a
            # symlink (-> swift-driver) that `find -type f` would skip.
            driver="$(find "$tmp_dir" -path '*/usr/bin/swift-driver' -print -quit)"
            payload_root="${driver%/usr/bin/swift-driver}"
            if [[ -n "$payload_root" && -x "$payload_root/usr/bin/swiftc" ]]; then
                rm -rf "$SWIFT_TC"
                cp -R "$payload_root" "$SWIFT_TC"
                ok "installed swift-6.3.2-RELEASE toolchain"
                SWIFT_OK=1
            else
                err "could not locate swiftc inside the expanded package."
                echo "  Install manually: download $SWIFT_PKG_URL and place the .xctoolchain at:" >&2
                echo "    $SWIFT_TC" >&2
                rm -f "$tmp_pkg"; rm -rf "$tmp_dir"
                exit 1
            fi
            rm -f "$tmp_pkg"; rm -rf "$tmp_dir"
        else
            err "the Swift toolchain is required to build the kernel."
            echo "  Download $SWIFT_PKG_URL and extract it to $SWIFT_TC" >&2
            exit 1
        fi
    fi
fi

# ---- VirtualBox ------------------------------------------------------------
find_vboxmanage() {
    if command -v VBoxManage >/dev/null 2>&1; then
        command -v VBoxManage
    elif [[ -x /Applications/VirtualBox.app/Contents/MacOS/VBoxManage ]]; then
        echo /Applications/VirtualBox.app/Contents/MacOS/VBoxManage
    fi
}

say "Checking VirtualBox"
VBOXMANAGE="$(find_vboxmanage || true)"
if [[ -n "${VBOXMANAGE:-}" ]]; then
    ok "VirtualBox ($("$VBOXMANAGE" --version 2>/dev/null || echo present))"
else
    miss "VirtualBox"
    if [[ "$CHECK_ONLY" -eq 0 ]]; then
        if confirm "VirtualBox (brew --cask virtualbox)"; then
            brew install --cask virtualbox
            VBOXMANAGE="$(find_vboxmanage || true)"
        fi
    fi
    if [[ -z "${VBOXMANAGE:-}" && "$CHECK_ONLY" -eq 0 ]]; then
        err "VirtualBox / VBoxManage not found after install."
        exit 1
    fi
fi

# ---- userland prerequisites (one-time cross-builds) ------------------------
# `make disk` bakes the newlib-linked userland + busybox into the kernel blob.
# Both are one-time builds (download + cross-compile) that live outside git:
# the newlib sysroot and build/busybox.elf. Each needs the aarch64-elf GNU
# toolchain (the recommended formulae above) and network access.
SYSROOT_LIB="sysroot/aarch64-elf/lib/libc.a"
BUSYBOX_ELF="build/busybox.elf"
NEED_NEWLIB=0
NEED_BUSYBOX=0

say "Checking userland prerequisites"
if [[ -f "$SYSROOT_LIB" ]]; then ok "newlib sysroot"; else miss "newlib sysroot (make newlib)";  NEED_NEWLIB=1;  fi
if [[ -f "$BUSYBOX_ELF" ]]; then ok "busybox.elf";    else miss "busybox (make busybox)";       NEED_BUSYBOX=1; fi

# ---- check-only stops here -------------------------------------------------
if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if [[ ${#MISSING_REQ[@]} -gt 0 || -z "${VBOXMANAGE:-}" || "$SWIFT_OK" -ne 1 \
          || "$NEED_NEWLIB" -eq 1 || "$NEED_BUSYBOX" -eq 1 ]]; then
        echo
        err "missing required dependencies (see 'need' above). Re-run without --check to install/build."
        exit 1
    fi
    say "All required dependencies present."
    exit 0
fi

# ---- build the userland prerequisites if missing ---------------------------
if [[ "$NEED_NEWLIB" -eq 1 ]]; then
    say "Building newlib into ./sysroot (one-time; downloads + cross-compiles)"
    make newlib
fi
if [[ "$NEED_BUSYBOX" -eq 1 ]]; then
    say "Building busybox (one-time; downloads + cross-compiles)"
    make busybox
fi

# ---- build the image + convert to VDI --------------------------------------
say "Building the bootable disk image (make disk)"
make disk

IMG="build/swift-os.img"
VDI="build/swift-os.vdi"
[[ -f "$IMG" ]] || { err "$IMG was not produced by 'make disk'."; exit 1; }

say "Converting $IMG -> $VDI (VirtualBox VDI)"
rm -f "$VDI"
"$VBOXMANAGE" convertfromraw "$IMG" "$VDI" --format VDI

echo
say "${G}Done.${N} VirtualBox disk: $ROOT/$VDI"
echo "Next, create the VM and capture the console — see docs/VIRTUALBOX.md:"
echo "  • New ARM 64-bit VM, 256 MB RAM, 1 CPU, EFI enabled"
echo "  • Attach $VDI as the hard disk"
echo "  • Serial Port 1 -> Raw File (e.g. /tmp/swiftos-serial.log) to capture output"
echo "  • Boot, wait ~15s, then send back the lines starting with 'UEFI:'"
