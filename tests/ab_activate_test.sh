#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ab_activate_test.sh — U1e acceptance: /bin/swos-activate promotes the inactive
# A/B slot, atomically and persisted, and the newly-activated slot boots "on
# trial" (UNTRIED, attempts reset) so U1d's rollback protects it.
#
# Boot 1: boot from slot A, drive to a root shell, run /bin/swos-activate —
#         assert the program + kernel report slot B activated.
# Boot 2: reboot the SAME writable store; assert slot B is now the active slot,
#         seen UNTRIED, and records its first boot attempt (on trial).
#
# cache=writethrough makes the activate write durable across the kill+reboot.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE="$ROOT/build/base.img"
USTORE="$ROOT/build/updatestore"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE" ]]   || { echo "FAIL: $BASE missing (make base-image)" >&2; exit 2; }
[[ -x "$USTORE" ]] || { echo "FAIL: $USTORE missing (make updatestore)" >&2; exit 2; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

STORE="$(mktemp -t swiftos-aba.XXXXXX)"
LOG="$(mktemp -t swiftos-aba-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-aba-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-aba-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$STORE" "$LOG" "$PIDFILE" "$INFIFO"' EXIT

"$USTORE" "$STORE" A "$BASE" "$BASE" >/dev/null || { echo "FAIL: could not build store" >&2; exit 2; }

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

QEMU_DRIVE=(-drive "file=$STORE,format=raw,if=none,id=swosstore,cache=writethrough"
            -device virtio-blk-device,drive=swosstore)

boot_fifo() {
  : > "$LOG"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false "${dtb_args[@]}" "${QEMU_DRIVE[@]}" \
    -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
  QP=$!; exec 3<>"$INFIFO"
}
boot_quiet() {
  : > "$LOG"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false "${dtb_args[@]}" "${QEMU_DRIVE[@]}" \
    -kernel "$KERNEL" </dev/null >"$LOG" 2>&1 &
  QP=$!
}
# Send a string to the guest reactively: settle so the reader is in read(), then
# write byte-by-byte with small gaps so the emulated PL011 RX FIFO never drops a
# burst. The login sequence is stateful (each line is consumed by a different
# read), so it cannot be blindly re-sent — reliable delivery is what keeps it
# deterministic.
send() {
  sleep 0.3
  local s="$1" i
  for (( i = 0; i < ${#s}; i++ )); do printf '%s' "${s:i:1}" >&3; sleep 0.03; done
}
to_shell() {
  await "M7 tty: type a line then Enter" 60 || return 1
  send $'tty-line\n'
  await "M7 tty: running; press Ctrl-C" 40 || return 1
  send $'\003'
  await "swift-os login:" 90 || return 1
  send $'root\n'
  await "Password:" 90 || return 1
  send $'swordfish\n'
  await "built-in shell (ash)" 120 || return 1
  return 0
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# --- Boot 1: activate the inactive slot --------------------------------------
boot_fifo
if to_shell; then
  await "update-store: SWOSBOOT manifest valid, active slot A" 30 || fail "boot1: did not boot slot A"
  # The interactive serial line can occasionally drop a typed command, so re-send
  # /bin/swos-activate until the kernel records the activation. This is safe and
  # not a toggle: update_activate always targets the slot OTHER than the one
  # booted this session (updateStoreActiveSlot is fixed at boot), so re-running it
  # is idempotent — it activates slot B every time here.
  activated=0
  for _ in 1 2 3 4 5; do
    send $'/bin/swos-activate\n'
    if await "update-store: activated slot B (on trial)" 15; then activated=1; break; fi
  done
  [[ "$activated" -eq 1 ]] || fail "boot1: kernel did not activate slot B"
  await "swos-activate: inactive slot activated" 10 || fail "boot1: swos-activate program did not confirm"
else
  fail "boot1: could not reach a shell"
fi
exec 3>&-; stop_qemu; QP=""

# --- Boot 2: the activated slot B is now active, on trial --------------------
boot_quiet
await "update-store: SWOSBOOT manifest valid, active slot B" 60 || fail "boot2: slot B not active (activate did not persist)"
await "update-store: recorded boot attempt 1 for active slot B" 30 || fail "boot2: slot B not on trial"
if grep -qF "manifest valid, active slot A" "$LOG"; then fail "boot2: still booted slot A after activate"; fi
stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: A/B activate — /bin/swos-activate promotes the inactive slot atomically; it boots on trial"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'update-store|swos-activate' >&2 | tail -20
exit 1
