#!/usr/bin/env bash
# smp_headroom_test.sh - SMP smoke around the default -smp 4 gate.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Delegates to smp_boot_test.sh, which applies DEMO_BOOT_TIMEOUT for the full
# demo-sequence poll. Pass DEMO_BOOT_TIMEOUT or legacy TIMEOUT to override.

if [[ -n "${SMP_HEADROOM_CPUS:-}" ]]; then
  read -r -a cpus <<<"$SMP_HEADROOM_CPUS"
else
  cpus=(1 8)
fi

for cpu in "${cpus[@]}"; do
  echo "smp-headroom: checking S1 boot with -smp $cpu"
  # Do not force a short TIMEOUT here — that would shrink smp_boot's demo-boot
  # ceiling. Let DEMO_BOOT_TIMEOUT / TIMEOUT from the environment flow through.
  SMP_CPUS="$cpu" SMP_DTB= "$ROOT/tests/smp_boot_test.sh"
done

echo "PASS: SMP headroom smoke passed for -smp ${cpus[*]}"
