#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# os_coordinate_activate_test.sh — OS-1b acceptance: `swupdate os` activates the
# single coordinated A/B selector.
#
# In the coordinated topology (UEFI kernel A/B on the ESP + a SWOSBOOT store as
# the base disk), `swupdate os` must flip the ESP kernel-state (the single A/B
# authority) — NOT the store's own SWOSBOOT active — so the loader boots the other
# kernel slot and the base follows it (OS-1a). One boot, no reboot/network:
#   boot (kernel A, base coordinated to A) -> shell ->
#   swupdate os-apply-local <tiny SWSYS> -> stage base into slot B, then flip the
#   ESP selector to kernel slot B.
#
# Asserts the kernel logs the base staged into slot B AND "kernel-store: activated
# kernel slot B" (the ESP selector), and that the store-only SWOSBOOT activate
# path was NOT taken. The bundle's base half is the tiny signed fixture, so this
# proves the delivery+verify+stage+coordinated-activate path (booting onto the
# staged base is covered elsewhere). AAVMF + the baked fixtures (INCLUDE_OS_STAGE_TEST).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
KERNEL_BIN="$ROOT/build/kernel.bin"
USTORE="$ROOT/build/updatestore"
BASE="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
AAVMF_CODE="$(host_aavmf_code)" || true
BUNDLE="/usr/share/swupdate-test/os.swsys"

[[ -f "$AAVMF_CODE" ]] || { echo "SKIP: AAVMF firmware missing at $AAVMF_CODE" >&2; exit 0; }
[[ -x "$USTORE" ]] || { echo "FAIL: $USTORE missing (make updatestore)" >&2; exit 2; }
[[ -f "$BASE" ]]   || { echo "FAIL: $BASE missing (make base-image INCLUDE_OS_STAGE_TEST=1)" >&2; exit 2; }

WORK="$(mktemp -t swiftos-osca-img.XXXXXX)"
STORE="$(mktemp -t swiftos-osca-store.XXXXXX)"
LOG="$(mktemp -t swiftos-osca-log.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-osca-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() { [[ -n "$QP" ]] && { kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null; }; QP=""; exec 3>&- 2>/dev/null || true; }
trap 'stop_qemu; rm -f "$WORK" "$STORE" "$LOG" "$INFIFO"' EXIT
export MTOOLS_SKIP_CHECK=1

"$ROOT/scripts/make-disk.sh" "$WORK" >/dev/null \
  || { echo "FAIL: could not create the GPT disk image (make disk)" >&2; exit 2; }
# Store: both slots = base.img (slot A bootable). SWOSBOOT active = A.
"$USTORE" "$STORE" A "$BASE" "$BASE" >/dev/null \
  || { echo "FAIL: could not build the store" >&2; exit 2; }

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
run_until() { local cmd="$1" marker="$2" tries="${3:-5}" max="${4:-25}" i; for (( i=0; i<tries; i++ )); do send "$cmd"$'\n'; await "$marker" "$max" && return 0; done; return 1; }

: > "$LOG"
"$QEMU" -M virt,acpi=off -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -bios "$AAVMF_CODE" -global virtio-mmio.force-legacy=false \
  -drive "file=$WORK,format=raw,if=none,id=esp,cache=writethrough" -device virtio-blk-device,drive=esp \
  -drive "file=$STORE,format=raw,if=none,id=swosbase,cache=writethrough" -device virtio-blk-device,drive=swosbase \
  <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

if to_shell; then
  await "base slot A coordinated with ESP kernel slot A" 30 || fail "boot: base not coordinated to ESP kernel slot A"
  # swupdate os-apply-local: verify + stage base into slot B + coordinated activate.
  run_until "/bin/swupdate os-apply-local $BUNDLE" "OS staged + ESP selector flipped" 4 30 \
    || fail "swupdate os did not report a coordinated (ESP selector) activate"
  await "update-store: staged base image" 5 || fail "base not staged into the inactive slot"
  await "version 2) into slot B" 5 || fail "staged slot/version not as expected"
  await "kernel-store: activated kernel slot B" 5 || fail "ESP kernel-state selector was not flipped to B"
  grep -qF "update-store: activated slot B (on trial)" "$LOG" \
    && fail "swupdate used the store-only SWOSBOOT activate instead of the ESP selector"
else
  fail "could not reach a shell under AAVMF"
fi
exec 3>&-

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: OS-1b coordinated activate — swupdate os stages the base + flips the single ESP selector (kernel+base together)"
  exit 0
fi
echo "--- serial ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'swupdate|update-store|kernel-store|coordinated|M7 tty|login' >&2 | tail -30
exit 1
