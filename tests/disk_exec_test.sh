#!/usr/bin/env bash
# disk_exec_test.sh - M11d acceptance: exec programs from the packed base image.
#
# Attaches build/base.img as a modern virtio-blk disk. The image contains real
# ELFs under /bin, so the kernel should launch the final busybox shell from
# /bin/busybox on disk and the shell's `ps` command should exec /bin/ps from
# the same packed base image.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-disk-exec.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-disk-exec-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-disk-exec-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
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
  if [[ -n "$QP" ]]; then
    wait "$QP" 2>/dev/null || true
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
  echo "--- serial (disk exec driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M11c:/,$p' >&2 || true
  exit 1
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=disk0,readonly=on" \
  -device virtio-blk-device,drive=disk0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
printf 'tty-line\n' >&3
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
printf 'root\n' >&3
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
printf 'swordfish\n' >&3
await "Welcome to swift-os, root" 120 || drive_fail "root login did not complete"
printf 'ps\n' >&3
await "M11d: exec loaded from disk /bin/ps" 60 || drive_fail "/bin/ps was not exec'd from disk"
await "PID PPID STATE CMD" 60 || drive_fail "ps output missing"
printf 'exit\n' >&3
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

ok=1
grep -qF "M11c: read-only base mounted from disk" "$LOG" || { echo "FAIL: base was not mounted from disk" >&2; ok=0; }
grep -qF "M11d: exec loaded from disk /bin/console-login" "$LOG" || { echo "FAIL: console-login was not loaded from disk" >&2; ok=0; }
grep -qF "M11d: exec loaded from disk /bin/busybox" "$LOG" || { echo "FAIL: busybox was not loaded from disk" >&2; ok=0; }
grep -qF "M11d: exec loaded from disk /bin/ps" "$LOG" || { echo "FAIL: /bin/ps was not exec'd from disk" >&2; ok=0; }
grep -qE "PID +PPID +STATE +CMD" "$LOG" || { echo "FAIL: ps output missing" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: busybox and /bin/ps executed from packed base image (M11d acceptance)"
  exit 0
fi
echo "--- serial (disk exec region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/M11c:/,$p' >&2
exit 1
