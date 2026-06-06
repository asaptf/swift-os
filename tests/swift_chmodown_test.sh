#!/usr/bin/env bash
# swift_chmodown_test.sh — native Swift /bin/chmod and /bin/chown.
#
# Changes mode/owner of a tmpfs file and confirms via /bin/ls -l. chmod/chown
# only affect the writable tmpfs (the base FS is read-only) and require
# capTmpWrite. Invoked by absolute path so the busybox shell execs our binaries.

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

LOG="$(mktemp -t swiftos-cm.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-cm-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

(
  sleep 8;  printf 'tty-line\n'
  sleep 1;  printf '\003'
  sleep 3;  printf 'root\n'
  sleep 1.5;  printf 'swordfish\n'
  sleep 3;  printf 'echo hi > /tmp/f\n'
  sleep 2;  printf '/bin/chmod 600 /tmp/f\n'
  sleep 2;  printf '/bin/ls -l /tmp/f\n'          # expect -rw------- ... root
  sleep 2;  printf '/bin/chown 2 /tmp/f\n'         # principal 2 = user
  sleep 2;  printf '/bin/ls -l /tmp/f\n'           # expect -rw------- ... user user
  sleep 2;  printf 'echo CHOWN-DONE\n'
  sleep 2;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 38
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
check() { grep -Eq -- "$1" <<<"$clean" || { echo "FAIL: $2" >&2; ok=0; }; }

check '^-rw------- +1 +root +root +3 +/tmp/f$'  "chmod 600 not reflected (expected -rw------- root)"
check '^-rw------- +1 +user +user +3 +/tmp/f$'  "chown 2 not reflected (expected owner/group user)"
check 'CHOWN-DONE'                              "shell did not survive chmod/chown"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: native Swift chmod/chown change tmpfs mode and owner (shown by ls -l)"
  exit 0
fi
echo "--- serial (chmod/chown region) ---" >&2
sed -n '/chmod/,$p' <<<"$clean" | head -30 >&2
exit 1
