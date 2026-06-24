#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# uefi_kinstall_test.sh — OS-1c-2b acceptance: the kernel installs a genuinely NEW,
# host-signed kernel into the INACTIVE ESP slot, verified kernel-side, and the
# loader then boots it.
#
# Unlike swos-kstage (which only duplicates the running kernel), /bin/swos-kinstall
# streams a distinct kernel image into the inactive slot and commits that slot's
# 104-byte host-signed manifest entry. The kernel verifies the entry — the per-slot
# Ed25519 signature (bound to the slot index) AND the on-disk re-hash — before
# writing it into the signed manifest.
#
# Boot 1 (active slot A, interactive):
#   - an entry signed for the WRONG slot index (slot A's entry replayed into B) is
#     rejected (the per-slot index binding — the key security property);
#   - an entry with a zeroed signature is rejected;
#   - the correct slot-B entry installs the new image and is accepted;
#   - swos-kactivate flips the ESP selector to slot B.
# Host (QEMU stopped): mcopy the slots out of the disk and prove slot B now holds
# the NEW image (the write landed) and slot A is byte-for-byte unchanged.
# Boot 2 (no interaction): the loader boots slot B, integrity-verifies it against
# the freshly written manifest entry, and the new kernel starts. A no-op write or a
# missed manifest update would leave B != its entry, so the loader would reject B
# and fall back to A — booting B proves both the streamed write and the manifest
# commit took effect.
#
# AAVMF (ESP on virtio-mmio so the kernel can reach it) + baked fixtures
# (INCLUDE_OS_KINSTALL_TEST=1). The loader's reject->rollback path itself is covered
# by uefi_kernel_ab_test / uefi_krollback_test.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$ROOT/build/base.img"
KERNEL_BIN="$ROOT/build/kernel.bin"
KERNEL_SLOT="$ROOT/build/kernel-slot.bin"        # the original (active) slot image
NEW_KERNEL="$ROOT/build/kinstall-newkernel.bin"  # the distinct image we install into B
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
MCOPY="${MCOPY:-/opt/homebrew/bin/mcopy}"
PART_OFFSET=$((2048 * 512))
FIX=/usr/share/swos-kinstall-test

[[ -f "$AAVMF_CODE" ]] || { echo "SKIP: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 0; }
[[ -f "$BASE" ]]        || { echo "FAIL: $BASE missing (make base-image INCLUDE_OS_KINSTALL_TEST=1)" >&2; exit 2; }
[[ -f "$KERNEL_SLOT" ]] || { echo "FAIL: $KERNEL_SLOT missing (run 'make build'/'make uefi')" >&2; exit 2; }
[[ -f "$NEW_KERNEL" ]]  || { echo "FAIL: $NEW_KERNEL missing (run 'make $NEW_KERNEL')" >&2; exit 2; }
[[ -x "$MCOPY" ]]       || { echo "FAIL: missing mtools $MCOPY" >&2; exit 2; }

FRESH="$(mktemp -t swiftos-kin-fresh.XXXXXX)"
WORK="$(mktemp -t swiftos-kin-img.XXXXXX)"
SLOTA="$(mktemp -t swiftos-kin-slota.XXXXXX)"
SLOTB="$(mktemp -t swiftos-kin-slotb.XXXXXX)"
LOG="$(mktemp -t swiftos-kin-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-kin-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-kin-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true; QP=""
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$FRESH" "$WORK" "$SLOTA" "$SLOTB" "$LOG" "$PIDFILE" "$INFIFO"' EXIT
export MTOOLS_SKIP_CHECK=1

"$ROOT/scripts/make-disk.sh" "$FRESH" >/dev/null \
  || { echo "FAIL: could not create a fresh disk image (run 'make disk')" >&2; exit 2; }
cp "$FRESH" "$WORK"

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }
await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
# Byte-by-byte serial drive: the emulated PL011 RX FIFO drops bursts, so settle
# then write one char at a time (see tests/uefi_kstage_test.sh).
send() {
  sleep 0.3
  local s="$1" i
  for (( i = 0; i < ${#s}; i++ )); do printf '%s' "${s:i:1}" >&3; sleep 0.03; done
}
to_shell() {
  await "M7 tty: type a line then Enter" 120 || return 1
  send $'tty-line\n'; await "M7 tty: running; press Ctrl-C" 60 || return 1
  send $'\003'; await "swift-os login:" 120 || return 1
  send $'root\n'; await "Password:" 90 || return 1
  send $'swordfish\n'; await "M12c: shell ready" 150 || return 1
  return 0
}

SUCCESS="kernel-store: installed new kernel into inactive slot B"
REJECT="kernel-store: kernel install commit rejected"

# ---- Boot 1: install (with negatives) + activate, driven interactively --------
: > "$LOG"
"$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false -bios "$AAVMF_CODE" \
  -drive "file=$WORK,format=raw,if=none,id=esp,cache=writethrough" -device virtio-blk-device,drive=esp \
  -drive "file=$BASE,format=raw,if=none,id=swosbase,readonly=on" -device virtio-blk-device,drive=swosbase \
  <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

if to_shell; then
  await "kernel-store: ESP kernel A/B active slot A" 30 || fail "boot 1: kernel did not read the ESP manifest (active A)"

  # Negative 1: an entry signed for slot index 0 (slot A) replayed into the
  # inactive slot B must be rejected by the per-slot index binding.
  send "/bin/swos-kinstall $FIX/newkernel.bin $FIX/entryA.bin ; echo KIN-DONE-IDX"$'\n'
  await "KIN-DONE-IDX" 240 || fail "boot 1: index-mismatch install did not finish"
  grep -qF "$SUCCESS" "$LOG" && fail "boot 1: index-mismatch entry was wrongly accepted"

  # Negative 2: an entry whose signature is zeroed must be rejected.
  send "/bin/swos-kinstall $FIX/newkernel.bin $FIX/entry-badsig.bin ; echo KIN-DONE-BADSIG"$'\n'
  await "KIN-DONE-BADSIG" 240 || fail "boot 1: bad-signature install did not finish"
  grep -qF "$SUCCESS" "$LOG" && fail "boot 1: bad-signature entry was wrongly accepted"
  grep -qF "$REJECT" "$LOG" || fail "boot 1: kernel did not log a commit rejection for the bad entries"

  # Positive: the correct slot-B entry installs the new image and is accepted.
  send "/bin/swos-kinstall $FIX/newkernel.bin $FIX/entryB.bin ; echo KIN-DONE-OK"$'\n'
  await "$SUCCESS" 240 || fail "boot 1: valid install was not accepted"
  await "swos-kinstall: new kernel installed into the inactive ESP slot (verified)" 10 \
    || fail "boot 1: swos-kinstall did not confirm success"

  # Flip the ESP selector to the freshly installed slot B for the next boot.
  send $'/bin/swos-kactivate\n'
  await "kernel-store: activated kernel slot B" 30 || fail "boot 1: could not activate slot B"
else
  fail "boot 1: could not reach a shell"
fi
exec 3>&-; stop_qemu

# ---- Host: prove the write landed on B and slot A is untouched ----------------
if [[ "$ok" -eq 1 ]]; then
  "$MCOPY" -n -i "${WORK}@@${PART_OFFSET}" ::/EFI/swift-os/kernelB.bin "$SLOTB" 2>/dev/null \
    || fail "could not read back kernelB.bin"
  "$MCOPY" -n -i "${WORK}@@${PART_OFFSET}" ::/EFI/swift-os/kernelA.bin "$SLOTA" 2>/dev/null \
    || fail "could not read back kernelA.bin"
  cmp -s "$SLOTB" "$NEW_KERNEL"   || fail "slot B does not hold the newly installed image"
  cmp -s "$SLOTA" "$KERNEL_SLOT"  || fail "slot A (active) was modified by the install"
fi

# ---- Boot 2: the loader must boot + integrity-verify the new slot B -----------
if [[ "$ok" -eq 1 ]]; then
  : > "$LOG"
  "$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false -bios "$AAVMF_CODE" \
    -drive "file=$WORK,format=raw,if=none,id=esp,cache=writethrough" -device virtio-blk-device,drive=esp \
    -drive "file=$BASE,format=raw,if=none,id=swosbase,readonly=on" -device virtio-blk-device,drive=swosbase \
    </dev/null >"$LOG" 2>&1 &
  QP=$!
  await "UEFI: kernel slot B integrity verified (sha256)" 120 \
    || fail "boot 2: loader did not integrity-verify slot B against the new manifest entry"
  await "UEFI: booted kernel slot B" 30 || fail "boot 2: loader did not boot slot B"
  await "Hello from Swift kernel" 60 || fail "boot 2: the installed slot-B kernel did not start"
  stop_qemu
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: OS-1c-2b — swos-kinstall installs a NEW host-signed kernel into the inactive ESP slot (verified, per-slot sig + on-disk re-hash); wrong-index and bad-sig entries rejected; slot A untouched; loader boots the new slot B"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'kernel-store|swos-kinstall|UEFI: |login|KIN-DONE' >&2 | tail -40
exit 1
