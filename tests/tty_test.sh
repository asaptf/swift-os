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
QEMU="${QEMU:-qemu-system-aarch64}"

if [[ ! -f "$KERNEL" ]]; then
    echo "FAIL: $KERNEL not found — run 'make build' first." >&2
    exit 2
fi

LOG="$(mktemp -t swiftos-tty.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

# Boot → (tty demo blocks on read) → type "ping" → (loop) → Ctrl-C.
( sleep 1.5; printf 'ping\n'; sleep 1.5; printf '\003'; sleep 2 ) | \
    "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -kernel "$KERNEL" \
    >"$LOG" 2>&1 &
QEMU_PID=$!

sleep 6
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

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
