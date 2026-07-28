#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# c5_tty_inject_test.sh - C5j: the userland virtio-input driver injects decoded
# keystrokes into the kernel tty, restoring interactive keyboard.
#
# Boots the base image with a virtio-input window. swos-init launches the persistent
# /bin/inputd driver, which owns the device (the kernel skipped its polled driver at
# C5i) and runs a forever poll+inject loop. The test drives past the serial milestone
# demos to the login prompt, then uses QMP send-key to inject key events INTO the
# virtio-input device (not the serial line). inputd decodes them and feeds them to the
# kernel tty via SYS_tty_inject, where console-login reads them. Asserts:
#   * inputd came up and owns the device (driver-ready marker);
#   * a send-key'd character is injected and reaches the tty
#     (C5j OK: TTY bytes injected from userland driver), and the byte appears at the
#     login prompt (proving it reached the line discipline, not just the driver).
# Requires python3 for the QMP socket; SKIPs cleanly without it.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
SMP_CPU_COUNT="${SMP_CPUS:-4}"
if [[ "$SMP_CPU_COUNT" -gt 1 ]]; then
  DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
else
  DTB="${SMP_DTB:-$ROOT/build/virt.dtb}"
fi
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]] || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }
command -v python3 >/dev/null || { echo "SKIP: python3 not found (needed for QMP send-key)" >&2; exit 0; }

LOG="$(mktemp -t swiftos-c5j.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-c5j-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-c5j-in.XXXXXX)"; mkfifo "$INFIFO"
QMP="$(mktemp -u -t swiftos-c5j-qmp.XXXXXX).sock"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO" "$QMP"' EXIT

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-40}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

fail() {
  echo "FAIL: $1" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

send_line() {
  local line="$1" i
  for (( i = 0; i < ${#line}; i++ )); do printf '%s' "${line:i:1}" >&3; sleep 0.01; done
  printf '\n' >&3; sleep 0.08
}

# Type a word followed by Enter INTO the virtio-input device over QMP. Each arg is
# a QEMU qcode; we append "ret". inputd must decode these and feed them to the tty.
send_keys() {
  python3 - "$QMP" "$@" <<'PY'
import socket, json, sys, time
sock = socket.socket(socket.AF_UNIX); sock.connect(sys.argv[1]); f = sock.makefile('rw')
f.readline()
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
for qcode in sys.argv[2:]:
    f.write(json.dumps({"execute": "send-key",
            "arguments": {"keys": [{"type": "qcode", "data": qcode}]}}) + "\n")
    f.flush(); f.readline(); time.sleep(0.12)
PY
}

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE" -global virtio-mmio.force-legacy=false
  -qmp "unix:$QMP,server,nowait")
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

# 1. Kernel must have handed virtio-input to userland (C5i precondition).
# Early assertion — short ceiling; not the demo-boot wait.
await "virtio-kbd: kernel skipped virtioKbdInit (userland driver owns virtio-input)" 60 \
  || fail "kernel did not skip its in-kernel virtio-input driver"

# 2. Drive past the serial milestone tty demo so boot reaches swos-init.
# First readiness await covering the pre-login demo boot (role = DEMO_BOOT_TIMEOUT).
await "M7 tty: type a line" "$DEMO_BOOT_TIMEOUT" || fail "timed out waiting for tty line prompt"
send_line 'x'
await "M7 tty: running; press Ctrl-C" 40 || fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3

# 3. swos-init launches inputd, which claims the device and brings the queue up.
await "inputd: virtio-input driver ready; injecting to tty" 90 \
  || fail "persistent userland input driver did not come up"
await "swift-os login:" 60 || fail "login prompt did not appear"

# 4. Type "guest<Enter>" into the virtio device. inputd must decode each key and
#    feed it to the tty; console-login must read the whole username line (proving the
#    injected bytes — including the newline — reached the line discipline and a real
#    reader) and advance to the password prompt.
send_keys g u e s t ret
await "C5j OK: TTY bytes injected from userland driver" 30 \
  || fail "userland driver did not inject a send-key'd byte into the tty"
await "Password:" 30 \
  || fail "injected keystrokes did not drive console-login through a username line read"

stop_qemu
QP=""
clean="$(sed 's/\r//' "$LOG")"

for marker in \
  "virtio-kbd: kernel skipped virtioKbdInit (userland driver owns virtio-input)" \
  "inputd: virtio-input driver ready; injecting to tty" \
  "C5j OK: TTY bytes injected from userland driver"; do
  grep -qF "$marker" <<<"$clean" || { echo "FAIL: missing marker: $marker" >&2; exit 1; }
done
for marker in "panic:" "inputd: device_mmap failed" "inputd: virtio init failed" "inputd: device grant not usable"; do
  grep -qF "$marker" <<<"$clean" && { echo "FAIL: forbidden marker present: $marker" >&2; exit 1; }
done

echo "PASS: C5j userland driver injects virtio key events into the tty under -smp $SMP_CPU_COUNT"
exit 0
