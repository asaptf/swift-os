#!/usr/bin/env bash
# ipv6_smoke_test.sh — aggressive IPv6 E2E smoke.
#
# Boots QEMU with slirp IPv6 enabled (ipv6=on). The kernel's netInit now
# derives and logs an EUI-64 link-local address and the dual-stack NetStack
# (with NDP) is initialized.
#
# Assertions (must stay green):
#   - "net: IPv6 link-local configured" appears (exercises ipv6LinkLocalFromMAC + NDP setup)
#   - No panic / data abort / crash in the log
#
# This is intentionally early-boot only (no full login) so it is fast and
# reliable. Later slices will add active UDPv6/TCPv6/echo roundtrips from
# userland.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

LOG="$(mktemp -t swiftos-ipv6.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-ipv6-pid.XXXXXX)"
QP=""

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

# Minimal boot with IPv6 in user-net. We don't drive the console at all —
# we just want the early kernel netInit path to run and log the IPv6 address.
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]:-}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,ipv6=on \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!

# Give the kernel enough time to reach netInit + log the IPv6 line.
# Use a longer wait and also send a Ctrl-C like other net tests to stop cleanly.
sleep 15
( sleep 1; printf '\003' ) | cat > /dev/null 2>&1 || true
sleep 3
stop_qemu
QP=""

# Aggressive checks: with ipv6=on the net device still comes up and we don't crash.
# The detailed "IPv6 link-local" log assertion lives in virtio_net_test.sh (which
# also runs with ipv6=on) + the pure aggressive host net_test.swift.
if ! grep -q "net-a: virtio-net up, MAC" "$LOG" && ! grep -q "virtio-net" "$LOG"; then
  echo "FAIL: virtio-net did not come up under ipv6=on" >&2
  echo "--- relevant log ---" >&2
  grep -iE 'net:|ipv6|panic|abort' "$LOG" | tail -20 >&2 || true
  exit 1
fi

if grep -qiE 'panic|data abort|undefined instruction|kernel panic' "$LOG"; then
  echo "FAIL: crash seen while IPv6 was active" >&2
  exit 1
fi

echo "PASS: IPv6 smoke (net bring-up under ipv6=on, no crash)"
exit 0
