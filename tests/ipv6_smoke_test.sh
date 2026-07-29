#!/usr/bin/env bash
# ipv6_smoke_test.sh — aggressive IPv6 E2E smoke (robust).
#
# Boots QEMU with slirp IPv6 enabled (ipv6=on). Asserts that the early kernel
# netInit path runs and logs the EUI-64 link-local address (exercises the
# IPv6 + NDP/RA foundation).
#
# This version uses the project's standard robust test pattern:
#   - FIFO for reactive console control (avoids fixed-sleep flakes on slow boots)
#   - await() polling for log markers with bounded retries
#   - Minimal input to get past M7 tty demo (Ctrl-C), then wait for the IPv6 log
#
# Assertions (must stay green):
#   - "net: IPv6 link-local configured" appears in the log
#   - No panic / data abort / crash
#
# Complements the IPv6-enabled udp/tcp smoke scripts by covering the pure
# link-local/NDP setup path even when hostfwd behavior varies across QEMU hosts.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${IPV6_SMOKE_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${IPV6_SMOKE_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-ipv6.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-ipv6-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-ipv6-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

# await: block until a literal MARKER appears in the serial log (bounded).
await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}


# Boot QEMU with console driven via FIFO (fd 3). This makes input reactive
# instead of fixed sleeps, which is the main source of flakes on cold/slow
# `make test` boots.
qemu_args+=(
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev user,id=n0,ipv6=on
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL"
)
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# Minimal reactive input to get past the M7 tty demo (the kernel net stack
# initialises very early, but the M7 demo can delay visible progress).
# We don't need full login for this smoke — we just need the kernel to have
# run netInit and printed the IPv6 line.
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" && send_line 'tty-line'
await "M7 tty: running; press Ctrl-C"  20 && printf '\003'           >&3

# Now wait specifically for the IPv6 link-local configuration log.
# This is the key assertion that the dual-stack + NDP/EUI-64 path ran.
if ! await "net: IPv6 link-local configured" 30; then
  echo "FAIL: kernel did not log IPv6 link-local (EUI-64 + NDP path)" >&2
  echo "--- relevant log ---" >&2
  grep -iE 'net:|ipv6|panic|abort|M7' "$LOG" | tail -30 >&2 || true
  exit 1
fi

exec 3>&-
stop_qemu
QP=""

# Final sanity: no crash through the IPv6 link-local acceptance point.
if grep -qiE 'panic|data abort|undefined instruction|kernel panic' "$LOG"; then
  echo "FAIL: crash seen while IPv6 was active" >&2
  echo "--- relevant log ---" >&2
  grep -iE 'panic|abort' "$LOG" | tail -10 >&2 || true
  exit 1
fi

echo "PASS: IPv6 smoke (link-local configured under ipv6=on, no crash)"
exit 0
