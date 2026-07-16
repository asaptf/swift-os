#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# uefi_kattempt_test.sh — U1g-5a acceptance: the loader DURABLY records a per-slot
# kernel boot-attempt counter on the ESP (its first EFI write).
#
# Boots the SAME writable disk copy three times under AAVMF (ESP on virtio-mmio,
# cache=writethrough) and asserts the active slot's boot-attempt counter (in the
# self-managed \EFI\swift-os\kernel-state file) increments 1 -> 2 -> 3 across
# reboots — proving the loader writes the ESP via the EFI File protocol and the
# write persists. The counter is the groundwork for attempt-based kernel rollback.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
DISK_IMG="$ROOT/build/swift-os.img"
BASE="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="$(host_aavmf_code)" || true

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }
[[ -f "$DISK_IMG" ]]   || { echo "FAIL: $DISK_IMG missing (run 'make disk')" >&2; exit 2; }
[[ -f "$BASE" ]]       || { echo "FAIL: $BASE missing (run 'make base-image')" >&2; exit 2; }

FRESH="$(mktemp -t swiftos-katt-fresh.XXXXXX)"
WORK="$(mktemp -t swiftos-katt-img.XXXXXX)"
LOG="$(mktemp -t swiftos-katt-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-katt-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$FRESH" "$WORK" "$LOG" "$PIDFILE"' EXIT

"$ROOT/scripts/make-disk.sh" "$FRESH" >/dev/null \
  || { echo "FAIL: could not create a fresh disk image (run 'make disk')" >&2; exit 2; }
cp "$FRESH" "$WORK"

QEMU_DRIVE=(-global virtio-mmio.force-legacy=false
            -bios "$AAVMF_CODE"
            -drive "file=$WORK,format=raw,if=none,id=esp,cache=writethrough"
            -device virtio-blk-device,drive=esp
            -drive "file=$BASE,format=raw,if=none,id=swosbase,readonly=on"
            -device virtio-blk-device,drive=swosbase)

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
boot_once() {  # boot_once <attempt-marker>
  : > "$LOG"
  "$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    "${QEMU_DRIVE[@]}" </dev/null >"$LOG" 2>&1 &
  QP=$!
  local rc=1
  await "$1" 90 && rc=0
  stop_qemu; QP=""
  return $rc
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# puthex prints the counter as a 16-digit hex value; active slot is A by default.
boot_once "UEFI: kernel slot A boot attempt 0x0000000000000001" \
  || fail "boot 1 did not record attempt 1"
boot_once "UEFI: kernel slot A boot attempt 0x0000000000000002" \
  || fail "boot 2 did not persist attempt 2 across reboot"
boot_once "UEFI: kernel slot A boot attempt 0x0000000000000003" \
  || fail "boot 3 did not persist attempt 3 across reboot"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: loader kernel boot-attempt counter persists across reboots (1->2->3) via an ESP EFI write"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'UEFI:|kernel-state|boot attempt' >&2 | tail -20
exit 1
