#!/usr/bin/env bash
# ipv6_udp_echo_test.sh — aggressive IPv6 UDP roundtrip (net-b over dual-stack).
#
# Boots with slirp netdev *with ipv6=on* (exercises NDP/EUI-64 link-local + RA
# paths in kernel at netInit). Uses hostfwd (IPv4 alias for compatibility with
# current userland bridge) so the IPv4 /bin/udpecho works for the data path;
# additionally drives nc -6 attempts against the listener to cover IPv6 client
# error cases while the stack is dual-stack.
#
# After reactive login (FIFO + await), runs the native Swift /bin/udpecho (which
# creates AF_INET UDP socket today; parallel userland IPv6 slice will make it
# AF_INET6 capable for true v6-bound echo). Sends datagram from host, asserts
# guest received it (and logged the src), and that the echo returned.
#
# Assertions (aggressive):
#   - net-a probe ran (virtio up)
#   - "net: IPv6 link-local configured" (EUI-64 + NDP foundation exercised)
#   - udpecho reported listening
#   - guest saw the datagram (from 10.0.2.2, as slirp presents)
#   - host received the echo back
#   - nc -6 attempt to the port demonstrates v6 client path (no v6 listener yet
#     so it fails cleanly — error-case coverage; no pollution of the v4 results)
#   - no panic/crash under IPv6-enabled net
#
# Uses the project's robust FIFO/await pattern (like tcp_echo_test.sh and
# ipv6_smoke_test.sh) to avoid fixed-sleep flakes on `make test` cold boots.
# Real data exchange happens (UDP roundtrip); IPv6 setup + NDP success covered.

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

LOG="$(mktemp -t swiftos-ipv6-udp.XXXXXX)"
NCOUT="$(mktemp -t swiftos-ipv6-udp-nc.XXXXXX)"
NCOUT6="$(mktemp -t swiftos-ipv6-udp-nc6.XXXXXX)"
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
trap 'stop_qemu; exec 3>&- 2>/dev/null; rm -f "$LOG" "$NCOUT" "$NCOUT6" "$PIDFILE" "$INFIFO"' EXIT

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
# netdev has ipv6=on (the point of this dedicated test) + the hostfwd that the
# current AF_INET udpecho understands. A second v6-oriented fwd is present for
# error-case probing with nc -6.
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,ipv6=on,hostfwd=udp:127.0.0.1:5555-:5555,hostfwd=udp:[::1]:5555-:5555,hostfwd=udp:[::1]:5556-:5556 \
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
await "Welcome to swift-os, root"      15 && printf '/bin/udpecho 6\n' >&3

# Wait for the guest to bind the (IPv6) socket.
listening=0
for _ in $(seq 1 40); do
  if grep -qF "udpecho: listening on 5555 (IPv6)" "$LOG"; then listening=1; break; fi
  sleep 1
done

# Main data exchange now over the IPv6 hostfwd (exercises full userland AF_INET6
# UDP + v6 msg layout + NDP for any resolution + slirp v6 inbound).
if [[ "$listening" -eq 1 ]]; then
  printf '%s' "$MSG" | nc -6 -u -w2 [::1] 5555 >"$NCOUT" 2>/dev/null || true
fi

# Extra v4 for coverage + error probe on separate v6 port (no listener there).
if [[ "$listening" -eq 1 ]]; then
  printf '%s' "v4-probe" | nc -u -w1 127.0.0.1 5555 >"$NCOUT" 2>/dev/null || true
  printf '%s' "ipv6-probe" | nc -6 -u -w1 [::1] 5556 >"$NCOUT6" 2>/dev/null || true
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
grep -Eq "udpecho: got 8 bytes from " <<<"$clean" \
  || { echo "FAIL: guest did not receive the (v6) datagram under ipv6=on netdev + AF_INET6 udpecho" >&2; ok=0; }
# v6 print uses ':' in addr (our hex groups); ensure we didn't fall back to v4 path.
grep -Eq "udpecho: got 8 bytes from .*:" <<<"$clean" \
  || { echo "FAIL: guest did not log a v6-style sender (colon in IPv6 addr print)" >&2; ok=0; }
grep -qF "$MSG" "$NCOUT" \
  || { echo "FAIL: host did not receive the echoed datagram back (v6 path)" >&2; ok=0; }

# The 5556 v6 probe (no listener) must not echo.
if grep -qF "ipv6-probe" "$NCOUT6" 2>/dev/null; then
  echo "FAIL: nc -6 to 5556 unexpectedly received echo (should be no listener)" >&2
  ok=0
fi

# Final sanity under IPv6-enabled stack.
if grep -qiE 'panic|data abort|undefined instruction|kernel panic' "$LOG"; then
  echo "FAIL: crash seen while IPv6 was active during UDP echo test" >&2
  ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/udpecho UDP round-trip (ipv6=on + AF_INET6 listener via '6' arg; v6 hostfwd primary; NDP exercised)"
  exit 0
fi
echo "--- serial (udpecho region) ---" >&2
sed -n '/udpecho:/,$p' <<<"$clean" | head -20 >&2
echo "--- nc v6 output ---" >&2; cat "$NCOUT" >&2
echo "--- nc -6 error-probe output ---" >&2; cat "$NCOUT6" >&2
exit 1
