#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ns3_net_service_test.sh - NS3: a restartable userland net service relays frames
# over an shmring data plane, driving a secondary NIC from EL0.
#
# Boots with TWO virtio-net (slirp) devices under -smp 4. The supervisor/client
# (/bin/netsvc-demo) creates a full-duplex shmring channel and, for two generations,
# spawns /bin/netsvc (which owns virtio-net.1), hands it an ARP request FRAME over
# ring0; the service transmits it on the NIC and forwards slirp's reply FRAME back
# over ring1, which the client verifies. Asserts:
#   * the service came up and relayed the ARP reply in generation 1;
#   * the service was stopped and a RESTARTED instance recovered in generation 2
#     (kill+restart recovery over the same data plane);
#   * the NS3 success marker; and the primary kernel NIC stays up (ICMP echo).
# Forbids panic / service failure markers.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
SMP_CPU_COUNT="${SMP_CPUS:-4}"
if [[ "$SMP_CPU_COUNT" -gt 1 ]]; then
  DTB="${SMP_DTB:-$ROOT/build/virt-smp4.dtb}"
else
  DTB="${SMP_DTB:-$ROOT/build/virt.dtb}"
fi
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
TIMEOUT="${TIMEOUT:-120}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]] || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-ns3.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-ns3-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$PIDFILE"' EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -smp "$SMP_CPU_COUNT" -m 256M
  -nographic -no-reboot -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev user,id=n0 -device virtio-net-device,netdev=n0
  -netdev user,id=n1 -device virtio-net-device,netdev=n1
  -kernel "$KERNEL")

"${qemu_args[@]}" >"$LOG" 2>&1 &
QP=$!

EXPECTS="net-a OK: ICMP echo reply from 10.0.2.2
netsvc: ready gen 1
netsvc-demo: gen 1 relayed ARP reply, 10.0.2.2 is at 52:55:0a:00:02:02
netsvc-demo: service stopped; restarting next generation
netsvc: ready gen 2
netsvc-demo: gen 2 relayed ARP reply, 10.0.2.2 is at 52:55:0a:00:02:02
NS3 OK: restartable userland net service relayed frames over shmring
NS3 net service demo exited, code 0"

FORBIDS="panic:
netsvc-demo: no secondary virtio-net device; skipping
netsvc-demo: spawn failed
netsvc-demo: service not ready
netsvc-demo: no arp reply over shmring
netsvc-demo: service exit mismatch
netsvc-demo: shmring create failed
netsvc: virtio-net init failed
netsvc: shmring map failed"

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
      echo "PASS: NS3 restartable userland net service relayed frames over shmring under -smp $SMP_CPU_COUNT"
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
echo "FAIL: timed out waiting for NS3 markers under -smp $SMP_CPU_COUNT" >&2
echo "--- serial tail ---" >&2
sed 's/\r//' "$LOG" | tail -160 >&2
exit 1
