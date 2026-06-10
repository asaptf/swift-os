#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# uefi_krollback_test.sh — U1g-5b acceptance: attempt-based kernel rollback.
#
# Boots the SAME writable disk copy repeatedly under AAVMF (ESP on virtio-mmio,
# cache=writethrough). The active slot (A) is never confirmed, so the loader
# counts boot attempts in the ESP kernel-state; once they reach the cap (3), the
# next boot presumes slot A unhealthy and FAILS OVER to slot B (marking A FAILED),
# persisted. Boots 1-3 record attempts 1/2/3 for slot A; boot 4 rolls back to B.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK_IMG="$ROOT/build/swift-os.img"
BASE="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }
[[ -f "$DISK_IMG" ]]   || { echo "FAIL: $DISK_IMG missing (run 'make disk')" >&2; exit 2; }
[[ -f "$BASE" ]]       || { echo "FAIL: $BASE missing (run 'make base-image')" >&2; exit 2; }

WORK="$(mktemp -t swiftos-krb-img.XXXXXX)"
LOG="$(mktemp -t swiftos-krb-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-krb-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$WORK" "$LOG" "$PIDFILE"' EXIT

cp "$DISK_IMG" "$WORK"

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
boot_once() {  # boot_once <marker>
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

boot_once "UEFI: kernel slot A boot attempt 0x0000000000000001" || fail "boot 1: attempt 1 not recorded for slot A"
boot_once "UEFI: kernel slot A boot attempt 0x0000000000000002" || fail "boot 2: attempt 2 not persisted"
boot_once "UEFI: kernel slot A boot attempt 0x0000000000000003" || fail "boot 3: attempt 3 not persisted"
# Boot 4: slot A unconfirmed + attempts exhausted -> roll back to slot B.
boot_once "UEFI: booted kernel slot B" || fail "boot 4: loader did not roll back to slot B"
grep -qF "rolling back to slot B" "$LOG" || fail "boot 4: no rollback log"
grep -qF "Hello from Swift kernel" "$LOG" || fail "boot 4: slot B kernel did not start"

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: kernel attempt-based rollback — unconfirmed slot A exhausts its attempts and the loader fails over to slot B (persisted)"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'UEFI:|boot attempt|rolling back' >&2 | tail -20
exit 1
