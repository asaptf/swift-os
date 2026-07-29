#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# el0_fault_backtrace_test.sh — EL0 stack-overflow fault report with backtrace.
#
# Boots a dedicated base image with /bin/stackovf as root's login shell (same
# pattern as tests/s4_resource_stress_test.sh). That avoids the interactive
# busybox ash path: this checkout's build/busybox.elf is a deliberate CI binary
# used to reproduce a separate recursion bug and may fault on launch.
#
# /bin/stackovf forks a child that runaway-recurses until the user stack
# overflows. Assertions:
#   1. the kernel logs an EL0 fault with SIGSEGV (signal 0xb) and the first-line
#      prefix through FAR_EL1 is intact;
#   2. the fault report includes greppable EL0 backtrace lines with a collapsed
#      repeat count (count>1) — the property that diagnoses recursion;
#   3. the parent reaps the child (STACKOVF-OK) and continues (STACKOVF-ALIVE),
#      proving the fault never panics or freezes the kernel.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${EL0BT_CHAR_DELAY:-0.02}"
SEND_SEND_DELAY="${EL0BT_SEND_DELAY:-0.12}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

# Dedicated image with /bin/stackovf as root's login shell.
DISK="$ROOT/build/base-stackovf.img"
if [[ ! -f "$DISK" || "$ROOT/userland/stackovf.c" -nt "$DISK" || "$ROOT/Makefile" -nt "$DISK" ]]; then
  ( cd "$ROOT" && make BASE_IMG="$DISK" ROOT_LOGIN_SHELL=/bin/stackovf base-image ) >/dev/null 2>&1 || {
    echo "FAIL: cannot build base-stackovf.img" >&2
    exit 2
  }
fi

LOG="$(mktemp -t swiftos-el0bt.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-el0bt-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-el0bt-in.XXXXXX)"; mkfifo "$INFIFO"
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
    if grep -qF "panic:" "$LOG" 2>/dev/null; then
      return 2
    fi
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (el0 fault backtrace) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}


DTB="${SMP_DTB:-$ROOT/build/virt.dtb}"
if [[ ! -f "$DTB" ]]; then
  tmp_dtb="$DTB.tmp"
  mkdir -p "$(dirname "$DTB")"
  "$QEMU" -M "virt,dumpdtb=$tmp_dtb" -cpu cortex-a72 -smp 1 -m 256M -nographic >/dev/null 2>&1
  mv "$tmp_dtb" "$DTB"
fi

"$QEMU" -M virt -cpu cortex-a72 -smp 1 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# Login only — stackovf is the login shell and runs immediately after auth.
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'

await "M11d: exec loaded from disk /bin/stackovf" 90 || drive_fail "stackovf did not execute"
await "STACKOVF-START deliberate recursion" 30 || drive_fail "stackovf did not start recursion"
# SIGSEGV = 11 = 0xb. First-line prefix through FAR_EL1 must stay intact.
await "EL0 fault -> terminate proc by signal 0x000000000000000B" 60 \
  || drive_fail "kernel did not report EL0 SIGSEGV fault"
await "EL0 backtrace: LR=" 30 || drive_fail "kernel did not emit EL0 backtrace lines"
await "STACKOVF-OK child died with SIGSEGV" 30 || drive_fail "parent did not report SIGSEGV reap"
await "STACKOVF-ALIVE parent continued after child fault" 30 \
  || drive_fail "parent did not continue after child fault"

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1

# First-line contract: prefix through FAR_EL1 (other greps rely on it).
if ! grep -qE 'EL0 fault -> terminate proc by signal 0x000000000000000B ESR_EL1=0x[0-9A-Fa-f]+ ELR_EL1=0x[0-9A-Fa-f]+ FAR_EL1=0x[0-9A-Fa-f]+' <<<"$clean"; then
  echo "FAIL: EL0 fault first-line prefix through FAR_EL1 missing or altered" >&2
  ok=0
fi

# Collapsed recursion: at least one backtrace entry with count > 1.
if ! grep -qE 'EL0 backtrace: LR=0x[0-9A-Fa-f]+ count=([2-9]|[1-9][0-9]+)' <<<"$clean"; then
  echo "FAIL: no collapsed EL0 backtrace repeat (count>1) found" >&2
  ok=0
fi

# Must not have returned from the recursion (would mean stack did not overflow).
grep -qF "STACKOVF-FAIL" <<<"$clean" && {
  echo "FAIL: stackovf reported a failure marker" >&2
  ok=0
}

grep -qF "panic:" <<<"$clean" && {
  echo "FAIL: kernel panic during stack-overflow fault" >&2
  ok=0
}

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: EL0 stack overflow reports collapsed backtrace, dies with SIGSEGV, kernel stays up"
  exit 0
fi
echo "--- serial (el0 fault backtrace region) ---" >&2
sed -n '/stackovf\|STACKOVF\|EL0 fault\|EL0 backtrace/p' <<<"$clean" | head -80 >&2
exit 1
