#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# device_mmio_map_test.sh - LA2 device-MMIO-map authority end to end.
#
# Boots the base image with a virtio-input window present. The capConsole boot
# probe (/bin/devicemmapprobe, run from kernel/main.swift) claims the mappable
# grant, sys_device_mmap's the window Device-nGnRE, and reads the virtio
# identification registers through it. This test asserts:
#   * a capConsole principal that claims a mappable device gets a `.map` grant
#     and device_mmap returns a valid pointer (DEVMMAP-CLAIM-OK + a live mapping);
#   * reading a known device register through the mapping returns the expected
#     virtio magic + device-id (DEVMMAP-MAGIC-OK / DEVMMAP-DEVID-OK);
#   * a grant on a deviceFlagNoMmioGrant device is refused with EACCES
#     (DEVMMAP-NOMMIO-REFUSED-OK err=-13);
#   * a non-capConsole principal (the interactive `guest` login) cannot claim or
#     map the device at all (DEVMMAP-CLAIM-DENY-OK err=-13).
# Runs single-core by default; the Makefile target also runs it under -smp 4.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
SMP_CPU_COUNT="${SMP_CPUS:-1}"
if [[ "$SMP_CPU_COUNT" -gt 1 ]]; then
  DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
else
  DTB="${SMP_DTB:-$ROOT/build/virt.dtb}"
fi
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-devmmap.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-devmmap-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-devmmap-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (device mmio map probe) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  exit 1
}

send_line() {
  local line="$1" delay="${DEVMMAP_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${DEVMMAP_SEND_DELAY:-0.08}"
}

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -device virtio-keyboard-device
  -kernel "$KERNEL")
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# 1. Wait for the capConsole boot probe to finish (positive + EACCES-refusal path).
await "DEVMMAP OK: device MMIO map authority enforced" 120 \
  || drive_fail "capConsole device-mmap boot probe did not complete"

# 2. Drive an interactive non-console login and run the probe as the guest
#    principal: device_claim must be denied (EACCES) before any mapping.
await "M7 tty: type a line then Enter" 60 || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "timed out waiting for login prompt"
send_line 'guest'
await "Password:" 90 || drive_fail "timed out waiting for password prompt"
send_line 'guest'
await "session: principal=3 session=3 caps=2" 120 || drive_fail "guest did not log in with the restricted context"
send_line '/bin/devicemmapprobe'
await "DEVMMAP-CLAIM-DENY-OK err=-13" 60 \
  || drive_fail "non-console principal was not denied the device claim"
send_line 'exit'
await "M12c: session ended" 60 || true

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1

# Positive + EACCES-refusal markers from the capConsole boot probe, plus the
# non-console denial from the interactive guest run.
for marker in \
  "DEVMMAP-CLAIM-OK" \
  "DEVMMAP-MAGIC-OK" \
  "DEVMMAP-DEVID-OK" \
  "DEVMMAP-NOMMIO-REFUSED-OK err=-13" \
  "DEVMMAP OK: device MMIO map authority enforced" \
  "DEVMMAP-CLAIM-DENY-OK err=-13"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; ok=0; }
done

for marker in \
  "DEVMMAP-MAGIC-BAD" \
  "DEVMMAP-MAP-FAIL" \
  "DEVMMAP-FLAG-MISSING" \
  "DEVMMAP-LEN-ZERO" \
  "DEVMMAP-CLAIM-FAIL" \
  "DEVMMAP-NOMMIO-LEAK" \
  "DEVMMAP-NO-DEVICE" \
  "panic:"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; ok=0; }
done

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: LA2 device MMIO map authority enforced end to end under -smp $SMP_CPU_COUNT"
  exit 0
fi
echo "--- serial (device mmio map region) ---" >&2
sed -n '/LA2: device MMIO map/,$p' <<<"$clean" >&2
exit 1
