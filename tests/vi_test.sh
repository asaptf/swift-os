#!/usr/bin/env bash
# vi_test.sh — busybox vi acceptance: busybox vi edits and saves a file.
#
# Boot ends with the M7 tty demo, then console-login. We satisfy the tty demo
# (a line + Ctrl-C), log in as root, then drive busybox vi:
#   vi /tmp/vitest        open a new tmpfs file (full-screen, raw mode)
#   i hello-from-vi <ESC> insert text
#   :wq                   write (open+full_write+ftruncate) and quit
#   cat /tmp/vitest       read it back  -> proves the bytes were saved
# Asserts vi's alt-screen banner, the read-back content, and a trailing marker
# (the latter proves the kernel did NOT panic and the shell kept running —
# the bug this milestone fixed crashed the kernel inside poll()).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-vi.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-vi-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
cleanup() { stop_qemu; rm -f "$LOG" "$PIDFILE"; }
trap cleanup EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
blk_args=(-global virtio-mmio.force-legacy=false \
          -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
          -device virtio-blk-device,drive=swosbase)

(
  sleep 8;  printf 'tty-line\n'          # M7 ttydemo: a line
  sleep 1;  printf '\003'                # Ctrl-C -> ttydemo exits, console-login starts
  sleep 2;  printf 'root\n'              # log in
  sleep 1;  printf 'swordfish\n'
  sleep 2;  printf 'vi /tmp/vitest\n'    # open vi on a new tmpfs file
  sleep 2;  printf 'ihello-from-vi'      # insert mode + text
  sleep 1;  printf '\033'                # ESC -> command mode
  sleep 1;  printf ':wq\n'               # write + quit
  sleep 2;  printf 'cat /tmp/vitest\n'   # read the saved file back
  sleep 1;  printf 'echo VI-DONE-MARKER\n'
  sleep 1;  printf 'exit\n'
  sleep 2
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 35
stop_qemu
QP=""

ok=1
clean="$(sed 's/\r//' "$LOG")"
grep -qaF $'\x1b[?1049h' "$LOG"     || { echo "FAIL: vi did not enter the alternate screen" >&2; ok=0; }
# Match the cat output as a CLEAN line (^...$), not vi's on-screen echo of the
# inserted text (which is embedded in cursor-positioning escapes) — so this
# truly asserts the file was saved, not merely typed.
grep -qE '^hello-from-vi$' <<<"$clean" || { echo "FAIL: saved file content not read back (vi :wq / ftruncate)" >&2; ok=0; }
grep -qa "VI-DONE-MARKER" "$LOG"    || { echo "FAIL: shell did not survive vi (kernel panic in poll?)" >&2; ok=0; }
grep -qa "panic" "$LOG"             && { echo "FAIL: kernel panic during vi" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: busybox vi edited and saved /tmp/vitest on swift-os (busybox vi)"
  exit 0
fi
echo "--- serial (vi region) ---" >&2
sed 's/\r//' "$LOG" | sed -n '/launching busybox/,$p' >&2
exit 1
