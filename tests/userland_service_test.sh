#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# userland_service_test.sh - LA1 persistent Swift supervisor + UserlandService
# boot smoke under SMP. Proves: a PID-1-style supervisor publishes a service in
# the in-kernel name registry, resolves it back by lookup, spawns a native Swift
# service over the C2 explicit-handle ABI, restarts it across generations, and
# transfers + reclaims a metadata-only device grant over IPC. Mirrors the
# driver_service_test.sh convention (QEMU -M virt -smp 4 + virtio-keyboard-device).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/bootargs.sh
source "$ROOT/tests/lib/bootargs.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPU_COUNT="${SMP_CPUS:-4}"
TIMEOUT="${TIMEOUT:-120}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]] || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-la1-service.XXXXXX)"
SELFTEST_DTB=""
PIDFILE="$(mktemp -t swiftos-la1-service-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE" "${SELFTEST_DTB:-}"' EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M
  -nographic -no-reboot -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
SELFTEST_DTB="$(mktemp -t swiftos-selftest.XXXXXX.dtb)"
bake_selftest_dtb "$DTB" "${SELFTEST_DTB:-}" || exit 2
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=${SELFTEST_DTB:-},addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -device virtio-keyboard-device
  -kernel "$KERNEL")

"${qemu_args[@]}" >"$LOG" 2>&1 &
QP=$!

# Ordered LA1 markers. gen 1 + gen 2 readiness proves the restart loop recovered
# service; the device markers prove the IPC grant transfer + reclaim.
EXPECTS="svc-supervisor: LA1 supervisor active
svc-supervisor: registered service in name registry
svc-supervisor: resolved service endpoint via name lookup
svc-input: LA1 service ready gen 1
svc-supervisor: service exited; restarting next generation
svc-input: LA1 service ready gen 2
svc-input: device grant accepted gen 2
svc-supervisor: device grant transferred via IPC
svc-supervisor: device grant reclaimed
LA1 OK: persistent supervisor + Swift userland service over name-registry grant
LA1 supervisor demo exited, code 0"

FORBIDS="${FORBIDS:-panic:
svc-input: invalid generation
svc-input: device handle missing
svc-input: duplicate device grant
svc-input: device info failed
svc-input: device info mismatch
svc-input: unknown command
svc-supervisor: endpoint_create failed
svc-supervisor: name_register failed
svc-supervisor: name_lookup failed
svc-supervisor: spawn failed
svc-supervisor: ready message mismatch
svc-supervisor: liveness check failed
svc-supervisor: device claim failed
svc-supervisor: device info mismatch
svc-supervisor: device grant send failed
svc-supervisor: moved device fd still valid
svc-supervisor: device ack mismatch
svc-supervisor: stop send failed
svc-supervisor: service exit mismatch
svc-supervisor: reclaim claim failed
svc-supervisor: reclaim info mismatch
svc-supervisor: restart cap reached; giving up
svc-supervisor: generation failed}"

all_found() {
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    grep -qF "$line" "$LOG" 2>/dev/null || return 1
  done <<<"$EXPECTS"
  return 0
}

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  if all_found; then
    stop_qemu
    QP=""
    clean="$(sed 's/\r//' "$LOG")"
    ok=1
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      grep -qF "$line" <<<"$clean" && { echo "FAIL: forbidden marker present: $line" >&2; ok=0; }
    done <<<"$FORBIDS"
    if [[ "$ok" -eq 1 ]]; then
      echo "PASS: LA1 persistent Swift supervisor + userland service boot smoke passed under -smp $SMP_CPU_COUNT"
      exit 0
    fi
    echo "--- serial tail ---" >&2
    tail -120 "$LOG" >&2
    exit 1
  fi
  sleep 0.1
done

stop_qemu
QP=""
echo "FAIL: timed out waiting for LA1 markers under -smp $SMP_CPU_COUNT" >&2
echo "--- serial tail ---" >&2
sed 's/\r//' "$LOG" | tail -160 >&2
exit 1
