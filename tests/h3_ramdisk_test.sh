#!/usr/bin/env bash
# h3_ramdisk_test.sh — H3 acceptance: boot to login from a RAM base image with
# NO block driver bound.
#
# Boots the GPT disk under UEFI on the Hetzner-faithful device model — GICv3,
# the boot disk on virtio-scsi-pci (which the kernel does NOT drive) — so there
# is no virtio-blk disk at all. The loader reads base.img from the ESP into RAM
# and hands the kernel a ramdisk; the kernel mounts the read-only base FS from
# RAM, runs the userland from it, and reaches the login prompt. This proves the
# root FS works without writing a virtio-scsi driver (the H3 plan).
#
# Asserts, in order: the loader staged base.img into RAM, no virtio-blk disk was
# bound, the base mounted (signature-verified) from RAM, and the system reached
# login — then logs in and runs a command served from the RAM base.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK_IMG="$ROOT/build/swift-os.img"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }
[[ -f "$DISK_IMG" ]]   || { echo "FAIL: $DISK_IMG missing (run 'make disk' after 'make base-image')" >&2; exit 2; }

LOG="$(mktemp -t swiftos-h3.XXXXXX)"
IN="$(mktemp -u -t swiftos-h3-in.XXXXXX)"
mkfifo "$IN"
QP=""
cleanup() {
    [[ -n "$QP" ]] && kill "$QP" 2>/dev/null
    exec 3>&- 2>/dev/null || true
    rm -f "$LOG" "$IN"
}
trap cleanup EXIT

wait_for() {
    local needle="$1" tenths="${2:-300}"
    for _ in $(seq 1 "$tenths"); do
        grep -qF "$needle" "$LOG" 2>/dev/null && return 0
        kill -0 "$QP" 2>/dev/null || return 1
        sleep 0.1
    done
    return 1
}
send_text() {
    local text="$1" i
    for (( i = 0; i < ${#text}; i++ )); do printf '%s' "${text:i:1}" >&3 || return 1; sleep 0.02; done
}

# Hetzner-faithful: GICv3, boot disk on virtio-scsi-pci (no virtio-blk), virtio
# over PCIe. The firmware reads the ESP (kernel + base.img); the kernel binds no
# block device and serves the base from the RAM image the loader staged.
"$QEMU" -M virt,gic-version=3 -cpu max -smp 2 -m 4G -nographic -no-reboot \
        -bios "$AAVMF_CODE" \
        -drive "file=$DISK_IMG,format=raw,if=none,id=hdd" \
        -device virtio-scsi-pci -device scsi-hd,drive=hdd \
        -device virtio-rng-pci \
        <"$IN" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$IN"

# Drive the interactive milestones the boot path runs before login.
wait_for "M7 tty: type a line then Enter" 2400 && send_text $'tty-line\n'
wait_for "M7 tty: running; press Ctrl-C" 600 && send_text $'\003'
if wait_for "swift-os login:" 600; then
    send_text $'root\n'
    wait_for "Password:" 240 || true
    send_text $'swordfish\n'
fi
if wait_for "built-in shell (ash)" 600; then
    send_text $'echo H3''-RAMDISK-OK\n'
    wait_for "H3-RAMDISK-OK" 240 || true
    send_text $'exit\n'
fi
exec 3>&-
kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null; QP=""

ok=1
check() { grep -qF "$1" "$LOG" || { echo "FAIL: missing '$1'" >&2; ok=0; }; }
check "base.img staged in RAM"                 # loader read base.img from the ESP
check "H3 ramdisk: base"                       # kernel received the ramdisk handoff
check "M11b: no virtio-blk disk attached"      # no block driver bound
check "base image signature verified"          # RAM base read + ed25519-verified
check "M11c: read-only base mounted from disk" # base FS mounted (from RAM)
check "swift-os login:"                        # booted to login
check "H3-RAMDISK-OK"                           # a command ran, served from the RAM base

if [[ "$ok" == 1 ]]; then
    echo "PASS: booted to login from a RAM base image with no block driver bound"
    exit 0
fi
echo "--- tail ---"; sed 's/\r//' "$LOG" | tail -30
exit 1
