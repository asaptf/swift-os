#!/usr/bin/env bash
# virtio_net_test.sh — net-a acceptance: bring up virtio-net and ping the gateway.
#
# Attaches a QEMU user-mode network (slirp) NIC. slirp gives the guest 10.0.2.15
# and emulates a gateway at 10.0.2.2 that answers ARP and ICMP echo. The kernel's
# net-a probe brings up the virtio-net device discovered in the virtio-mmio
# window, ARPs the gateway, then sends an ICMP echo request and waits for the
# echo reply — proving driver RX/TX plus the sans-IO Ethernet/ARP/IPv4/ICMP core
# end to end, against a real (emulated) network.

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

LOG="$(mktemp -t swiftos-net.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-net-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.2
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  if [[ -n "$QP" ]]; then
    wait "$QP" 2>/dev/null || true
  fi
}
cleanup() {
  stop_qemu
  rm -f "$LOG" "$PIDFILE"
}
trap cleanup EXIT

dtb_args=()
if [[ -f "$DTB" ]]; then
  dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi

# A user-mode (slirp) NIC as a modern (v2) virtio-mmio device. The base image
# rides along as a virtio-blk disk so the boot path is identical to the others.
# The net-a probe runs early in boot; a short Ctrl-C just stops the kernel.
( sleep 9; printf '\003'; sleep 1 ) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]:-}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,ipv6=on \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!
sleep 12
stop_qemu
QP=""

ok=1
grep -qF "net-a: virtio-net up, MAC" "$LOG" || { echo "FAIL: virtio-net device not brought up" >&2; ok=0; }
grep -qF "net-a: ARP reply, 10.0.2.2 is at" "$LOG" || { echo "FAIL: gateway ARP not resolved" >&2; ok=0; }
grep -qF "net-a OK: ICMP echo reply from 10.0.2.2" "$LOG" || { echo "FAIL: no ICMP echo reply from gateway" >&2; ok=0; }
grep -qF "net: IPv6 link-local configured" "$LOG" || { echo "FAIL: IPv6 link-local not configured (dual-stack / NDP path not exercised)" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: virtio-net ARP + ICMP echo against slirp gateway (net-a acceptance)"
  exit 0
fi
echo "--- serial log ---" >&2
sed 's/\r//' "$LOG" | grep -iE "M9 platform|net-a|virtio|panic" >&2
exit 1
