#!/usr/bin/env bash
# userland_elf_test.sh — sanity-check the cross-built userland ELF.
#
# Cheap guardrail so a broken userland toolchain fails fast and clearly, before
# the slower in-QEMU boot test. Asserts the embedded program is a static AArch64
# ELF64 executable linked at our userland base (0x80000000).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/host-tools.sh
source "$ROOT/scripts/host-tools.sh"
ELF="$ROOT/build/hello.elf"
READELF="$(host_tool llvm-readelf "${READELF:-}")" || true

if [[ ! -f "$ELF" ]]; then
    echo "FAIL: $ELF not found — run 'make build' first." >&2
    exit 2
fi

hdr="$("$READELF" -h "$ELF" 2>/dev/null)"
fail() { echo "FAIL: userland ELF — $1" >&2; echo "$hdr" >&2; exit 1; }

grep -q "ELF64"                 <<<"$hdr" || fail "not ELF64"
grep -q "AArch64"               <<<"$hdr" || fail "not AArch64"
grep -qE "Type:\s+EXEC"         <<<"$hdr" || fail "not ET_EXEC (static executable)"
grep -qE "Entry point.*0x80000000" <<<"$hdr" || fail "entry not at userland base 0x80000000"

echo "PASS: userland ELF is a static AArch64 ELF64 at 0x80000000"
