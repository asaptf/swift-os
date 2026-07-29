#!/usr/bin/env bash
# smp_resource_stress_test.sh — S4f acceptance: resource churn under SMP boot.
#
# This deliberately stays within the current S2h scheduler contract: general
# EL0 work still runs on CPU0, while secondary CPUs are online, ticking, and
# handling the existing SMP probes. The stress re-runs process/VFS/pipe/tmpfs
# paths after the boot demos so S4a-S4e lock boundaries have to remain balanced
# across sustained post-boot userland resource churn.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
# shellcheck source=tests/lib/bootargs.sh
source "$ROOT/tests/lib/bootargs.sh"
SEND_CHAR_DELAY="${S4F_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${S4F_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DISK="$ROOT/build/base.img"
SMP_CPUS="${SMP_CPUS:-4}"
SMP_DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$SMP_DTB" && "$SMP_CPUS" == "4" ]]; then
  ( cd "$ROOT" && make build/virt-smp4.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt-smp4.dtb" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-s4f.XXXXXX)"
SELFTEST_DTB=""
PIDFILE="$(mktemp -t swiftos-s4f-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-s4f-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO" "${SELFTEST_DTB:-}"' EXIT

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
  echo "--- serial (S4f resource stress) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}


qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPUS" -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
# Opt-in: this harness asserts boot-time S4a–S4e "stayed balanced" markers from
# the milestone self-test path.
if [[ -f "$SMP_DTB" ]]; then
  SELFTEST_DTB="$(mktemp -t swiftos-s4f-selftest.XXXXXX.dtb)"
  bake_selftest_dtb "$SMP_DTB" "$SELFTEST_DTB" || exit 2
  qemu_args+=(-device "loader,file=$SELFTEST_DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -kernel "$KERNEL")
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 60 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"

await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
send_line '/bin/forkdemo; echo S4F-FORK-RC=$?'
await "S4F-FORK-RC=0" 180 || drive_fail "fork/IPC handle-transfer stress failed"
send_line '/bin/fdopsdemo; echo S4F-FDOPS-RC=$?'
await "S4F-FDOPS-RC=0" 180 || drive_fail "fd/pipe/tmpfs stress failed"
send_line '/bin/execdemo; echo S4F-EXEC-RC=$?'
await "S4F-EXEC-RC=3" 120 || drive_fail "exec stress did not return expected code"
send_line '/bin/threadsdemo; echo S4F-THREADS-RC=$?'
await "S4F-THREADS-RC=0" 120 || drive_fail "threads/futex stress failed"
send_line 'for i in 1 2 3 4 5 6; do mkdir /tmp/s4f$i; echo data$i > /tmp/s4f$i/a; cat /tmp/s4f$i/a | cat > /tmp/s4f$i/b; /bin/mv /tmp/s4f$i/b /tmp/s4f$i/c; /bin/rm /tmp/s4f$i/a; /bin/rm -r /tmp/s4f$i; done; echo S4F-TMPFS-DONE'
await "S4F-TMPFS-DONE" 180 || drive_fail "tmpfs churn loop did not finish"
send_line 'if [ -e /tmp/s4f1 ]; then echo S4F-TMPFS-LEFT; else echo S4F-TMPFS-CLEAN; fi'
await "S4F-TMPFS-CLEAN" 60 || drive_fail "tmpfs churn left stale directories"
send_line 'echo S4F-RESOURCE-STRESS-DONE'
await "S4F-RESOURCE-STRESS-DONE" 60 || drive_fail "resource stress completion marker missing"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
check_marker() { # <marker> <message>
  grep -qF "$1" <<<"$clean" || { echo "FAIL: $2" >&2; ok=0; }
}

check_marker "S4a OK: PMM lock boundary stayed balanced" "S4a PMM boundary did not stay balanced"
check_marker "S4b OK: VFS lock boundary stayed balanced" "S4b VFS boundary did not stay balanced"
check_marker "S4c OK: kernel heap lock boundary stayed balanced" "S4c heap boundary did not stay balanced"
check_marker "S4d OK: package-store lock boundary stayed balanced" "S4d package-store boundary did not stay balanced"
check_marker "S4e OK: network lock boundary stayed balanced" "S4e network boundary did not stay balanced"
check_marker "S4F-FORK-RC=0" "fork stress command failed"
check_marker "S4F-FDOPS-RC=0" "fdops stress command failed"
check_marker "S4F-EXEC-RC=3" "exec stress command returned an unexpected status"
check_marker "S4F-THREADS-RC=0" "threads stress command failed"
check_marker "S4F-TMPFS-CLEAN" "tmpfs churn did not clean up"
check_marker "S4F-RESOURCE-STRESS-DONE" "resource stress completion missing"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: S4f SMP resource stress exercised fork/exec/fd/pipe/tmpfs/thread churn under -smp $SMP_CPUS"
  exit 0
fi
echo "--- serial (S4f stress region) ---" >&2
sed -n '/S4F-FORK-RC/,$p' <<<"$clean" >&2
exit 1
