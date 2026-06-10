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
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
MCOPY="${MCOPY:-/opt/homebrew/bin/mcopy}"
MDEL="${MDEL:-/opt/homebrew/bin/mdel}"
PART_OFFSET=$((2048 * 512))

[[ -f "$AAVMF_CODE" ]] || { echo "FAIL: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 2; }
[[ -f "$DISK_IMG" ]]   || { echo "FAIL: $DISK_IMG missing (run 'make disk')" >&2; exit 2; }
[[ -x "$KERNELBOOT" ]] || { echo "FAIL: $KERNELBOOT missing (run 'make kernelboot')" >&2; exit 2; }
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
  printf '%s\0' -drive "file=$WORK,format=raw,if=virtio"
  if [[ -f "$BASE" ]]; then
    printf '%s\0' -global virtio-mmio.force-legacy=false \
      -drive "file=$BASE,format=raw,if=none,id=swosbase,readonly=on" \
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
"$KERNELBOOT" "$MANI" B >/dev/null || fail "could not build active-B manifest"
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
await "rolling back to slot A" 60 || fail "fallback: loader did not roll back to slot A"
await "UEFI: booted kernel slot A" 30   || fail "fallback: loader did not boot slot A"
await "Hello from Swift kernel" 60      || fail "fallback: kernel did not start from slot A"
stop_qemu

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: UEFI kernel A/B — manifest selects the active slot; missing active slot rolls back to the other"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'UEFI:|Hello from Swift|M9 OK' >&2 | tail -25
exit 1
