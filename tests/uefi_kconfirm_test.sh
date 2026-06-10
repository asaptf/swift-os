#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# uefi_kconfirm_test.sh — U1g-5c acceptance: confirm the booted ESP kernel slot.
#
# Boot 1: boot the default disk copy (slot A), reach a root shell, and run
#         /bin/swos-kconfirm. The kernel marks the loader-recorded booted slot
#         CONFIRMED in \EFI\swift-os\kernel-state and resets its attempt counter.
# Boots 2-4: reboot the SAME writable disk copy. A confirmed slot stops accruing
#            attempts, so the loader stays on slot A with attempt 0 instead of
#            rolling back after the third post-confirm boot.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK_IMG="$ROOT/build/swift-os.img"
BASE="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }
[[ -f "$DISK_IMG" ]]   || { echo "FAIL: $DISK_IMG missing (run 'make disk')" >&2; exit 2; }
[[ -f "$BASE" ]]       || { echo "FAIL: $BASE missing (run 'make base-image')" >&2; exit 2; }

FRESH="$(mktemp -t swiftos-kconf-fresh.XXXXXX)"
WORK="$(mktemp -t swiftos-kconf-img.XXXXXX)"
LOG="$(mktemp -t swiftos-kconf-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-kconf-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-kconf-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$FRESH" "$WORK" "$LOG" "$PIDFILE" "$INFIFO"' EXIT

"$ROOT/scripts/make-disk.sh" "$FRESH" >/dev/null \
  || { echo "FAIL: could not create a fresh disk image (run 'make disk')" >&2; exit 2; }
cp "$FRESH" "$WORK"

QEMU_DRIVE=(-global virtio-mmio.force-legacy=false
            -bios "$AAVMF_CODE"
            -drive "file=$WORK,format=raw,if=none,id=esp,cache=writethrough"
            -device virtio-blk-device,drive=esp
            -drive "file=$BASE,format=raw,if=none,id=swosbase,readonly=on"
            -device virtio-blk-device,drive=swosbase)

await() {
  local marker="$1" max="${2:-90}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
send() {
  sleep 0.3
  local s="$1" i
  for (( i = 0; i < ${#s}; i++ )); do printf '%s' "${s:i:1}" >&3; sleep 0.03; done
}
boot_fifo() {
  : > "$LOG"
  "$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    "${QEMU_DRIVE[@]}" <"$INFIFO" >"$LOG" 2>&1 &
  QP=$!; exec 3<>"$INFIFO"
}
boot_quiet() {
  : > "$LOG"
  "$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    "${QEMU_DRIVE[@]}" </dev/null >"$LOG" 2>&1 &
  QP=$!
}
to_shell() {
  await "M7 tty: type a line then Enter" 90 || return 1
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

boot_fifo
if to_shell; then
  await "UEFI: booted kernel slot A" 30 || fail "boot1: loader did not boot slot A"
  await "UEFI: kernel slot A boot attempt 0x0000000000000001" 30 || fail "boot1: initial attempt not recorded"
  confirmed=0
  for _ in 1 2 3 4 5; do
    send $'/bin/swos-kconfirm\n'
    if await "kernel-store: confirmed kernel slot A healthy in kernel-state" 25; then confirmed=1; break; fi
  done
  [[ "$confirmed" -eq 1 ]] || fail "boot1: kernel did not confirm slot A"
  await "swos-kconfirm: booted kernel slot confirmed healthy" 10 || fail "boot1: swos-kconfirm program did not confirm"
else
  fail "boot1: could not reach a shell"
fi
exec 3>&-; stop_qemu; QP=""

for boot in 2 3 4; do
  boot_quiet
  await "UEFI: booted kernel slot A" 90 || fail "boot${boot}: loader did not stay on confirmed slot A"
  await "UEFI: kernel slot A boot attempt 0x0000000000000000" 30 \
    || fail "boot${boot}: confirmed slot A accrued an attempt"
  if grep -qF "rolling back to slot B" "$LOG"; then
    fail "boot${boot}: confirmed slot A rolled back"
  fi
  stop_qemu; QP=""
done

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: kernel health-confirm — swos-kconfirm marks the booted ESP slot CONFIRMED and prevents attempt rollback"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'UEFI:|kernel-store|swos-kconfirm|boot attempt|rolling back' >&2 | tail -30
exit 1
