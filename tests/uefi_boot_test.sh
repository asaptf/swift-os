#!/usr/bin/env bash
# uefi_boot_test.sh - M10 acceptance: boot to busybox from disk via UEFI firmware.
#
# Boots QEMU `virt` with the prebuilt AAVMF/edk2 firmware (NOT `-kernel`). The
# default path uses the real GPT disk image produced by `make disk`; set
# UEFI_BOOT=fat to use the older QEMU virtual-FAT ESP path. The loader locates
# the device tree, stages the embedded kernel, ExitBootServices, and jumps into
# it. We then drive the kernel exactly like the `-kernel` busybox test.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ESP_DIR="$ROOT/build/esp"
EFI_APP="$ESP_DIR/EFI/BOOT/BOOTAA64.EFI"
DISK_IMG="$ROOT/build/swift-os.img"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
UEFI_BOOT="${UEFI_BOOT:-disk}"

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }

drive_args=()
if [[ "$UEFI_BOOT" == "disk" ]]; then
    [[ -f "$DISK_IMG" ]] || { echo "FAIL: $DISK_IMG missing (run 'make disk')" >&2; exit 2; }
    drive_args=(-drive "file=$DISK_IMG,format=raw,if=virtio")
elif [[ "$UEFI_BOOT" == "fat" ]]; then
    [[ -f "$EFI_APP" ]] || { echo "FAIL: $EFI_APP missing (run 'make uefi')" >&2; exit 2; }
    drive_args=(-drive "file=fat:rw:$ESP_DIR,format=raw,if=virtio")
else
    echo "FAIL: unknown UEFI_BOOT=$UEFI_BOOT (use disk or fat)" >&2
    exit 2
fi

# Attach the packed base image as a second, modern virtio-blk disk: the firmware
# still boots off the first (ESP/GPT) disk, while the kernel serves the
# read-only base and /bin/* from this one (it picks the SWOSBASE disk).
DISK="$ROOT/build/base.img"
if [[ -f "$DISK" ]]; then
    drive_args+=(-global virtio-mmio.force-legacy=false \
                 -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
                 -device virtio-blk-device,drive=swosbase)
fi

LOG="$(mktemp -t swiftos-uefi.XXXXXX)"
IN="$(mktemp -u -t swiftos-uefi-in.XXXXXX)"
mkfifo "$IN"
QP=""
cleanup() {
    [[ -n "$QP" ]] && kill "$QP" 2>/dev/null
    exec 3>&- 2>/dev/null || true
    rm -f "$LOG" "$IN"
}
trap cleanup EXIT

wait_for() {
    local needle="$1"
    local tenths="${2:-300}"
    for _ in $(seq 1 "$tenths"); do
        grep -qF "$needle" "$LOG" 2>/dev/null && return 0
        kill -0 "$QP" 2>/dev/null || return 1
        sleep 0.1
    done
    return 1
}

send_text() {  # send_text TEXT
    local text="$1" i
    for (( i = 0; i < ${#text}; i++ )); do
        printf '%s' "${text:i:1}" >&3 || return 1
        sleep 0.02
    done
}

# acpi=off -> firmware publishes the FDT table the loader hands to the kernel.
"$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
        -bios "$AAVMF_CODE" \
        "${drive_args[@]}" <"$IN" >"$LOG" 2>&1 &
QP=$!

exec 3<>"$IN"
wait_for "M7 tty: type a line then Enter" 350 && send_text $'tty-line\n'
wait_for "M7 tty: running; press Ctrl-C" 120 && send_text $'\003'
# M12c: console-login is the init program — authenticate before the shell.
if wait_for "swift-os login:" 120; then
    send_text $'root\n'
    wait_for "Password:" 60 || true
    send_text $'swordfish\n'
fi
if wait_for "built-in shell (ash)" 120; then
    send_text $'echo M10\'\'-UEFI-OK\n'
    wait_for "M10-UEFI-OK" 80 || true
    send_text $'ls /\n'
    wait_for "readme.txt" 80 || true
    send_text $'cat /etc/motd\n'
    wait_for "Welcome to swift-os." 80 || true
    send_text $'exit\n'
fi
exec 3>&-

kill "$QP" 2>/dev/null
wait "$QP" 2>/dev/null
QP=""

ok=1
check() { grep -qF "$1" "$LOG" || { echo "FAIL: missing '$1'" >&2; ok=0; }; }
check "swift-os UEFI loader (M10)"            # loader ran under firmware
check "UEFI: kernel staged, launching"        # ExitBootServices handoff
check "Hello from Swift kernel"               # kernel entered via UEFI
check "M9 OK: hardware discovered from device tree"  # DTB the loader passed
check "built-in shell (ash)"                  # busybox came up
check "M10-UEFI-OK"                           # echo applet
check "readme.txt"                            # ls applet
grep -c "Welcome to swift-os." "$LOG" | grep -qvx 0 || { echo "FAIL: cat applet" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
    echo "PASS: UEFI firmware booted swift-os to busybox from $UEFI_BOOT (M10 acceptance)"
    exit 0
fi
echo "--- serial log ---" >&2
sed 's/\r//' "$LOG" >&2
exit 1
