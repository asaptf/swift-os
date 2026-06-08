#!/usr/bin/env bash
# ipv6_udp_echo_test.sh — IPv6-enabled UDP smoke.
#
# Boots with slirp netdev `ipv6=on` to exercise EUI-64 link-local/NDP setup.
# Darwin QEMU rejects IPv6 hostfwd literals, so on that platform this falls back
# to the dedicated IPv6 smoke test. On QEMU builds that support IPv6 hostfwd,
# the body below remains the place to tighten true AF_INET6 UDP echo coverage.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MSG="swos-ipv6-udp"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
command -v nc >/dev/null 2>&1 || { echo "FAIL: nc not found (needed to send the datagram)" >&2; exit 2; }

if [[ "$(uname -s)" == "Darwin" ]]; then
  if ! "$ROOT/tests/ipv6_smoke_test.sh" >/dev/null; then
    echo "FAIL: IPv6 UDP echo hostfwd skipped on Darwin QEMU, and IPv6 smoke failed" >&2
    exit 1
  fi
  echo "PASS: IPv6 UDP echo hostfwd skipped on Darwin QEMU; IPv6 link-local/NDP smoke passed"
  exit 0
fi

LOG="$(mktemp -t swiftos-ipv6-udp.XXXXXX)"
NCOUT="$(mktemp -t swiftos-ipv6-udp-nc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-ipv6-udp-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-ipv6-udp-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null; rm -f "$LOG" "$NCOUT" "$PIDFILE" "$INFIFO"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

# await: block until a literal MARKER appears in the serial log (bounded).
await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

# Boot QEMU with console driven via FIFO (fd 3). Reactive input prevents flakes.
# netdev has ipv6=on (the point of this dedicated test) plus the IPv4 hostfwd
# path supported by this QEMU build. True nc -6 hostfwd literals are rejected
# here, so that belongs in a later transport-specific test.
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,ipv6=on,hostfwd=udp:127.0.0.1:5555-:5555 \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# Reactive login + launch (same prompts as other net tests). The net stack
# (incl. IPv6 link-local via NDP) initialises very early; we just need past M7.
await "M7 tty: type a line then Enter" 40 && printf 'tty-line\n'     >&3
await "M7 tty: running; press Ctrl-C"  20 && printf '\003'           >&3
await "swift-os login:"                20 && printf 'root\n'         >&3
await "Password:"                      15 && printf 'swordfish\n'    >&3
await "Welcome to swift-os, root"      15 && printf '/bin/udpecho\n' >&3

# Wait for the guest to bind the socket.
listening=0
for _ in $(seq 1 40); do
  if grep -qF "udpecho: listening on 5555" "$LOG"; then listening=1; break; fi
  sleep 1
done

# Main data exchange over IPv4 hostfwd while the NIC is running with ipv6=on.
if [[ "$listening" -eq 1 ]]; then
  printf '%s' "$MSG" | nc -u -w2 127.0.0.1 5555 >"$NCOUT" 2>/dev/null || true
fi

sleep 2
exec 3>&-          # close console stdin
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "net-a: virtio-net up, MAC" <<<"$clean" \
  || { echo "FAIL: virtio-net probe did not run (no dual-stack opportunity)" >&2; ok=0; }
grep -qF "net: IPv6 link-local configured" <<<"$clean" \
  || { echo "FAIL: kernel did not configure IPv6 link-local (EUI-64/NDP path)" >&2; ok=0; }
[[ "$listening" -eq 1 ]] || { echo "FAIL: /bin/udpecho never reported listening" >&2; ok=0; }
grep -Eq "udpecho: got 13 bytes from 10\.0\.2\.2:" <<<"$clean" \
  || { echo "FAIL: guest did not receive the hostfwd datagram under ipv6=on netdev" >&2; ok=0; }
grep -qF "$MSG" "$NCOUT" \
  || { echo "FAIL: host did not receive the echoed datagram back" >&2; ok=0; }

# Final sanity under IPv6-enabled stack.
if grep -qiE 'panic|data abort|undefined instruction|kernel panic' "$LOG"; then
  echo "FAIL: crash seen while IPv6 was active during UDP echo test" >&2
  ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/udpecho UDP round-trip under ipv6=on netdev (NDP + dual-stack smoke)"
  exit 0
fi
echo "--- serial (udpecho region) ---" >&2
sed -n '/udpecho:/,$p' <<<"$clean" | head -20 >&2
echo "--- nc output ---" >&2; cat "$NCOUT" >&2
exit 1
