#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ns2_net_driver_test.sh - NS2: a userland virtio-net driver does real TX/RX on a
# secondary NIC, without disturbing the primary kernel-owned NIC.
#
# Boots with TWO virtio-net (slirp) devices under -smp 4. The in-kernel net driver
# binds the first NIC (primary); the userland driver (/bin/netdriverprobe) claims the
# secondary grant virtio-net.1, brings up the RX/TX virtqueues entirely from EL0
# (resolving ring/buffer physical addresses via virt_to_phys), and performs an ARP
# round-trip against slirp. Asserts:
#   * the primary kernel NIC is unaffected (still gets an ICMP echo reply);
#   * the userland driver came up on virtio-net.1 and completed the ARP round-trip
#     (NS2 OK: it received slirp's ARP reply, 10.0.2.2 is at 52:55:0a:00:02:02).
# Forbids panic / driver failure markers.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
# shellcheck source=tests/lib/bootargs.sh
source "$ROOT/tests/lib/bootargs.sh"
KERNEL="$ROOT/build/kernel.elf"
SMP_CPU_COUNT="${SMP_CPUS:-4}"
if [[ "$SMP_CPU_COUNT" -gt 1 ]]; then
  DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
else
  DTB="${SMP_DTB:-$ROOT/build/virt.dtb}"
fi
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
# Poll ceiling for NS2 markers emitted mid demo sequence (role = DEMO_BOOT_TIMEOUT).
# Override via DEMO_BOOT_TIMEOUT or legacy TIMEOUT.

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]] || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-ns2.XXXXXX)"
SELFTEST_DTB=""
PIDFILE="$(mktemp -t swiftos-ns2-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
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
  -netdev user,id=n0 -device virtio-net-device,netdev=n0
  -netdev user,id=n1 -device virtio-net-device,netdev=n1
  -kernel "$KERNEL")

"${qemu_args[@]}" >"$LOG" 2>&1 &
QP=$!

EXPECTS="net-a OK: ICMP echo reply from 10.0.2.2
NS2: userland virtio-net up on virtio-net.1
NS2 OK: userland virtio-net TX/RX — ARP reply, 10.0.2.2 is at 52:55:0a:00:02:02
NS2 net driver probe exited, code 0"

FORBIDS="panic:
netdriverprobe: net grant not usable
netdriverprobe: device_mmap failed
netdriverprobe: queue setup failed
netdriverprobe: buffer mmap failed
netdriverprobe: rx virt_to_phys failed
netdriverprobe: tx virt_to_phys failed
netdriverprobe: FEATURES_OK rejected
netdriverprobe: no ARP reply received"

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
      echo "PASS: NS2 userland virtio-net driver did TX/RX on a secondary NIC under -smp $SMP_CPU_COUNT"
      exit 0
    fi
    echo "--- serial tail ---" >&2
    sed 's/\r//' "$LOG" | tail -120 >&2
    exit 1
  fi
  sleep 0.1
done

stop_qemu
QP=""
echo "FAIL: timed out waiting for NS2 markers under -smp $SMP_CPU_COUNT" >&2
echo "--- serial tail ---" >&2
sed 's/\r//' "$LOG" | tail -160 >&2
exit 1
