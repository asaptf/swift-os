#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# uefi_kactivate_test.sh — U1g-4d acceptance: flip the active kernel slot from a
# running system, persisted, and the loader boots the newly-activated slot.
#
# Boot 1: boot the default disk copy (active slot A), reach a root shell, run
#         /bin/swos-kactivate — the kernel installs the pre-signed alternate
#         manifest (kernel-boot-alt, active=B) over kernel-boot on the ESP.
# Boot 2: reboot the SAME disk copy; the loader verifies the (offline-signed)
#         manifest and boots slot B — proving the flip persisted and authenticity
#         held (the OS only courier-copied an already-signed manifest).
#
# cache=writethrough makes the kactivate write durable across the kill+reboot.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK_IMG="$ROOT/build/swift-os.img"
BASE="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }
[[ -f "$DISK_IMG" ]]   || { echo "FAIL: $DISK_IMG missing (run 'make disk')" >&2; exit 2; }
[[ -f "$BASE" ]]       || { echo "FAIL: $BASE missing (run 'make base-image')" >&2; exit 2; }

WORK="$(mktemp -t swiftos-kact-img.XXXXXX)"
LOG="$(mktemp -t swiftos-kact-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-kact-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-kact-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$WORK" "$LOG" "$PIDFILE" "$INFIFO"' EXIT

cp "$DISK_IMG" "$WORK"

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
send() {  # byte-by-byte (PL011 RX FIFO drops bursts)
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

# --- Boot 1: activate the inactive kernel slot -------------------------------
boot_fifo
if to_shell; then
  await "UEFI: booted kernel slot A" 30 || fail "boot1: loader did not boot slot A"
  activated=0
  for _ in 1 2 3 4 5; do
    send $'/bin/swos-kactivate\n'
    if await "kernel-store: activated kernel slot B for next boot (signed manifest)" 25; then activated=1; break; fi
  done
  [[ "$activated" -eq 1 ]] || fail "boot1: kernel did not activate slot B"
  await "swos-kactivate: inactive kernel slot activated" 10 || fail "boot1: swos-kactivate program did not confirm"
else
  fail "boot1: could not reach a shell"
fi
exec 3>&-; stop_qemu; QP=""

# --- Boot 2: the loader boots the newly-activated, signed slot B -------------
boot_quiet
await "UEFI: kernel A/B manifest active slot B" 90 || fail "boot2: manifest not active slot B (activate did not persist)"
await "UEFI: booted kernel slot B" 30 || fail "boot2: loader did not boot slot B"
await "Hello from Swift kernel" 60 || fail "boot2: kernel did not start from slot B"
if grep -qF "UEFI: kernel manifest signature INVALID" "$LOG"; then
  fail "boot2: flipped manifest failed signature verification"
fi
stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: kernel A/B activate — swos-kactivate installs the pre-signed alternate manifest; the loader verifies it and boots slot B after reboot"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'UEFI:|kernel-store|swos-kactivate|Hello from Swift' >&2 | tail -25
exit 1
