#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# uefi_kstage_test.sh — U1g-4c acceptance: the kernel writes the inactive kernel
# slot on the ESP (FAT32) in place, verified.
#
# Setup: a disk copy whose INACTIVE slot (kernelB.bin; the manifest is active=A)
# is a byte-flipped copy of the kernel — so it currently differs from the active
# slot's image. Boot under AAVMF (ESP on virtio-mmio so the kernel can reach it),
# reach a root shell, and run /bin/swos-kstage. The kernel copies the active slot
# (kernelA.bin) over kernelB.bin in place and re-reads both to verify they match.
# Verify only passes if the write actually landed: had it been a no-op, kernelB
# would still be corrupt (!= kernelA) and the in-kernel verify would fail.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
DISK_IMG="$ROOT/build/swift-os.img"
BASE="$ROOT/build/base.img"
KERNEL_BIN="$ROOT/build/kernel.bin"
# OS-1c: ESP slots are the kernel padded to a fixed size; the corrupt slot-B
# fixture must match that size so swos-kstage's same-size in-place copy applies.
KERNEL_SLOT="$ROOT/build/kernel-slot.bin"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="$(host_aavmf_code)" || true
MCOPY="$(host_tool mcopy "${MCOPY:-}")" || true
PART_OFFSET=$((2048 * 512))

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }
[[ -f "$DISK_IMG" ]]   || { echo "FAIL: $DISK_IMG missing (run 'make disk')" >&2; exit 2; }
[[ -f "$BASE" ]]       || { echo "FAIL: $BASE missing (run 'make base-image')" >&2; exit 2; }
[[ -f "$KERNEL_BIN" ]] || { echo "FAIL: $KERNEL_BIN missing (run 'make build')" >&2; exit 2; }
[[ -x "$MCOPY" ]]      || { echo "FAIL: missing mtools $MCOPY" >&2; exit 2; }

FRESH="$(mktemp -t swiftos-kst-fresh.XXXXXX)"
WORK="$(mktemp -t swiftos-kst-img.XXXXXX)"
BADB="$(mktemp -t swiftos-kst-badb.XXXXXX)"
LOG="$(mktemp -t swiftos-kst-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-kst-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-kst-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$FRESH" "$WORK" "$BADB" "$LOG" "$PIDFILE" "$INFIFO"' EXIT
export MTOOLS_SKIP_CHECK=1

"$ROOT/scripts/make-disk.sh" "$FRESH" >/dev/null \
  || { echo "FAIL: could not create a fresh disk image (run 'make disk')" >&2; exit 2; }

# A same-size, byte-flipped copy of the padded kernel slot for (inactive) slot B.
cp "$KERNEL_SLOT" "$BADB"
printf '\xFF' | dd of="$BADB" bs=1 count=1 seek=0 conv=notrunc 2>/dev/null
cp "$FRESH" "$WORK"
"$MCOPY" -o -i "${WORK}@@${PART_OFFSET}" "$BADB" ::/EFI/swift-os/kernelB.bin \
  || { echo "FAIL: could not corrupt kernelB.bin" >&2; exit 2; }

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
# Byte-by-byte serial drive (see tests/ab_activate_test.sh): the emulated PL011 RX
# FIFO drops bursts, so settle then write one char at a time.
send() {
  sleep 0.3
  local s="$1" i
  for (( i = 0; i < ${#s}; i++ )); do printf '%s' "${s:i:1}" >&3; sleep 0.03; done
}

# Boot under AAVMF (ESP + base.img on virtio-mmio), driven via the FIFO.
: > "$LOG"
"$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  -bios "$AAVMF_CODE" \
  -drive "file=$WORK,format=raw,if=none,id=esp" -device virtio-blk-device,drive=esp \
  -drive "file=$BASE,format=raw,if=none,id=swosbase,readonly=on" -device virtio-blk-device,drive=swosbase \
  <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# Drive to a root shell.
to_shell() {
  await "M7 tty: type a line then Enter" 90 || return 1
  send $'tty-line\n'
  await "M7 tty: running; press Ctrl-C" 40 || return 1
  send $'\003'
  await "swift-os login:" 90 || return 1
  send $'root\n'
  await "Password:" 90 || return 1
  send $'swordfish\n'
  await "M12c: shell ready" 120 || return 1
  return 0
}

if to_shell; then
  await "kernel-store: ESP kernel A/B active slot A" 30 || fail "kernel did not read the ESP manifest (active A)"
  staged=0
  for _ in 1 2 3 4 5; do
    send $'/bin/swos-kstage\n'
    if await "kernel-store: staged active slot image into inactive slot, verified (FAT32)" 25; then staged=1; break; fi
  done
  [[ "$staged" -eq 1 ]] || fail "kernel did not stage+verify the inactive slot (FAT32 write)"
  await "swos-kstage: active kernel image staged into the inactive ESP slot (verified)" 10 \
    || fail "swos-kstage program did not confirm success"
else
  fail "could not reach a shell"
fi
exec 3>&-; stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: kernel FAT32 write — swos-kstage copies the active kernel image over the (corrupt) inactive slot in place, verified"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'kernel-store|swos-kstage|login|ash' >&2 | tail -25
exit 1
