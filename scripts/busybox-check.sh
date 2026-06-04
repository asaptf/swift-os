#!/usr/bin/env bash
# busybox-check.sh — reproducible M8d5 feasibility probe.
#
# This is not the final in-OS busybox launch. It pins the upstream source/config
# and proves the current newlib/POSIX compatibility surface can produce a static
# AArch64 busybox binary for ash + ls/cat/echo.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${BUSYBOX_VERSION:-1.38.0}"
WORK="$ROOT/userland/busybox"
TARBALL="$WORK/busybox-${VERSION}.tar.bz2"
SRC="$WORK/busybox-${VERSION}"
URL="https://busybox.net/downloads/busybox-${VERSION}.tar.bz2"
LOG="$ROOT/build/busybox-check.log"
MIN_CONFIG="$ROOT/build/busybox-min.config"
SYSROOT="$ROOT/sysroot/aarch64-elf"
JOBS="${JOBS:-4}"

mkdir -p "$WORK" "$ROOT/build"

if [[ ! -f "$SYSROOT/lib/libc.a" ]]; then
    echo "FAIL: newlib sysroot missing. Run: make newlib" >&2
    exit 2
fi

if [[ ! -f "$TARBALL" ]]; then
    echo "Fetching busybox ${VERSION}..."
    curl -fsSL -o "$TARBALL" "$URL" || exit 2
fi

if [[ ! -d "$SRC" ]]; then
    tar -xjf "$TARBALL" -C "$WORK" || exit 2
fi

cat >"$MIN_CONFIG" <<'CONFIG_EOF'
CONFIG_STATIC=y
CONFIG_ASH=y
CONFIG_LS=y
CONFIG_CAT=y
CONFIG_ECHO=y
CONFIG_FEATURE_SH_STANDALONE=y
CONFIG_FEATURE_PREFER_APPLETS=y
CONFIG_FEATURE_EDITING=n
CONFIG_FEATURE_HISTORY=n
CONFIG_FEATURE_TAB_COMPLETION=n
CONFIG_FEATURE_EDITING_SAVEHISTORY=n
CONFIG_FEATURE_VERBOSE_USAGE=n
CONFIG_WERROR=n
CONFIG_EFENCE=n
CONFIG_DMALLOC=n
CONFIG_MOUNT=n
CONFIG_UMOUNT=n
CONFIG_SWAPON=n
CONFIG_SWAPOFF=n
CONFIG_FDISK=n
CONFIG_MDEV=n
CONFIG_BLKID=n
CONFIG_FINDFS=n
CONFIG_FEATURE_VOLUMEID=n
CONFIG_UDHCPC=n
CONFIG_IFCONFIG=n
CONFIG_ROUTE=n
CONFIG_IP=n
CONFIG_NETSTAT=n
CONFIG_PING=n
CONFIG_WGET=n
CONFIG_TELNET=n
CONFIG_TFTP=n
CONFIG_HTTPD=n
CONFIG_INETD=n
CONFIG_SYSLOGD=n
CONFIG_KLOGD=n
CONFIG_LOGIN=n
CONFIG_PASSWD=n
CONFIG_SU=n
CONFIG_ADDUSER=n
CONFIG_DELUSER=n
CONFIG_GETTY=n
CONFIG_INIT=n
CONFIG_HALT=n
CONFIG_REBOOT=n
CONFIG_POWEROFF=n
CONFIG_EJECT=n
CONFIG_E2FSCK=n
CONFIG_MKE2FS=n
CONFIG_TUNE2FS=n
CONFIG_E2LABEL=n
CONFIG_CHATTR=n
CONFIG_LSATTR=n
CONFIG_DUMPE2FS=n
CONFIG_DEBUGFS=n
CONFIG_RESIZE2FS=n
CONFIG_MKFS_EXT2=n
CONFIG_FSCK=n
CONFIG_MKFS_MINIX=n
CONFIG_FSCK_MINIX=n
CONFIG_MKFS_VFAT=n
CONFIG_TEST=n
CONFIG_PRINTF=n
CONFIG_TRUE=n
CONFIG_FALSE=n
CONFIG_SLEEP=n
CONFIG_ECHO=y
CONFIG_ECHO_FEATURE_FANCY=n
CONFIG_ECHO_FEATURE_ESCAPE=n
CONFIG_ECHO_FEATURE_NOLF=n
CONFIG_FEATURE_LS_FILETYPES=y
CONFIG_FEATURE_LS_FOLLOWLINKS=n
CONFIG_FEATURE_LS_RECURSIVE=n
CONFIG_FEATURE_LS_SORTFILES=n
CONFIG_FEATURE_LS_TIMESTAMPS=n
CONFIG_FEATURE_LS_USERNAME=n
CONFIG_FEATURE_LS_COLOR=n
CONFIG_FEATURE_CATN=n
CONFIG_FEATURE_CATV=n
CONFIG_EOF

cd "$SRC" || exit 2
make distclean >/dev/null 2>&1 || true
make KCONFIG_ALLCONFIG="$MIN_CONFIG" allnoconfig >"$LOG" 2>&1 || {
    echo "FAIL: busybox config generation failed; see $LOG" >&2
    exit 1
}

set +e
make -j"$JOBS" \
    CROSS_COMPILE=aarch64-elf- \
    CC=aarch64-elf-gcc \
    EXTRA_CFLAGS="-ffreestanding -isystem $ROOT/userland/compat -isystem $SYSROOT/include" \
    EXTRA_LDFLAGS="-nostartfiles -nostdlib -T $ROOT/userland/user_newlib.ld -L $SYSROOT/lib" \
    >>"$LOG" 2>&1
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
    echo "PASS: busybox built: $SRC/busybox"
    exit 0
fi

echo "FAIL: busybox build failed. Log: $LOG" >&2
tail -60 "$LOG" >&2
exit 1
