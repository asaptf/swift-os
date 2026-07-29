# SPDX-License-Identifier: Apache-2.0
#
# bootargs.sh — bake FDT /chosen/bootargs into a DTB copy for QEMU -kernel tests.
#
# Our harness injects the DTB via `-device loader,file=...,addr=0x4FF00000`, not
# QEMU `-dtb`. With that path, QEMU `-append` does not reach the kernel's
# /chosen/bootargs parser (verified empirically). Follow the existing precedent
# in tests/v2_anchor_test.sh / tests/passwd_recovery_test.sh: decompile, insert
# bootargs under /chosen, recompile.
#
# Usage (after ROOT is set):
#   # shellcheck source=tests/lib/bootargs.sh
#   source "$ROOT/tests/lib/bootargs.sh"
#   SELFTEST_DTB="$(mktemp -t swiftos-selftest.XXXXXX.dtb)"
#   bake_selftest_dtb "$DTB" "$SELFTEST_DTB"
#   # then -device loader,file=$SELFTEST_DTB,addr=0x4FF00000,force-raw=on
#   # and rm -f "$SELFTEST_DTB" in the test cleanup trap.

# bake_bootargs SRC_DTB DST_DTB BOOTARGS
# Writes DST_DTB with /chosen/bootargs set to BOOTARGS. Overwrites any existing
# bootargs property in /chosen. Requires `dtc` on PATH.
bake_bootargs() {
  local src="$1" dst="$2" args="$3"
  if [[ ! -f "$src" ]]; then
    echo "FAIL: bake_bootargs: missing source DTB $src" >&2
    return 2
  fi
  if ! command -v dtc >/dev/null 2>&1; then
    echo "FAIL: bake_bootargs: dtc not installed" >&2
    return 2
  fi
  local tmp_dts
  tmp_dts="$(mktemp -t swiftos-bootargs.XXXXXX.dts)"
  dtc -I dtb -O dts "$src" 2>/dev/null \
    | awk -v b="\t\tbootargs = \"${args}\";" '
        /chosen \{/ { print; print b; next }
        /bootargs = / { next }
        { print }
      ' >"$tmp_dts"
  if ! dtc -I dts -O dtb "$tmp_dts" 2>/dev/null >"$dst"; then
    rm -f "$tmp_dts"
    echo "FAIL: bake_bootargs: dtc recompile failed" >&2
    return 2
  fi
  rm -f "$tmp_dts"
  if ! strings "$dst" | grep -qF "$args"; then
    echo "FAIL: bake_bootargs: could not bake '$args' into $dst" >&2
    return 2
  fi
  return 0
}

# bake_selftest_dtb SRC_DTB DST_DTB — convenience for the milestone opt-in flag.
bake_selftest_dtb() {
  bake_bootargs "$1" "$2" "selftest=1"
}
