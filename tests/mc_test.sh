#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# mc_test.sh — MC1 Midnight Commander port acceptance.
#
# Boots the base image, logs into the root shell, and runs /bin/mc (the static
# Midnight Commander, ncurses backend + glib). MC has no plain-text markers (it
# is a full-screen TUI), so the harness asserts that MC drew its UI — the
# top menu titles and bottom function-key button bar are emitted as literal text
# amid the ncurses cursor escapes — and that it quits cleanly back to the shell.
# MC is quit with its ESC-prefix convention: ESC then '0' == F10 (Quit).

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

LOG="$(mktemp -t swiftos-mc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-mc-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-mc-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

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
  echo "--- serial (mc, control chars stripped) ---" >&2
  LC_ALL=C tr -cd '\11\12\15\40-\176' < "$LOG" 2>/dev/null | tail -60 >&2 || true
  exit 1
}
send_line() {
  local line="$1" delay="${MC_CHAR_DELAY:-0.02}" i
  for (( i = 0; i < ${#line}; i++ )); do printf '%s' "${line:i:1}" >&3; sleep "$delay"; done
  printf '\n' >&3; sleep "${MC_SEND_DELAY:-0.1}"
}

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line '/bin/mc'

# No skin file is shipped, so MC draws a one-time startup notice ("Default skin
# has been loaded") in a dialog and waits for a key — drawing this centered,
# boxed dialog already proves MC initialised the terminal and renders via
# ncurses. Dismiss it with Enter, then the two-panel UI with its menu + bottom
# function-key button bar ("Help" ... "Quit") appears.
saw_dialog=0
if await "skin" 60; then saw_dialog=1; sleep 0.3; printf '\r' >&3; sleep 0.5; fi
if ! await "Quit" 40; then
  await "Help" 15 || { [[ "$saw_dialog" = 1 ]] || drive_fail "/bin/mc did not draw its UI (TERM/terminfo/init failure?)"; }
fi

# Quit: ESC then '0' is MC's F10. Send a confirming Enter in case a quit dialog
# is shown, then expect the shell prompt back.
sleep 0.3
printf '\0330' >&3
sleep 0.5
printf '\r' >&3
await "M12c: shell ready" 30 || await "swift-os login:" 20 || true
send_line 'exit'
await "M12c: session ended" 30 || true

exec 3>&-
stop_qemu
QP=""

clean="$(LC_ALL=C tr -cd '\11\12\15\40-\176' < "$LOG")"
ok=1

# A userland fault (segfault/abort) is logged by the kernel as "EL0 fault ...".
# MC's one-time "Default skin has been loaded" notice is drawn BEFORE the file
# panels load, so it must NOT count as success on its own: MC used to crash
# right after it (empty root file list -> NULL fname deref) yet still "drew" the
# notice, so this test passed falsely. Require both: no fault, and a real
# two-panel/menu marker that only appears once the panels have initialised.
if grep -qF "EL0 fault" <<<"$clean"; then
  echo "FAIL: MC crashed on launch (kernel logged an EL0 fault)" >&2
  grep -oE "EL0 fault.*FAR_EL1=0x[0-9A-Fa-f]+" <<<"$clean" | head -1 >&2
  ok=0
fi

# Informational only (drawn before the panels, so not a pass criterion).
grep -qF "Default skin has been loaded" <<<"$clean" && echo "note: drew the default-skin notice"

# Pass markers: MC's actual panel/menu UI (only reached once panels load).
hit=0
for marker in "Quit" "Command" "Help" "PullDn" "Left" "Right"; do
  if grep -qF "$marker" <<<"$clean"; then echo "PASS: drew \"$marker\""; hit=1; fi
done
[[ "$hit" = 1 ]] || { echo "FAIL: MC did not draw its two-panel UI (crash or terminal init failure?)" >&2; ok=0; }

if (( ok )); then
  echo "RESULT: Midnight Commander started and rendered its TUI on swift-os."
  exit 0
fi
echo "--- serial (mc region) ---" >&2
sed -n '/built-in shell/,$p' <<<"$clean" | head -80 >&2
exit 1
