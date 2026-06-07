#!/usr/bin/env bash
# mmap_test.sh — Track B acceptance: anonymous mmap/munmap (B1).
#
# Boots the kernel (-kernel) with the packed base image attached, satisfies the
# M7 tty demo (a line + Ctrl-C), logs in as root, then runs /bin/mmapdemo, which
# maps anonymous memory, confirms it reads as 0, round-trips a write/read pattern
# across a page boundary, and munmaps. (B2 — mprotect + W^X — extends this.)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

DISK="$ROOT/build/base.img"
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-mmap.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-mmap-pid.XXXXXX)"
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

blk_args=()
if [[ -f "$DISK" ]]; then
  blk_args=(-global virtio-mmio.force-legacy=false \
            -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
            -device virtio-blk-device,drive=swosbase)
fi

(
  sleep 7;  printf 'tty-line\n'        # M7 ttydemo: a line
  sleep 1;  printf '\003'              # Ctrl-C -> ttydemo exits, console-login starts
  sleep 2;  printf 'root\n'            # log in at the init prompt
  sleep 1;  printf 'swordfish\n'
  sleep 2;  printf '/bin/mmapdemo\n'
  sleep 3;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 27
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "mmapdemo: B1-OK" <<<"$clean" || { echo "FAIL: B1 anon mmap (zero/write/read/munmap)" >&2; ok=0; }
grep -qF "mmapdemo: ALL-OK" <<<"$clean" || { echo "FAIL: mmapdemo did not finish cleanly" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: anonymous mmap/munmap (Track B B1 acceptance)"
  exit 0
fi
echo "--- serial (mmapdemo region) ---" >&2
sed -n '/mmapdemo/,$p' <<<"$clean" | head -30 >&2
echo "--- tail ---" >&2
tail -20 <<<"$clean" >&2
exit 1
