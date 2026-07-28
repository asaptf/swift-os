#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# reboot_test.sh — power-control acceptance: shutdown/reboot commands and the
# capConsole gate.
#
# Phase A (reboot): boot to a root shell (capConsole), run /bin/reboot. Assert the
#   kernel issues PSCI SYSTEM_RESET and the machine actually resets — the boot
#   reaches the M7 tty prompt a SECOND time. Then, on the rebooted guest, log in as
#   the unprivileged `user` (caps=14, no capConsole) and run /bin/reboot: assert it
#   is refused and the machine does NOT reset again.
# Phase B (poweroff): boot to a root shell, run /bin/shutdown. Assert the kernel
#   issues PSCI SYSTEM_OFF and QEMU exits on its own (no kill from us).
#
# The same PSCI reset path is what the kernel panic auto-reboot uses, so proving
# /bin/reboot here also exercises the reset mechanism behind the panic countdown.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE" ]]   || { echo "FAIL: $BASE missing (make base-image)" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-reboot.XXXXXX)"
DATA_IMG="$WORK/data.img"
LOG="$WORK/serial.log"
PIDFILE="$WORK/qemu.pid"
INFIFO="$WORK/in.fifo"; mkfifo "$INFIFO"
QP=""

# A stamped, writable data disk so the reboot/shutdown sync() flushes real media.
dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  QP=""
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -rf "$WORK"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

base_drive=(-drive "file=$BASE,format=raw,if=none,id=swosbase,readonly=on"
            -device virtio-blk-device,drive=swosbase
            -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata,cache=writethrough"
            -device virtio-blk-device,drive=swosdata)

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
    got="$(grep -cF "$marker" "$LOG" 2>/dev/null || true)"
    (( got >= want )) && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
send_line() {
  local line="$1" delay="${REBOOT_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do printf '%s' "${line:i:1}" >&3; sleep "$delay"; done
  printf '\n' >&3
  sleep "${REBOOT_SEND_DELAY:-0.08}"
}
# Drive the standard boot flow (M7 tty demo -> login) to a shell as $1/$2.
# Counts from $3: the ordinal of the M7 prompt to wait for (1 on first boot, 2 after a reboot).
to_shell() { # to_shell USER PASSWORD PROMPT_ORDINAL
  local u="$1" pw="$2" ord="$3"
  await_count "M7 tty: type a line then Enter" "$ord" "$DEMO_BOOT_TIMEOUT" || return 1
  send_line 'tty-line'
  await_count "M7 tty: running; press Ctrl-C" "$ord" 40 || return 1
  printf '\003' >&3
  await_count "swift-os login:" "$ord" 90 || return 1
  send_line "$u"
  await_count "Password:" "$ord" 90 || return 1
  send_line "$pw"
  return 0
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# === Phase A: /bin/reboot resets the machine; non-console user is refused =======
: > "$LOG"
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false "${dtb_args[@]}" "${base_drive[@]}" \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

if to_shell root swordfish 1; then
  await "M12c: shell ready" 120 || fail "A: root shell did not start"
  send_line '/bin/reboot'
  await "power: rebooting now" 60 || fail "A: kernel did not issue PSCI SYSTEM_RESET"
  # The machine must actually reset: the boot flow reaches its prompts a 2nd time.
  if await_count "M7 tty: type a line then Enter" 2 "$DEMO_BOOT_TIMEOUT"; then
    : # rebooted
  else
    fail "A: machine did not reboot (no second boot)"
  fi
else
  fail "A: could not reach a root shell"
fi

# On the rebooted guest, an unprivileged user must be refused.
if [[ "$ok" -eq 1 ]] && to_shell user swordfish 2; then
  await "Welcome to swift-os, user" 120 || fail "A: user login did not succeed"
  send_line '/bin/reboot'
  await "reboot: permission denied (need capConsole)" 60 || fail "A: non-console reboot was not refused"
  # And it must NOT have reset a second time.
  if await_count "M7 tty: type a line then Enter" 3 8; then
    fail "A: unprivileged /bin/reboot still rebooted the machine"
  fi
else
  [[ "$ok" -eq 1 ]] && fail "A: could not reach a user shell after reboot"
fi
exec 3>&-; stop_qemu

# === Phase B: /bin/shutdown powers off (QEMU exits on its own) =================
: > "$LOG"
# Fresh boot with -no-reboot (a stray reset would also exit); SYSTEM_OFF must quit
# QEMU on its own — we deliberately do NOT pass -no-shutdown.
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false "${dtb_args[@]}" "${base_drive[@]}" \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

if to_shell root swordfish 1; then
  await "M12c: shell ready" 120 || fail "B: root shell did not start"
  send_line '/bin/shutdown'
  await "power: powering off now" 60 || fail "B: kernel did not issue PSCI SYSTEM_OFF"
  # QEMU must exit on its own (SYSTEM_OFF), without our kill.
  n=0; exited=0
  while (( n < 150 )); do
    kill -0 "$QP" 2>/dev/null || { exited=1; break; }
    sleep 0.1; n=$((n + 1))
  done
  (( exited == 1 )) || fail "B: QEMU did not power off on PSCI SYSTEM_OFF"
else
  fail "B: could not reach a root shell"
fi
exec 3>&-; stop_qemu

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/reboot resets (PSCI SYSTEM_RESET), /bin/shutdown powers off (PSCI SYSTEM_OFF), capConsole enforced"
  exit 0
fi
echo "--- serial (last boot, power region) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'power:|reboot:|shutdown:|M7 tty|login' >&2 | tail -30
exit 1
