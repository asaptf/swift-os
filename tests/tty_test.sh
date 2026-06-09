#!/usr/bin/env bash
# tty_test.sh — M7 acceptance test: interactive echo + Ctrl-C interrupts.
#
# Drives the kernel through QEMU's stdio serial: after the tty demo blocks on
# read(0), we type a line (expect it echoed and read back), then send Ctrl-C
# (0x03) while the program loops (expect SIGINT to terminate it). Timed sends
# keep the sequence deterministic.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"

if [[ ! -f "$KERNEL" ]]; then
    echo "FAIL: $KERNEL not found — run 'make build' first." >&2
    exit 2
fi

LOG="$(mktemp -t swiftos-tty.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-tty-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-tty-in.XXXXXX)"; mkfifo "$INFIFO"
QEMU_PID=""
stop_qemu() {
    if [[ -f "$PIDFILE" ]]; then
        local pid
        pid="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            sleep 0.2
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    if [[ -n "$QEMU_PID" ]]; then
        wait "$QEMU_PID" 2>/dev/null || true
    fi
}
cleanup() {
    stop_qemu
    exec 3>&- 2>/dev/null || true
    rm -f "$LOG" "$PIDFILE" "$INFIFO"
}
trap cleanup EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
    dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

# Attach the packed base image (modern virtio-mmio) — the demos and tty demo run
# from disk once the embedded blob is gone.
DISK="$ROOT/build/base.img"
blk_args=()
if [[ -f "$DISK" ]]; then
    blk_args=(-global virtio-mmio.force-legacy=false \
              -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
              -device virtio-blk-device,drive=swosbase)
fi

await() {  # await MARKER [MAXSEC]
    local marker="$1" max="${2:-30}" n=0
    while (( n < max * 10 )); do
        grep -qF "$marker" "$LOG" 2>/dev/null && return 0
        sleep 0.1; n=$((n + 1))
    done
    return 1
}

drive_fail() {
    echo "FAIL: $1" >&2
    echo "Serial log was:" >&2
    echo "---------------------------------------------" >&2
    cat -v "$LOG" >&2
    echo "---------------------------------------------" >&2
    exit 1
}

# Boot → (tty demo blocks on read) → type "pinXg", then move the cursor left
# (ESC[D) and backspace to delete the stray 'X', committing "ping" → (loop) →
# Ctrl-C. Asserting read(0) returns "ping" exercises the cooked line editor's
# movable cursor and mid-line delete, not just plain appending.
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" \
    <"$INFIFO" >"$LOG" 2>&1 &
QEMU_PID=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
printf 'pinXg\033[D\177\n' >&3
await "you typed: ping" 30 || drive_fail "typed line was not echoed back by read(0)"
await "M7 tty: running; press Ctrl-C" 30 || drive_fail "timed out waiting for Ctrl-C prompt"
printf '\003' >&3
await "M7 OK: foreground interrupted by Ctrl-C (SIGINT)" 30 || true
exec 3>&-
stop_qemu
QEMU_PID=""

ok=1
grep -qF "you typed: ping" "$LOG" || { echo "FAIL: typed line was not echoed back by read(0)" >&2; ok=0; }
grep -qF "M7 OK: foreground interrupted by Ctrl-C (SIGINT)" "$LOG" || { echo "FAIL: Ctrl-C did not interrupt the running command" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
    echo "PASS: tty echo + read(0) line + Ctrl-C/SIGINT interruption"
    exit 0
fi

echo "Serial log was:" >&2
echo "---------------------------------------------" >&2
cat -v "$LOG" >&2
echo "---------------------------------------------" >&2
exit 1
