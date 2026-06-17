#!/usr/bin/env bash
# gicv3_test.sh — H1 acceptance: interrupts work under the GICv3 profile.
#
# Boots the kernel on a GICv3 machine (`-M virt,gic-version=3` + `-cpu max`),
# which is the interrupt controller the Hetzner ARM cloud VM presents (GICD +
# per-CPU redistributors + a system-register CPU interface), instead of the
# QEMU `virt` default GICv2 (MMIO CPU interface). It proves the dual-path GIC
# driver detects v3 and that interrupts are live MULTI-CORE before any userland:
#   * the kernel reports "M2 GIC: GICv3 …" (detected via ID_AA64PFR0_EL1.GIC),
#   * CPU0 and a secondary both take their timer IRQ (S2a per-CPU heartbeat),
#   * the secondary comes online (S1), and
#   * SGI/IPI delivery works between CPUs (S3b, via ICC_SGI1R_EL1).
# These markers are emitted during SMP bring-up, before the base FS / userland,
# so the test needs no base image. (The boot then reaches the same point as the
# GICv2 path; a later no-base userland guard is out of scope for this gate.)
#
# Run with `-smp 2` so the secondary-CPU GICv3 redistributor + sysreg interface
# and the SGI path are exercised, not just CPU0.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt-gicv3-smp2.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPUS="${SMP_CPUS:-2}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }

# A GICv3, -smp 2 device tree for the direct-boot harness (loaded at the fixed
# scan address the kernel checks). Dumped on demand so the test is self-contained.
if [[ ! -f "$DTB" ]]; then
  "$QEMU" -M "virt,gic-version=3,dumpdtb=$DTB" -cpu cortex-a72 -smp "$SMP_CPUS" \
    -m 256M -nographic >/dev/null 2>&1 || { echo "FAIL: cannot dump GICv3 DTB" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-gicv3.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-gicv3-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

"$QEMU" -M "virt,gic-version=3" -cpu max -smp "$SMP_CPUS" -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -device "loader,file=$DTB,addr=0x4FF00000,force-raw=on" \
  -kernel "$KERNEL" </dev/null >"$LOG" 2>&1 &
QP=$!

await() {
  local marker="$1" n=0
  while (( n < 200 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    # Stop early on a GIC-stage fault (the abort the GICv2 driver would hit here).
    grep -qF "panic: unexpected EL1 exception" "$LOG" 2>/dev/null && return 1
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

fail() { echo "FAIL: $1"; echo "--- log ---"; sed 's/\r//' "$LOG" | tail -40; exit 1; }

await "M2 GIC: GICv3"                                  || fail "GICv3 not detected (no 'M2 GIC: GICv3')"
await "S2a OK: per-CPU timer heartbeat ready detail=1" || fail "CPU0 took no timer IRQ on GICv3"
await "S2a OK: per-CPU timer heartbeat ready detail=2" || fail "secondary CPU took no timer IRQ on GICv3"
await "S1 OK: secondary CPUs online"                   || fail "secondary CPU did not come online on GICv3"
await "S3b OK: GIC SGI IPI substrate ready"            || fail "SGI/IPI delivery failed on GICv3"

echo "PASS: GICv3 interrupts live — detection + CPU0/secondary timer IRQ + SGI/IPI"
grep -aF "M2 GIC: GICv3" "$LOG" | sed 's/\r//' | head -1
exit 0
