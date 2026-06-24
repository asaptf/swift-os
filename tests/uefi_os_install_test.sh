#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# uefi_os_install_test.sh — OS-1c-3b acceptance: one SWSYS bundle moves kernel + base.
#
# The coordinated topology (UEFI kernel A/B on the ESP + a SWOSBOOT store as the
# base disk). `swupdate os-apply-local` is given a signed v2 SWSYS bundle whose
# KERNEL half is a genuinely distinct kernel. It must:
#   - stream the base half into the inactive SWOSBOOT store slot (OS-3b), AND
#   - stream the kernel half into the inactive ESP slot, committing the per-slot
#     entry sliced from the bundle's v4 manifest (OS-1c-2b/3 — the kernel re-verifies
#     the per-slot signature + on-disk re-hash), THEN
#   - flip the single ESP selector so kernel + base activate together (OS-1).
#
# One boot, no reboot. Asserts swupdate + the kernel log both halves staged and the
# ESP selector flipped, then (QEMU stopped) mcopy proves the inactive ESP slot now
# holds the NEW kernel while the active slot is byte-for-byte untouched. Booting the
# installed kernel is covered by uefi_kinstall_test; here we prove `swupdate os`
# DRIVES the kernel install from the bundle. AAVMF + baked fixtures
# (INCLUDE_OS_KINSTALL_TEST=1).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$ROOT/build/base.img"
USTORE="$ROOT/build/updatestore"
KERNEL_SLOT="$ROOT/build/kernel-slot.bin"        # original (active) slot image
NEW_KERNEL="$ROOT/build/kinstall-newkernel.bin"  # the bundle's distinct kernel
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="${AAVMF_CODE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
MCOPY="${MCOPY:-/opt/homebrew/bin/mcopy}"
PART_OFFSET=$((2048 * 512))
BUNDLE=/usr/share/swos-kinstall-test/os.swsys

[[ -f "$AAVMF_CODE" ]] || { echo "SKIP: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 0; }
[[ -f "$BASE" ]]        || { echo "FAIL: $BASE missing (make base-image INCLUDE_OS_KINSTALL_TEST=1)" >&2; exit 2; }
[[ -x "$USTORE" ]]      || { echo "FAIL: $USTORE missing (make updatestore)" >&2; exit 2; }
[[ -f "$KERNEL_SLOT" ]] || { echo "FAIL: $KERNEL_SLOT missing" >&2; exit 2; }
[[ -f "$NEW_KERNEL" ]]  || { echo "FAIL: $NEW_KERNEL missing" >&2; exit 2; }
[[ -x "$MCOPY" ]]       || { echo "FAIL: missing mtools $MCOPY" >&2; exit 2; }

WORK="$(mktemp -t swiftos-osi-img.XXXXXX)"
STORE="$(mktemp -t swiftos-osi-store.XXXXXX)"
SLOTA="$(mktemp -t swiftos-osi-slota.XXXXXX)"
SLOTB="$(mktemp -t swiftos-osi-slotb.XXXXXX)"
LOG="$(mktemp -t swiftos-osi-log.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-osi-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() { [[ -n "$QP" ]] && { kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null; }; QP=""; exec 3>&- 2>/dev/null || true; }
trap 'stop_qemu; rm -f "$WORK" "$STORE" "$SLOTA" "$SLOTB" "$LOG" "$INFIFO"' EXIT
export MTOOLS_SKIP_CHECK=1

"$ROOT/scripts/make-disk.sh" "$WORK" >/dev/null \
  || { echo "FAIL: could not create the GPT disk image (make disk)" >&2; exit 2; }
# Store: both slots = base.img (slot A bootable). SWOSBOOT active = A.
"$USTORE" "$STORE" A "$BASE" "$BASE" >/dev/null \
  || { echo "FAIL: could not build the store" >&2; exit 2; }

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }
await() { local m="$1" max="${2:-90}" n=0; while (( n < max*10 )); do grep -qF "$m" "$LOG" 2>/dev/null && return 0; kill -0 "$QP" 2>/dev/null || return 1; sleep 0.1; n=$((n+1)); done; return 1; }
send() { sleep 0.3; local s="$1" i; for (( i=0; i<${#s}; i++ )); do printf '%s' "${s:i:1}" >&3; sleep 0.03; done; }
to_shell() {
  await "M7 tty: type a line then Enter" 120 || return 1
  send $'tty-line\n'; await "M7 tty: running; press Ctrl-C" 60 || return 1
  send $'\003'; await "swift-os login:" 120 || return 1
  send $'root\n'; await "Password:" 90 || return 1
  send $'swordfish\n'; await "M12c: shell ready" 150 || return 1
  return 0
}
run_until() { local cmd="$1" marker="$2" tries="${3:-4}" max="${4:-60}" i; for (( i=0; i<tries; i++ )); do send "$cmd"$'\n'; await "$marker" "$max" && return 0; done; return 1; }

: > "$LOG"
"$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -bios "$AAVMF_CODE" -global virtio-mmio.force-legacy=false \
  -drive "file=$WORK,format=raw,if=none,id=esp,cache=writethrough" -device virtio-blk-device,drive=esp \
  -drive "file=$STORE,format=raw,if=none,id=swosbase,cache=writethrough" -device virtio-blk-device,drive=swosbase \
  <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

if to_shell; then
  await "base slot A coordinated with ESP kernel slot A" 30 || fail "boot: base not coordinated to ESP kernel slot A"
  # One bundle: install the kernel into the inactive ESP slot + stage the base, then flip.
  run_until "/bin/swupdate os-apply-local $BUNDLE" "OS staged + ESP selector flipped" 3 90 \
    || fail "swupdate did not report a coordinated kernel+base activate"
  grep -qF "kernel-store: installed new kernel into inactive slot B" "$LOG" \
    || fail "kernel did not install the new kernel into the inactive ESP slot B"
  grep -qF "swupdate: new kernel installed into the inactive ESP slot (verified)" "$LOG" \
    || fail "swupdate did not confirm the kernel half install"
  grep -qF "kernel-store: activated kernel slot B" "$LOG" \
    || fail "ESP selector was not flipped to slot B"
else
  fail "could not reach a shell"
fi
exec 3>&-; stop_qemu

# Host: prove the inactive ESP slot now holds the NEW kernel and slot A is untouched.
if [[ "$ok" -eq 1 ]]; then
  "$MCOPY" -n -i "${WORK}@@${PART_OFFSET}" ::/EFI/swift-os/kernelB.bin "$SLOTB" 2>/dev/null || fail "could not read back kernelB.bin"
  "$MCOPY" -n -i "${WORK}@@${PART_OFFSET}" ::/EFI/swift-os/kernelA.bin "$SLOTA" 2>/dev/null || fail "could not read back kernelA.bin"
  cmp -s "$SLOTB" "$NEW_KERNEL"  || fail "inactive ESP slot B does not hold the bundle's new kernel"
  cmp -s "$SLOTA" "$KERNEL_SLOT" || fail "active ESP slot A was modified"
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: OS-1c-3b — swupdate os installs BOTH halves from one SWSYS bundle (new kernel into the inactive ESP slot, verified per-slot; base into the store slot) and flips the single selector; active slot untouched"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'swupdate|update-store|kernel-store|coordinated|login' >&2 | tail -30
exit 1
