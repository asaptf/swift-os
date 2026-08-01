#!/usr/bin/env bash
# driver_service_test.sh - C5 restartable driver-service boot smoke under SMP.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
# shellcheck source=tests/lib/bootargs.sh
source "$ROOT/tests/lib/bootargs.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
SMP_CPU_COUNT="${SMP_CPUS:-4}"
# Poll ceiling for C5 driver-service markers mid demo sequence (role = DEMO_BOOT_TIMEOUT).
# Override via DEMO_BOOT_TIMEOUT or legacy TIMEOUT.
C5_INPUT_DEVICE="${C5_INPUT_DEVICE:-1}"
C5_AUTHORITY_TEST="${C5_AUTHORITY_TEST:-0}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]] || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-c5-driver.XXXXXX)"
SELFTEST_DTB=""
PIDFILE="$(mktemp -t swiftos-c5-driver-pid.XXXXXX)"
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
  -device virtio-blk-device,drive=swosbase)
if [[ "$C5_INPUT_DEVICE" == "1" ]]; then
  qemu_args+=(-device virtio-keyboard-device)
fi
qemu_args+=(-kernel "$KERNEL")

"${qemu_args[@]}" >"$LOG" 2>&1 &
QP=$!

if [[ -z "${EXPECTS+x}" ]]; then
  EXPECTS="drvsvc: C5a supervisor starting
drvsvc: generation 1 ready
drvsvc: generation 1 event
drvsvc: generation 1 stopped
drvsvc: generation 2 ready
drvsvc: generation 2 event
drvsvc: C5c device manifest matched
drvsvc: C5c discovery exhausted
drvsvc: C5b device grant claimed"
  if [[ "$C5_INPUT_DEVICE" == "1" ]]; then
    EXPECTS="${EXPECTS}
drvsvc: C5d virtio-input metadata discovered
drvsvc: C5c virtio-input grant matched
drvsvc: C5f device grant rights metadata-only
drvsvc: C5b device grant moved
drvinputd: C5b device grant accepted
drvinputd: C5c virtio-input grant accepted
drvsvc: C5b device busy while service owns grant
drvsvc: generation 2 stopped
drvsvc: C5b device grant reclaimed
drvsvc: C5c virtio-input grant reclaimed
C5a OK: restartable driver service recovered over IPC
C5b OK: opaque device handle transferred and released
C5c OK: virtio-input device grant discovered and matched
C5d OK: virtio input discovery metadata surfaced
C5e OK: device authority withheld until explicit handoff
C5f OK: device grant rights stayed metadata-only
C5a driver service demo exited, code 0"
  else
    EXPECTS="${EXPECTS}
drvsvc: C5f device grant rights metadata-only
drvsvc: C5b device grant moved
drvinputd: C5b device grant accepted
drvsvc: C5b device busy while service owns grant
drvsvc: generation 2 stopped
drvsvc: C5b device grant reclaimed
C5a OK: restartable driver service recovered over IPC
C5b OK: opaque device handle transferred and released
C5c OK: device discovery manifest matched pseudo input
C5e OK: device authority withheld until explicit handoff
C5f OK: device grant rights stayed metadata-only
C5a driver service demo exited, code 0"
  fi
fi

FORBIDS="${FORBIDS:-panic:
drvinputd: missing endpoint args
drvinputd: invalid generation
drvinputd: ready send failed
drvinputd: command receive failed
drvinputd: event send failed
drvinputd: device handle missing
drvinputd: duplicate device grant
drvinputd: device info failed
drvinputd: device info mismatch
drvinputd: device ack send failed
drvinputd: unknown command
drvsvc: endpoint_create failed
drvsvc: fork failed
drvsvc: exec drvinputd failed
drvsvc: ready message mismatch
drvsvc: ping send failed
drvsvc: event message mismatch
drvsvc: device discovery failed
drvsvc: device manifest mismatch
drvsvc: device discovery exhaustion failed
drvsvc: device claim failed
drvsvc: device info mismatch
drvsvc: device dup unexpectedly succeeded
drvsvc: device grant send failed
drvsvc: moved device fd still valid
drvsvc: device ack mismatch
drvsvc: busy claim failed
drvsvc: reclaim claim failed
drvsvc: reclaim info mismatch
drvsvc: stop send failed
drvsvc: service wait failed}"

all_found() {
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    grep -qF "$line" "$LOG" 2>/dev/null || return 1
  done <<<"$EXPECTS"
  return 0
}

deadline=$((SECONDS + DEMO_BOOT_TIMEOUT))
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
      if [[ "$C5_AUTHORITY_TEST" == "1" ]]; then
        echo "PASS: C5 restartable driver-service/device-authority boot smoke passed under -smp $SMP_CPU_COUNT"
      elif [[ "$C5_INPUT_DEVICE" == "1" ]]; then
        echo "PASS: C5 restartable driver-service/device-metadata boot smoke passed under -smp $SMP_CPU_COUNT"
      else
        echo "PASS: C5 restartable driver-service/device-discovery boot smoke passed under -smp $SMP_CPU_COUNT"
      fi
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
echo "FAIL: timed out waiting for C5 driver-service markers under -smp $SMP_CPU_COUNT" >&2
echo "--- serial tail ---" >&2
sed 's/\r//' "$LOG" | tail -160 >&2
exit 1
