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
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
ESP_DIR="$ROOT/build/esp"
EFI_APP="$ESP_DIR/EFI/BOOT/BOOTAA64.EFI"
DISK_IMG="$ROOT/build/swift-os.img"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="$(host_aavmf_code)" || true
UEFI_BOOT="${UEFI_BOOT:-disk}"
SMP_CPUS="${SMP_CPUS:-1}"

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }
if [[ ! "$SMP_CPUS" =~ ^[0-9]+$ ]] || (( 10#$SMP_CPUS < 1 || 10#$SMP_CPUS > 8 )); then
    echo "FAIL: SMP_CPUS must be 1..8 for the parked-SMP UEFI smoke, got '$SMP_CPUS'." >&2
    exit 2
fi
SMP_CPU_COUNT=$((10#$SMP_CPUS))

LOG="$(mktemp -t swiftos-uefi.XXXXXX)"
IN="$(mktemp -u -t swiftos-uefi-in.XXXXXX)"
WORK_DISK=""
mkfifo "$IN"
QP=""
cleanup() {
    [[ -n "$QP" ]] && kill "$QP" 2>/dev/null
    exec 3>&- 2>/dev/null || true
    rm -f "$LOG" "$IN" "$WORK_DISK"
}
trap cleanup EXIT

drive_args=()
# U1g-4: the ESP/GPT boot disk is attached on virtio-MMIO (if=none + a modern
# virtio-blk-device), not if=virtio (PCI). AAVMF boots from it, AND the kernel —
# which only drives virtio-mmio — can reach it to read the kernel A/B manifest.
drive_args=(-global virtio-mmio.force-legacy=false)
if [[ "$UEFI_BOOT" == "disk" ]]; then
    [[ -f "$DISK_IMG" ]] || { echo "FAIL: $DISK_IMG missing (run 'make disk')" >&2; exit 2; }
    WORK_DISK="$(mktemp -t swiftos-uefi-disk.XXXXXX)"
    "$ROOT/scripts/make-disk.sh" "$WORK_DISK" >/dev/null \
        || { echo "FAIL: could not create a fresh UEFI disk image (run 'make disk')" >&2; exit 2; }
    drive_args+=(-drive "file=$WORK_DISK,format=raw,if=none,id=esp,cache=writethrough" \
                 -device virtio-blk-device,drive=esp)
elif [[ "$UEFI_BOOT" == "fat" ]]; then
    [[ -f "$EFI_APP" ]] || { echo "FAIL: $EFI_APP missing (run 'make uefi')" >&2; exit 2; }
    drive_args+=(-drive "file=fat:rw:$ESP_DIR,format=raw,if=none,id=esp" -device virtio-blk-device,drive=esp)
else
    echo "FAIL: unknown UEFI_BOOT=$UEFI_BOOT (use disk or fat)" >&2
    exit 2
fi

# Attach the packed base image as a second virtio-mmio disk: the firmware boots
# off the ESP/GPT disk, while the kernel serves the read-only base and /bin/* from
# this one (it picks the SWOSBASE disk).
DISK="$ROOT/build/base.img"
if [[ -f "$DISK" ]]; then
    drive_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
                 -device virtio-blk-device,drive=swosbase)
fi

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
"$QEMU" -M virt,acpi=off -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic -no-reboot \
        -bios "$AAVMF_CODE" \
        "${drive_args[@]}" <"$IN" >"$LOG" 2>&1 &
QP=$!

exec 3<>"$IN"
wait_for "M7 tty: type a line then Enter" $((DEMO_BOOT_TIMEOUT * 10)) && send_text $'tty-line\n'
wait_for "M7 tty: running; press Ctrl-C" 480 && send_text $'\003'
# M12c: console-login is the init program — authenticate before the shell.
if wait_for "swift-os login:" 480; then
    send_text $'root\n'
    wait_for "Password:" 240 || true
    send_text $'swordfish\n'
fi
if wait_for "M12c: shell ready" 480; then
    await_shell_ready "$LOG" 60 || { echo "FAIL: guest shell not reading after login" >&2; exit 1; }
    send_text $'echo M10\'\'-UEFI-OK\n'
    wait_for "M10-UEFI-OK" 240 || true
    send_text $'ls /\n'
    wait_for "readme.txt" 240 || true
    send_text $'cat /etc/motd\n'
    wait_for "Welcome to swift-os." 240 || true
    send_text $'exit\n'
fi
exec 3>&-

kill "$QP" 2>/dev/null
wait "$QP" 2>/dev/null
QP=""

ok=1
check() { grep -qF "$1" "$LOG" || { echo "FAIL: missing '$1'" >&2; ok=0; }; }
check "swift-os UEFI loader (M10)"            # loader ran under firmware
check "UEFI: kernel loaded from ESP file"     # U1g: kernel read from the ESP, not the embedded blob
check "UEFI: kernel staged, launching"        # ExitBootServices handoff
# U1g-4a: with the ESP/GPT disk on virtio-mmio, the kernel locates the ESP it
# was booted from (only the real GPT disk has a GPT; the fat path has none).
if [[ "$UEFI_BOOT" == "disk" ]]; then
    check "kernel-store: ESP partition found at LBA"
    # U1g-4b: the kernel reads the signed kernel A/B manifest from FAT32 (default
    # disk is active slot A).
    check "kernel-store: ESP kernel A/B active slot A"
fi
check "Hello from Swift kernel"               # kernel entered via UEFI
check "M9 OK: hardware discovered from device tree"  # DTB the loader passed
check "[I] smp: S0 OK: foundations ready"       # primary still owns kernel work
check "[I] smp: S0b OK: atomics and barriers ready"
check "[I] smp: S0d OK: per-CPU state ready"
check "[I] smp: S0e OK: secondary park mailbox ready"
check "[I] smp: S0f OK: CPU topology ready detail=$SMP_CPU_COUNT"
check "[I] smp: S0g OK: PSCI discovery ready"
if (( SMP_CPU_COUNT > 1 )); then
    psci_mask=$(((1 << SMP_CPU_COUNT) - 1))
    check "[I] smp: S0g OK: PSCI discovery ready detail=$psci_mask"
fi
cpu=0
while (( cpu < SMP_CPU_COUNT )); do
    check "[I] smp: S2a OK: per-CPU timer heartbeat ready detail=$((cpu + 1))"
    if (( cpu == 0 )); then
        check "[I] smp: S1 CPU online"
    else
        check "[I] smp: S1 CPU online detail=$cpu"
    fi
    cpu=$((cpu + 1))
done
check "[I] smp: S2a OK: scheduler boundary held detail=$SMP_CPU_COUNT"
check "[I] smp: S1 OK: secondary CPUs online detail=$SMP_CPU_COUNT"
check "[I] smp: S2a OK: scheduler owner ready"
check "[I] smp: S2b OK: process scheduler context scaffold ready"
check "[I] smp: S2c OK: kernel scheduler owner ready"
check "[I] smp: S2d OK: process run queue scaffold ready"
check "[I] smp: S2e OK: dormant process scheduler CPUs published"
check "[I] smp: S2f OK: process dispatch telemetry ready"
check "[I] smp: S2h OK: secondary EL0 gate ready"
check "[I] smp: S3a OK: address-space CPU mask scaffold ready"
check "[I] smp: S3b OK: GIC SGI IPI substrate ready"
check "[I] smp: S3c OK: TLB shootdown IPI scaffold ready"
check "[I] smp: S3d OK: address-space TLB flush facade ready"
check "[I] smp: S4a OK: PMM lock boundary ready"
check "[I] smp: S4d OK: package-store lock boundary ready"
check "[I] smp: S4b OK: VFS lock boundary ready"
check "[I] smp: S4c OK: kernel heap lock boundary ready"
check "[I] smp: S4e OK: network lock boundary ready"
# Default boot skips the heavy pre-login demos (selftest=1 restores them on the
# -kernel path; firmware FDT has no bootargs). Still require M7 + multi-CPU EL0
# enable + userland.
check "boot: selftest skipped (selftest=1 to enable)"
check "[I] smp: S5g OK: default multi-CPU EL0 placement enabled"
check "M12c: shell ready"                  # busybox came up
check "M10-UEFI-OK"                           # echo applet
check "readme.txt"                            # ls applet
grep -c "Welcome to swift-os." "$LOG" | grep -qvx 0 || { echo "FAIL: cat applet" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
    echo "PASS: UEFI firmware booted swift-os to busybox from $UEFI_BOOT with -smp $SMP_CPU_COUNT (M10/S0–S5a readiness + M7/login; demos opt-in via selftest=1)"
    exit 0
fi
echo "--- serial log ---" >&2
sed 's/\r//' "$LOG" >&2
exit 1
