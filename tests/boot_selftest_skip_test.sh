#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# boot_selftest_skip_test.sh — default boot skips the heavy pre-login milestone
# demos while still running M7 tty + login (init/console-login).
#
# Asserts:
#   - mode log: "boot: selftest skipped (selftest=1 to enable)"
#   - heavy markers ABSENT (M6/M8a/M8c/M8d/S5b/S5c/S5d/SMPRACE/…)
#   - M7 tty prompt still appears (183 harnesses synchronise on it)
#   - login reaches "swift-os login:" after completing the M7 demo

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${SELFTEST_SKIP_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${SELFTEST_SKIP_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }
[[ -f "$DTB" ]]    || { echo "FAIL: $DTB missing (make build/virt.dtb)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-selftest-skip.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-selftest-skip-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-selftest-skip-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}


drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (boot selftest skip) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

# Default DTB: no selftest=1 in bootargs.
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "boot: selftest skipped (selftest=1 to enable)" 60 \
  || drive_fail "default boot did not log selftest-skipped mode"
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" \
  || drive_fail "M7 tty prompt missing on default boot"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "M7 Ctrl-C prompt missing"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "login prompt missing after M7 on default boot"

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1

grep -qF "boot: selftest skipped (selftest=1 to enable)" <<<"$clean" \
  || { echo "FAIL: missing selftest-skipped mode log" >&2; ok=0; }
grep -qF "M7 tty: type a line then Enter" <<<"$clean" \
  || { echo "FAIL: M7 tty prompt missing" >&2; ok=0; }
grep -qF "swift-os login:" <<<"$clean" \
  || { echo "FAIL: login prompt missing" >&2; ok=0; }

# Heavy milestone markers must be absent on the default path.
ABSENT=(
  "M6 OK: ELF process exited"
  "M8a OK: argv delivered"
  "M8a OK: spawn parent exited"
  "M8b OK: VFS demo exited"
  "M8c OK: newlib program exited"
  "M8d OK: two EL0 processes ran concurrently"
  "M8d OK: fork demo exited"
  "M8e OK: fdops demo exited"
  "S5b OK: three EL0 processes ran with scheduler placement"
  "S5c OK: repeated EL0 placement stress completed"
  "S5d OK: EL0 fanout ran across scheduler CPUs"
  "SMPRACE OK: concurrent EL0 churn completed"
  "M12a OK: identity demo exited"
  "boot: selftest=1: milestone self-tests enabled"
)
for m in "${ABSENT[@]}"; do
  if grep -qF "$m" <<<"$clean"; then
    echo "FAIL: heavy marker present on default boot: $m" >&2
    ok=0
  fi
done

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: default boot skips milestone self-tests; M7 + login still work"
  exit 0
fi
echo "--- serial tail ---" >&2
sed -n '1,200p' <<<"$clean" >&2
exit 1
