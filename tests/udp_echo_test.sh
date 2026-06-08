#!/usr/bin/env bash
# udp_echo_test.sh — net-b acceptance: a native Swift /bin/udpecho round-trip.
#
# Boots with a slirp NIC that hostfwds host UDP 5555 to the guest. After logging
# in, the shell runs /bin/udpecho, which opens a UDP socket (net capability),
# binds 5555, and echoes the first datagram it receives. Once the guest prints
# its "listening" line we send a datagram from the host with `nc -u`, then assert
# both the guest's "got N bytes from …" line and that nc received the echo back —
# exercising the whole path: driver ↔ sans-IO UDP ↔ socket syscalls ↔ bridge ↔
# userland.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MSG="swos-udp"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
command -v nc >/dev/null 2>&1 || { echo "FAIL: nc not found (needed to send the datagram)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-udp.XXXXXX)"
NCOUT="$(mktemp -t swiftos-udp-nc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-udp-pid.XXXXXX)"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; rm -f "$LOG" "$NCOUT" "$PIDFILE"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

# Feed the console: skip the M7 tty demo, log in as root, then run udpecho. Keep
# stdin open afterwards so udpecho can block on recvfrom and QEMU stays alive.
(
  sleep 8;   printf 'tty-line\n'
  sleep 1;   printf '\003'
  sleep 3;   printf 'root\n'
  sleep 1.5; printf 'swordfish\n'
  sleep 3;   printf '/bin/udpecho\n'
  sleep 20
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,ipv6=on,hostfwd=udp:127.0.0.1:5555-:5555 \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!

# Wait for the guest to bind the socket, then send a datagram from the host.
listening=0
for _ in $(seq 1 40); do
  if grep -qF "udpecho: listening on 5555" "$LOG"; then listening=1; break; fi
  sleep 1
done
if [[ "$listening" -eq 1 ]]; then
  printf '%s' "$MSG" | nc -u -w2 127.0.0.1 5555 >"$NCOUT" 2>/dev/null || true
fi
sleep 2
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
[[ "$listening" -eq 1 ]] || { echo "FAIL: /bin/udpecho never reported listening" >&2; ok=0; }
grep -Eq "udpecho: got 8 bytes from 10\.0\.2\.2:" <<<"$clean" \
  || { echo "FAIL: guest did not receive the datagram" >&2; ok=0; }
grep -qF "$MSG" "$NCOUT" \
  || { echo "FAIL: host did not receive the echoed datagram back" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/udpecho UDP round-trip over slirp hostfwd (net-b acceptance)"
  exit 0
fi
echo "--- serial (udpecho region) ---" >&2
sed -n '/udpecho:/,$p' <<<"$clean" | head -20 >&2
echo "--- nc output ---" >&2; cat "$NCOUT" >&2
exit 1
