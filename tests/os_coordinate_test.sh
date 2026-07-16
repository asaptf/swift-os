#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# os_coordinate_test.sh — OS-1 acceptance: the single coordinated A/B selector.
#
# This is the only topology where BOTH A/B mechanisms coexist: a UEFI/GPT disk
# (kernel A/B on the ESP, selected by the loader) PLUS a SWOSBOOT update-store as
# the base disk (base A/B). OS-1 makes the kernel put the base on the SAME slot
# the loader booted the kernel from (read from ESP kernel-state.lastBooted), so
# kernel and base never drift — one selector drives both.
#
#   Case A: default manifest (active=A) -> loader boots kernel slot A; the kernel
#           must log "base slot A coordinated with ESP kernel slot A" and mount it.
#   Case B: rewrite kernel-boot to active=B -> loader boots kernel slot B; the
#           kernel must coordinate the base to slot B — even though the store's own
#           SWOSBOOT active is still A, proving the ESP kernel-state is the single
#           authority (not the store's own active field).
#
# Built on the real GPT disk (make-disk.sh) under AAVMF, with a store disk built
# by `updatestore` (both slots = base.img) attached as the base.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
KERNELBOOT="$ROOT/build/kernelboot"
KERNEL_BIN="$ROOT/build/kernel.bin"
# OS-1c: ESP kernel slots are padded to a fixed size; a rebuilt manifest must sign
# the same padded image so the slot verifies on disk.
KERNEL_SLOT="$ROOT/build/kernel-slot.bin"
USTORE="$ROOT/build/updatestore"
BASE="$ROOT/build/base.img"
SIGN_SEED="$ROOT/models/dev-image-signing.seed"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="$(host_aavmf_code)" || true
MCOPY="$(host_tool mcopy "${MCOPY:-}")" || true
PART_OFFSET=$((2048 * 512))

[[ -f "$AAVMF_CODE" ]] || { echo "SKIP: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 0; }
[[ -x "$KERNELBOOT" ]] || { echo "FAIL: $KERNELBOOT missing (make kernelboot)" >&2; exit 2; }
[[ -f "$KERNEL_BIN" ]] || { echo "FAIL: $KERNEL_BIN missing (make build)" >&2; exit 2; }
[[ -x "$USTORE" ]]     || { echo "FAIL: $USTORE missing (make updatestore)" >&2; exit 2; }
[[ -f "$BASE" ]]       || { echo "FAIL: $BASE missing (make base-image)" >&2; exit 2; }
[[ -f "$SIGN_SEED" ]]  || { echo "FAIL: $SIGN_SEED missing" >&2; exit 2; }
[[ -x "$MCOPY" ]]      || { echo "FAIL: missing mtools mcopy" >&2; exit 2; }

FRESH="$(mktemp -t swiftos-osco-fresh.XXXXXX)"
WORK="$(mktemp -t swiftos-osco-img.XXXXXX)"
STORE="$(mktemp -t swiftos-osco-store.XXXXXX)"
MANI="$(mktemp -t swiftos-osco-mani.XXXXXX)"
LOG="$(mktemp -t swiftos-osco-log.XXXXXX)"
QP=""
stop_qemu() { [[ -n "$QP" ]] && { kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null; }; QP=""; }
trap 'stop_qemu; rm -f "$FRESH" "$WORK" "$STORE" "$MANI" "$LOG"' EXIT
export MTOOLS_SKIP_CHECK=1

# A FRESH GPT/ESP disk (kernel A/B, default active=A) + a SWOSBOOT store (both
# slots = base.img) as the base disk. Each case boots a fresh copy of the disk so
# no stale kernel-state (which overrides the manifest) leaks between cases.
"$ROOT/scripts/make-disk.sh" "$FRESH" >/dev/null \
  || { echo "FAIL: could not create the GPT disk image (make disk)" >&2; exit 2; }
"$USTORE" "$STORE" A "$BASE" "$BASE" >/dev/null \
  || { echo "FAIL: could not build the store" >&2; exit 2; }

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    kill -0 "$QP" 2>/dev/null || { grep -qF "$marker" "$LOG" 2>/dev/null && return 0; return 1; }
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
boot_work() {
  : > "$LOG"
  "$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -bios "$AAVMF_CODE" -global virtio-mmio.force-legacy=false \
    -drive "file=$WORK,format=raw,if=none,id=esp" -device virtio-blk-device,drive=esp \
    -drive "file=$STORE,format=raw,if=none,id=swosbase,cache=writethrough" \
    -device virtio-blk-device,drive=swosbase \
    </dev/null >"$LOG" 2>&1 &
  QP=$!
}

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# --- Case A: default active=A -> base coordinated to slot A -------------------
cp "$FRESH" "$WORK"
boot_work
await "UEFI: booted kernel slot A" 60 || fail "caseA: loader did not boot slot A"
await "base slot A coordinated with ESP kernel slot A" 60 || fail "caseA: base not coordinated to the ESP kernel slot A"
await "M11c: read-only base mounted from disk" 60 || fail "caseA: coordinated base did not mount"
stop_qemu

# --- Case B: active=B -> base coordinated to slot B (store active is still A) -
# Fresh disk so no kernel-state from case A (which overrides the manifest) lingers.
cp "$FRESH" "$WORK"
"$KERNELBOOT" "$MANI" B "$KERNEL_SLOT" "$KERNEL_SLOT" "$SIGN_SEED" >/dev/null \
  || fail "could not build active-B kernel manifest"
"$MCOPY" -o -i "${WORK}@@${PART_OFFSET}" "$MANI" ::/EFI/swift-os/kernel-boot \
  || fail "could not write active-B manifest into the ESP"
boot_work
await "UEFI: booted kernel slot B" 60 || fail "caseB: loader did not boot slot B"
await "base slot B coordinated with ESP kernel slot B" 60 || fail "caseB: base did not follow the kernel to slot B (single-authority broken)"
await "M11c: read-only base mounted from disk" 60 || fail "caseB: coordinated base did not mount"
stop_qemu

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: OS-1 coordinated selector — base follows the loader-booted kernel slot via ESP kernel-state (A and B)"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'UEFI:|update-store|M11c|coordinated' >&2 | tail -25
exit 1
