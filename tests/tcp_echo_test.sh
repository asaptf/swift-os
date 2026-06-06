#!/usr/bin/env bash
# tcp_echo_test.sh — net-c2 acceptance: a native Swift /bin/tcpecho round-trip.
#
# Boots with a slirp NIC that hostfwds host TCP 5555 to the guest. After logging
# in, the shell runs /bin/tcpecho, which opens a TCP socket (net capability),
# binds 5555, listens, accepts one connection, reads a chunk, echoes it, and
# closes. Once the guest prints "listening" we connect from the host with `nc`,
# send a line, and assert both the guest's "got N bytes" line and that nc got the
# echo back — the full SYN/data/echo/FIN round-trip driven by our TCP engine.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MSG="swos-tcp"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
command -v nc >/dev/null 2>&1 || { echo "FAIL: nc not found (needed to connect)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-tcp.XXXXXX)"
NCOUT="$(mktemp -t swiftos-tcp-nc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-tcp-pid.XXXXXX)"
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

# Feed the console: skip the M7 tty demo, log in as root, then run tcpecho. Keep
# stdin open afterwards so the server can accept/echo and QEMU stays alive.
(
  sleep 8;   printf 'tty-line\n'
  sleep 1;   printf '\003'
  sleep 3;   printf 'root\n'
  sleep 1.5; printf 'swordfish\n'
  sleep 3;   printf '/bin/tcpecho\n'
  sleep 20
) | "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5555-:5555 \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" >"$LOG" 2>&1 &
QP=$!

# Wait for the guest to listen, then connect + send a line from the host.
listening=0
for _ in $(seq 1 40); do
  if grep -qF "tcpecho: listening on 5555" "$LOG"; then listening=1; break; fi
  sleep 1
done
if [[ "$listening" -eq 1 ]]; then
  printf '%s\n' "$MSG" | nc -w3 127.0.0.1 5555 >"$NCOUT" 2>/dev/null || true
fi
sleep 2
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
[[ "$listening" -eq 1 ]] || { echo "FAIL: /bin/tcpecho never reported listening" >&2; ok=0; }
grep -Eq "tcpecho: got [0-9]+ bytes" <<<"$clean" \
  || { echo "FAIL: guest did not receive the connection's data" >&2; ok=0; }
grep -qF "$MSG" "$NCOUT" \
  || { echo "FAIL: host did not receive the echoed data back" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/tcpecho TCP round-trip over slirp hostfwd (net-c2 acceptance)"
  exit 0
fi
echo "--- serial (tcpecho region) ---" >&2
sed -n '/tcpecho:/,$p' <<<"$clean" | head -20 >&2
echo "--- nc output ---" >&2; cat "$NCOUT" >&2
exit 1
