#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# boot_selftest_optin_test.sh — FDT /chosen/bootargs selftest=1 restores the
# full pre-login milestone demo sequence.
#
# Complements boot_selftest_skip_test.sh (default = skip). Also covered more
# deeply by tests/boot_test.sh (which opts in and asserts the full marker set).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
# shellcheck source=tests/lib/bootargs.sh
source "$ROOT/tests/lib/bootargs.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }
[[ -f "$DTB" ]]    || { echo "FAIL: $DTB missing (make build/virt.dtb)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-selftest-optin.XXXXXX)"
SELFTEST_DTB="$(mktemp -t swiftos-selftest-optin.XXXXXX.dtb)"
PIDFILE="$(mktemp -t swiftos-selftest-optin-pid.XXXXXX)"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE" "$SELFTEST_DTB"' EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

bake_selftest_dtb "$DTB" "$SELFTEST_DTB" || exit 2

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -device "loader,file=$SELFTEST_DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!

await "boot: selftest=1: milestone self-tests enabled" 60 \
  || { echo "FAIL: selftest=1 mode log missing" >&2; exit 1; }
# Representative heavy markers (full set is asserted by boot_test.sh).
await "M6 OK: ELF process exited, code 7" "$DEMO_BOOT_TIMEOUT" \
  || { echo "FAIL: M6 OK missing with selftest=1" >&2; exit 1; }
await "M8a OK: argv delivered, argc=3" 60 \
  || { echo "FAIL: M8a OK missing with selftest=1" >&2; exit 1; }
await "M8d OK: two EL0 processes ran concurrently" 120 \
  || { echo "FAIL: M8d OK missing with selftest=1" >&2; exit 1; }
await "M7 tty: type a line then Enter" 120 \
  || { echo "FAIL: M7 tty missing after selftest demos" >&2; exit 1; }

stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
for m in \
  "boot: selftest=1: milestone self-tests enabled" \
  "M6 OK: ELF process exited, code 7" \
  "M8a OK: argv delivered, argc=3" \
  "M8d OK: two EL0 processes ran concurrently" \
  "M7 tty: type a line then Enter"; do
  grep -qF "$m" <<<"$clean" || { echo "FAIL: missing $m" >&2; ok=0; }
done
if grep -qF "boot: selftest skipped" <<<"$clean"; then
  echo "FAIL: skip mode log present with selftest=1" >&2
  ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: selftest=1 restores pre-login milestone demos"
  exit 0
fi
echo "--- serial (selftest opt-in) ---" >&2
sed -n '/boot: selftest/,/M7 tty/p' <<<"$clean" | head -80 >&2
exit 1
