#!/usr/bin/env bash
# boot_test.sh — M0 acceptance test.
#
# Boots the kernel in QEMU (headless), captures the serial console, and asserts
# the expected banner appears within a timeout. The kernel halts in an infinite
# loop, so QEMU never exits on its own — we poll the log and then kill it.
#
# Exit 0 = banner seen (pass); non-zero = timeout/missing (fail).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
QEMU="${QEMU:-qemu-system-aarch64}"
EXPECT="${EXPECT:-Hello from Swift kernel}"
TIMEOUT="${TIMEOUT:-10}"

if [[ ! -f "$KERNEL" ]]; then
    echo "FAIL: $KERNEL not found — run 'make build' first." >&2
    exit 2
fi

LOG="$(mktemp -t swiftos-boot.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

# -no-reboot/-no-shutdown keep QEMU from looping; serial goes to the log.
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
        -kernel "$KERNEL" >"$LOG" 2>&1 &
QEMU_PID=$!

found=0
for _ in $(seq 1 "$((TIMEOUT * 10))"); do
    if grep -qF "$EXPECT" "$LOG" 2>/dev/null; then
        found=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break  # QEMU died early.
    fi
    sleep 0.1
done

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

if [[ "$found" -eq 1 ]]; then
    echo "PASS: serial console produced: \"$EXPECT\""
    exit 0
fi

echo "FAIL: \"$EXPECT\" not seen within ${TIMEOUT}s. Serial log was:" >&2
echo "---------------------------------------------" >&2
cat "$LOG" >&2
echo "---------------------------------------------" >&2
exit 1
