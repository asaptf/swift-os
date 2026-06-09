#!/usr/bin/env bash
# smp_headroom_test.sh - S0i parked-SMP smoke around the default -smp 4 gate.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIMEOUT="${TIMEOUT:-90}"

if [[ -n "${SMP_HEADROOM_CPUS:-}" ]]; then
  read -r -a cpus <<<"$SMP_HEADROOM_CPUS"
else
  cpus=(1 8)
fi

for cpu in "${cpus[@]}"; do
  echo "smp-headroom: checking parked boot with -smp $cpu"
  SMP_CPUS="$cpu" SMP_DTB= TIMEOUT="$TIMEOUT" "$ROOT/tests/smp_boot_test.sh"
done

echo "PASS: SMP parked headroom smoke passed for -smp ${cpus[*]}"
