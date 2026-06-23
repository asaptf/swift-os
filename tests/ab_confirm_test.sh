#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ab_confirm_test.sh — U1c acceptance: health-confirm marks the active A/B slot
# CONFIRMED (persisted), and a confirmed slot stops accruing boot attempts.
#
# Boot 1: boot from store slot A, drive to a root shell, run /bin/swos-confirm —
#         assert the program reports success and the kernel records the confirm
#         in the manifest.
# Boot 2: reboot the SAME writable store; assert the kernel sees slot A as
#         CONFIRMED and records NO new boot attempt (confirmed slots are trusted).
#
# cache=writethrough makes the confirm write durable across the kill+reboot.

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

STORE="$(mktemp -t swiftos-abc.XXXXXX)"
LOG="$(mktemp -t swiftos-abc-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-abc-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-abc-in.XXXXXX)"; mkfifo "$INFIFO"
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

boot_fifo() { # interactive boot (drive login + commands)
  : > "$LOG"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false "${dtb_args[@]}" "${QEMU_DRIVE[@]}" \
    -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
  QP=$!; exec 3<>"$INFIFO"
}
boot_quiet() { # non-interactive boot (observe early markers only)
  : > "$LOG"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false "${dtb_args[@]}" "${QEMU_DRIVE[@]}" \
    -kernel "$KERNEL" </dev/null >"$LOG" 2>&1 &
  QP=$!
}
send_line() {
  local line="$1" delay="${AB_CONFIRM_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${AB_CONFIRM_SEND_DELAY:-0.08}"
}
to_shell() {
  await "M7 tty: type a line then Enter" 60 || return 1
  send_line 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || return 1
  printf '\003' >&3
  await "swift-os login:" 90 || return 1
  send_line 'root'
  await "Password:" 90 || return 1
  send_line 'swordfish'
  await "M12c: shell ready" 120 || return 1
  return 0
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# --- Boot 1: confirm the active slot -----------------------------------------
boot_fifo
if to_shell; then
  await "update-store: recorded boot attempt 1 for active slot A" 30 || fail "boot1: attempt 1 not recorded"
  send_line '/bin/swos-confirm'
  await "swos-confirm: active slot confirmed healthy" 60 || fail "boot1: swos-confirm did not succeed"
  await "update-store: slot A confirmed healthy" 30 || fail "boot1: kernel did not record the confirm"
else
  fail "boot1: could not reach a shell"
fi
exec 3>&-; stop_qemu; QP=""

# --- Boot 2: confirmed slot is trusted, records no new attempt ---------------
boot_quiet
await "active slot A gen 1 confirmed" 60 || fail "boot2: slot A not CONFIRMED (confirm did not persist)"
await "M11c: read-only base mounted from disk" 30 || fail "boot2: base did not mount"
if grep -qF "recorded boot attempt" "$LOG"; then
  fail "boot2: a CONFIRMED slot still recorded a boot attempt"
fi
stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: A/B health-confirm — /bin/swos-confirm marks the slot CONFIRMED, persists, and stops boot-attempt counting"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'update-store|swos-confirm|mounted' >&2 | tail -20
exit 1
