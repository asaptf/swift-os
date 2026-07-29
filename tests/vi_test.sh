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
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${VI_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${VI_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-vi.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-vi-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-vi-in.XXXXXX)"
mkfifo "$INFIFO"
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
cleanup() { stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"; }
trap cleanup EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
blk_args=(-global virtio-mmio.force-legacy=false \
          -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
          -device virtio-blk-device,drive=swosbase)

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_count() {  # await_count MARKER COUNT [MAXSEC]
  local marker="$1" want="$2" max="${3:-30}" n=0 got=0
  while (( n < max * 10 )); do
    got="$(grep -aoF -- "$marker" "$LOG" 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$got" -ge "$want" ]] && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_clean_regex() {  # await_clean_regex REGEX [MAXSEC]
  local regex="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -qE "$regex" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (vi driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}


"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" "${dtb_args[@]}" "${blk_args[@]}" -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
send_line 'tty-line'                    # M7 ttydemo: a line
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3                       # Ctrl-C -> ttydemo exits, console-login starts
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
send_line 'root'                        # log in
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line 'vi /tmp/vitest'              # open vi on a new tmpfs file
await $'\x1b[?1049h' 120 || drive_fail "vi did not enter the alternate screen"
send_text 'ihello-from-vi'              # insert mode + text
sleep "${VI_TEXT_FLUSH_DELAY:-0.2}"
printf '\033' >&3                       # ESC -> command mode
await_count "- /tmp/vitest" 2 60 || drive_fail "vi did not return to command mode"
send_line ':wq'                         # write + quit
await $'\x1b[?1049l' 120 || drive_fail "vi did not leave the alternate screen"
send_line 'cat /tmp/vitest'             # read the saved file back
await_clean_regex '^hello-from-vi$' 120 || drive_fail "saved file content was not read back"
send_line 'echo VI-DONE-MARKER'
await "VI-DONE-MARKER" 90 || drive_fail "shell did not survive vi"
send_line 'exit'
await "M12c: session ended" 60 || true
exec 3>&-
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
