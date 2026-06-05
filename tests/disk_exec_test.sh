#!/usr/bin/env bash
# disk_exec_test.sh - M11d acceptance: exec programs from the packed base image.
#
# Attaches build/base.img as a modern virtio-blk disk. The image contains real
# ELFs under /bin, so the kernel should launch the final busybox shell from
# /bin/busybox on disk and the shell's `ps` command should exec /bin/ps from
# the same packed base image.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
  rm -f "$LOG" "$PIDFILE"
}
trap cleanup EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

(
  sleep 7;  printf 'tty-line\n'
  sleep 1;  printf '\003'
  sleep 2;  printf 'ps\n'
  sleep 1;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=disk0,readonly=on" \
  -device virtio-blk-device,drive=disk0 \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 16
stop_qemu
QP=""

ok=1
grep -qF "M11c: read-only base mounted from disk" "$LOG" || { echo "FAIL: base was not mounted from disk" >&2; ok=0; }
grep -qF "M11d: busybox loaded from disk (/bin/busybox)" "$LOG" || { echo "FAIL: busybox was not loaded from disk" >&2; ok=0; }
grep -qF "M11d: exec loaded from disk /bin/ps" "$LOG" || { echo "FAIL: /bin/ps was not exec'd from disk" >&2; ok=0; }
grep -qE "PID +PPID +STATE +CMD" "$LOG" || { echo "FAIL: ps output missing" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: busybox and /bin/ps executed from packed base image (M11d acceptance)"
  exit 0
fi
echo "--- serial (disk exec region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/M11c:/,$p' >&2
exit 1
