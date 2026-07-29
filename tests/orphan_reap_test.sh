#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# orphan_reap_test.sh — QW3 acceptance: the kernel collects orphaned-child
# zombies instead of leaking their process slots until reboot.
#
# The in-kernel orphan-reap self-test (runOrphanReapDemo in kernel/main.swift)
# runs many rounds of the orphan scenario at boot — a parent forks a child and
# exits without waiting, so the child is reparented to the kernel and later exits
# with no waiter — and asserts that live process slots, PMM frames, and endpoint
# slots all return to baseline. It emits a stable OK marker on success.
#
# This is a boot-time marker test (no login needed): boot the kernel, wait for
# the OK marker, fail on the FAIL marker / panic / timeout. Reparent-and-reap is
# the SMP-sensitive path, so it runs at -smp 1 AND -smp 4.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/bootargs.sh
source "$ROOT/tests/lib/bootargs.sh"
KERNEL="$ROOT/build/kernel.elf"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
TIMEOUT="${TIMEOUT:-120}"
SINGLE_DTB="${SINGLE_DTB:-$ROOT/build/virt.dtb}"
SMP_DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
DTB_ADDR="${DTB_ADDR:-0x4FF00000}"

OK_MARKER="orphan-reap OK: no zombie slot leak across orphan churn"
FAIL_MARKERS=("orphan-reap FAIL" "orphan-reap: demo image missing" "panic:")

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]] || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

run_once() {  # run_once <smp_cpus>
  local cpus="$1"
  local log pidfile qp
  log="$(mktemp -t swiftos-orphan-reap.XXXXXX)"
  pidfile="$(mktemp -t swiftos-orphan-reap-pid.XXXXXX)"
  qp=""

  stop_qemu() {
    if [[ -f "$pidfile" ]]; then
      local pid; pid="$(cat "$pidfile" 2>/dev/null || true)"
      if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
      fi
    fi
    [[ -n "$qp" ]] && wait "$qp" 2>/dev/null || true
  }

  # The S0g PSCI-discovery self-test requires the DTB the kernel boots against:
  # the single-CPU virt.dtb at -smp 1, the 4-CPU virt-smp4.dtb at -smp 4 (matches
  # `make run` / the SMP test harnesses, which always load a matching DTB).
  local dtb="$SINGLE_DTB"
  [[ "$cpus" != "1" ]] && dtb="$SMP_DTB"
  local selftest_dtb
  selftest_dtb="$(mktemp -t swiftos-orphan-selftest.XXXXXX.dtb)"
  bake_selftest_dtb "$dtb" "$selftest_dtb" || { rm -f "$selftest_dtb" "$log" "$pidfile"; return 2; }

  local qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$cpus" -m 256M
    -nographic -no-reboot -pidfile "$pidfile"
    -global virtio-mmio.force-legacy=false)
  if [[ -f "$selftest_dtb" ]]; then
    qemu_args+=(-device "loader,file=$selftest_dtb,addr=$DTB_ADDR,force-raw=on")
  fi
  qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
    -device virtio-blk-device,drive=swosbase
    -kernel "$KERNEL")

  "${qemu_args[@]}" >"$log" 2>&1 &
  qp=$!

  local rc=2 deadline=$((SECONDS + TIMEOUT)) failed=""
  while (( SECONDS < deadline )); do
    for m in "${FAIL_MARKERS[@]}"; do
      if grep -qF "$m" "$log" 2>/dev/null; then failed="$m"; break; fi
    done
    [[ -n "$failed" ]] && { rc=1; break; }
    if grep -qF "$OK_MARKER" "$log" 2>/dev/null; then rc=0; break; fi
    sleep 0.1
  done

  stop_qemu
  rm -f "$selftest_dtb"
  if [[ "$rc" -eq 0 ]]; then
    echo "PASS: orphan-reap self-test OK under -smp $cpus"
    grep -F "orphan-reap: slots base=" "$log" | sed 's/\r//' | tail -1 >&2 || true
  elif [[ "$rc" -eq 1 ]]; then
    echo "FAIL: orphan-reap regression under -smp $cpus (marker: $failed)" >&2
    echo "--- serial tail ---" >&2; sed 's/\r//' "$log" | tail -120 >&2
  else
    echo "FAIL: timed out waiting for orphan-reap OK under -smp $cpus" >&2
    echo "--- serial tail ---" >&2; sed 's/\r//' "$log" | tail -120 >&2
  fi
  rm -f "$log" "$pidfile"
  return "$rc"
}

overall=0
for cpus in 1 4; do
  run_once "$cpus" || overall=1
done

if [[ "$overall" -eq 0 ]]; then
  echo "PASS: QW3 orphan-zombie reaper collects orphans (single-core and -smp 4)"
fi
exit "$overall"
