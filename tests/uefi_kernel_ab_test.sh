#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# uefi_kernel_ab_test.sh — U1g-2 acceptance: the UEFI loader reads the kernel A/B
# boot manifest from the ESP, loads the active slot, and rolls back to the other
# slot when the active one is missing.
#
# Built on the real GPT disk image (make disk). We make per-case copies and edit
# the ESP with mtools (the same tooling make-disk uses), then boot under AAVMF:
#
#   Case B: rewrite \EFI\swift-os\kernel-boot to active=B; assert the loader
#           reports "active slot B" and "booted kernel slot B", and the kernel
#           boots (the slot-B image is valid — both slots are the same build).
#   Fallback: active=B but delete kernelB.bin; assert the loader reports rolling
#           back to slot A, "booted kernel slot A", and the kernel boots.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISK_IMG="$ROOT/build/swift-os.img"
KERNELBOOT="$ROOT/build/kernelboot"
KERNEL_BIN="$ROOT/build/kernel.bin"
SIGN_SEED="$ROOT/models/dev-image-signing.seed"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
MCOPY="${MCOPY:-/opt/homebrew/bin/mcopy}"
MDEL="${MDEL:-/opt/homebrew/bin/mdel}"
PART_OFFSET=$((2048 * 512))

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }
[[ -f "$DISK_IMG" ]]   || { echo "FAIL: $DISK_IMG missing (run 'make disk')" >&2; exit 2; }
[[ -x "$KERNELBOOT" ]] || { echo "FAIL: $KERNELBOOT missing (run 'make kernelboot')" >&2; exit 2; }
[[ -f "$KERNEL_BIN" ]] || { echo "FAIL: $KERNEL_BIN missing (run 'make build')" >&2; exit 2; }
[[ -f "$SIGN_SEED" ]]  || { echo "FAIL: $SIGN_SEED missing (run 'make base-image')" >&2; exit 2; }
for t in "$MCOPY" "$MDEL"; do [[ -x "$t" ]] || { echo "FAIL: missing mtools $t" >&2; exit 2; }; done

BASE="$ROOT/build/base.img"
LOG="$(mktemp -t swiftos-uabk.XXXXXX)"
MANI="$(mktemp -t swiftos-uabk-mani.XXXXXX)"
WORK="$(mktemp -t swiftos-uabk-img.XXXXXX)"
QP=""
stop_qemu() { [[ -n "$QP" ]] && { kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null; }; QP=""; }
trap 'stop_qemu; rm -f "$LOG" "$MANI" "$WORK"' EXIT
export MTOOLS_SKIP_CHECK=1

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-40}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    kill -0 "$QP" 2>/dev/null || { grep -qF "$marker" "$LOG" 2>/dev/null && return 0; return 1; }
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_args() {  # echoes the QEMU drive args for $WORK + the base disk
  # U1g-4: ESP/GPT disk on virtio-mmio (so AAVMF and the kernel can both reach it).
  printf '%s\0' -global virtio-mmio.force-legacy=false \
    -drive "file=$WORK,format=raw,if=none,id=esp" \
    -device virtio-blk-device,drive=esp
  if [[ -f "$BASE" ]]; then
    printf '%s\0' -drive "file=$BASE,format=raw,if=none,id=swosbase,readonly=on" \
      -device virtio-blk-device,drive=swosbase
  fi
}

boot_work() {  # boot $WORK headless, capturing serial to $LOG
  : > "$LOG"
  local args=(); local a
  while IFS= read -r -d '' a; do args+=("$a"); done < <(drive_args)
  "$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -bios "$AAVMF_CODE" "${args[@]}" </dev/null >"$LOG" 2>&1 &
  QP=$!
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# --- Case B: active=B, both slots present -> loader boots slot B -------------
cp "$DISK_IMG" "$WORK"
"$KERNELBOOT" "$MANI" B "$KERNEL_BIN" "$KERNEL_BIN" "$SIGN_SEED" >/dev/null || fail "could not build active-B manifest"
"$MCOPY" -o -i "${WORK}@@${PART_OFFSET}" "$MANI" ::/EFI/swift-os/kernel-boot \
  || fail "could not write active-B manifest into the ESP"
boot_work
await "UEFI: kernel A/B manifest active slot B" 60 || fail "caseB: loader did not read active slot B"
await "UEFI: booted kernel slot B" 30            || fail "caseB: loader did not boot slot B"
await "Hello from Swift kernel" 60               || fail "caseB: kernel did not start from slot B"
await "M9 OK: hardware discovered from device tree" 60 || fail "caseB: kernel did not progress"
stop_qemu

# --- Fallback: active=B but kernelB.bin missing -> roll back to slot A -------
cp "$DISK_IMG" "$WORK"
"$MCOPY" -o -i "${WORK}@@${PART_OFFSET}" "$MANI" ::/EFI/swift-os/kernel-boot \
  || fail "could not write active-B manifest (fallback case)"
"$MDEL" -i "${WORK}@@${PART_OFFSET}" ::/EFI/swift-os/kernelB.bin \
  || fail "could not delete kernelB.bin for the fallback case"
boot_work
await "UEFI: kernel slot unusable, trying slot A" 60 || fail "fallback: loader did not try slot A after missing active slot"
await "UEFI: booted kernel slot A" 30   || fail "fallback: loader did not boot slot A"
await "Hello from Swift kernel" 60      || fail "fallback: kernel did not start from slot A"
stop_qemu

# --- Integrity: active slot A corrupt -> SHA-256 mismatch -> roll back to B --
# The default manifest is active=A with v2 hashes over the real kernel. Replace
# kernelA.bin with a byte-flipped copy: its SHA-256 no longer matches, so the
# loader must reject slot A and boot the (valid) slot B.
cp "$DISK_IMG" "$WORK"
BADA="$(mktemp -t swiftos-uabk-bada.XXXXXX)"
cp "$KERNEL_BIN" "$BADA"
printf '\xFF' | dd of="$BADA" bs=1 count=1 seek=0 conv=notrunc 2>/dev/null
"$MCOPY" -o -i "${WORK}@@${PART_OFFSET}" "$BADA" ::/EFI/swift-os/kernelA.bin \
  || fail "could not write corrupt kernelA.bin"
rm -f "$BADA"
boot_work
await "kernel slot A FAILED integrity check (sha256)" 60 || fail "integrity: loader did not detect the corrupt slot A"
await "UEFI: booted kernel slot B" 30 || fail "integrity: loader did not roll back to slot B"
await "Hello from Swift kernel" 60    || fail "integrity: kernel did not start from slot B"
stop_qemu

# --- Authenticity: tamper the manifest signature -> loader refuses the manifest
# and boots its own embedded blob (never an attacker-chosen slot). Flip a byte in
# the 64-byte Ed25519 signature region (offset 104) of the kernel-boot manifest.
cp "$DISK_IMG" "$WORK"
MANI2="$(mktemp -t swiftos-uabk-mani2.XXXXXX)"
"$MCOPY" -i "${WORK}@@${PART_OFFSET}" ::/EFI/swift-os/kernel-boot "$MANI2" \
  || fail "could not read kernel-boot manifest"
printf '\xFF' | dd of="$MANI2" bs=1 count=1 seek=104 conv=notrunc 2>/dev/null
"$MCOPY" -o -i "${WORK}@@${PART_OFFSET}" "$MANI2" ::/EFI/swift-os/kernel-boot \
  || fail "could not write tampered manifest"
rm -f "$MANI2"
boot_work
await "UEFI: kernel manifest signature INVALID" 60 || fail "auth: loader did not reject the tampered manifest"
await "using embedded blob" 30 || fail "auth: loader did not fall back to the embedded blob"
await "Hello from Swift kernel" 60 || fail "auth: kernel did not start from the embedded blob"
stop_qemu

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: UEFI kernel A/B — signed manifest selects the active slot; missing/SHA-256-mismatched slot rolls back; a tampered manifest signature is refused (embedded blob)"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'UEFI:|Hello from Swift|M9 OK' >&2 | tail -25
exit 1
