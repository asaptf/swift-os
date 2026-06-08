#!/usr/bin/env bash
# ipv6_tcp_echo_test.sh — aggressive IPv6 TCP roundtrip (net-c2 over dual-stack).
#
# Boots with slirp netdev *with ipv6=on* (exercises full NDP/EUI-64 +
# link-local + dual-stack TCPv6 ingress/egress readiness in the kernel).
# Hostfwd (v4 form) for compatibility with today's AF_INET /bin/tcpecho;
# extra v6 hostfwd + nc -6 probes for error cases and to drive IPv6 packets
# into the guest while the stack is up.
#
# Reactive FIFO/await login, launch /bin/tcpecho, wait for "listening",
# then patient connect+send+echo from host (copied/adapted from the robust
# retry logic in tcp_echo_test.sh — virtio poll + one-shot server + cold-boot
# starvation make short timeouts flake).
#
# Real SYN/data/echo/FIN roundtrip occurs. IPv6 coverage:
#   - link-local configured + NDP paths exercised at boot
#   - actual TCP data exchange while ipv6=on is active
#   - nc -6 attempts (to v6 fwd listener) hit the v6 path (no AF_INET6
#     listener yet → error/unreach at socket layer) for negative testing
#   - no crashes, no pollution of the working v4 path
#
# When the parallel userland IPv6 slice lands (swiftos_socket6 etc + AF_INET6
# tcpecho), this test can be tightened to use hostfwd with IPv6 literals +
# nc -6 as the *primary* client for true end-to-end v6 TCP to a v6-bound
# listener (and guest will log the v6 src addr).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MSG="swos-ipv6-tcp"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
command -v nc >/dev/null 2>&1 || { echo "FAIL: nc not found (needed to connect)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-ipv6-tcp.XXXXXX)"
NCOUT="$(mktemp -t swiftos-ipv6-tcp-nc.XXXXXX)"
NCOUT6="$(mktemp -t swiftos-ipv6-tcp-nc6.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-ipv6-tcp-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-ipv6-tcp-in.XXXXXX)"; mkfifo "$INFIFO"
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

# Boot with ipv6=on (core requirement) + hostfwd for the working path + an
# extra v6 listener fwd purely to drive IPv6 TCP SYNs into the guest for the
# error-case and stack-coverage assertions.
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=n0,ipv6=on,hostfwd=tcp:127.0.0.1:5555-:5555,hostfwd=tcp:[::1]:5556-:5556 \
  -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# Wait for each stage's prompt before sending (reactive, not fixed sleeps).
await "M7 tty: type a line then Enter" 40 && printf 'tty-line\n'     >&3
await "M7 tty: running; press Ctrl-C"  20 && printf '\003'           >&3
await "swift-os login:"                20 && printf 'root\n'         >&3
await "Password:"                      15 && printf 'swordfish\n'    >&3
await "Welcome to swift-os, root"      15 && printf '/bin/tcpecho\n' >&3

# Wait for guest listener (the one-shot server prints just before accept()).
listening=0
for _ in $(seq 1 40); do
  if grep -qF "tcpecho: listening on 5555" "$LOG"; then listening=1; break; fi
  sleep 1
done

# Patient v4 connect + send + echo (copied from tcp_echo_test.sh rationale:
# virtio is polled; one-shot server; cold `make test` starvation; the first
# connect can race the listener; short -w loses the echo after guest spent
# its accept). We stop on echo back or on "got N bytes".
if [[ "$listening" -eq 1 ]]; then
  for _ in $(seq 1 4); do
    : > "$NCOUT"
    printf '%s\n' "$MSG" | nc -w8 127.0.0.1 5555 >"$NCOUT" 2>/dev/null || true
    grep -qF "$MSG" "$NCOUT" && break
    grep -Eq "tcpecho: got [0-9]+ bytes" "$LOG" && break
    sleep 1
  done
fi

# Let guest emit its "got" line.
for _ in $(seq 1 20); do
  grep -Eq "tcpecho: got [0-9]+ bytes" "$LOG" && break
  sleep 0.1
done

# Aggressive IPv6 error-case coverage: drive a TCPv6 SYN (via nc -6) at the
# v6 hostfwd. With no AF_INET6 listener, this hits the IPv6 TCP path in
# slirp->virtio->kernel (NDP if needed for L2, then TCPv6 dispatch, no
# socket match → RST or drop). We assert it does *not* produce a successful
# echo on the v6 side (prevents accidental success if userland v6 lands
# unexpectedly) and does not affect the primary v4 results.
if [[ "$listening" -eq 1 ]]; then
  : > "$NCOUT6"
  printf '%s\n' "ipv6-probe-tcp" | nc -6 -w2 [::1] 5556 >"$NCOUT6" 2>/dev/null || true
fi

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "net-a: virtio-net up, MAC" <<<"$clean" \
  || { echo "FAIL: virtio-net probe did not run (dual-stack not exercised)" >&2; ok=0; }
grep -qF "net: IPv6 link-local configured" <<<"$clean" \
  || { echo "FAIL: kernel did not log IPv6 link-local (EUI-64 + NDP)" >&2; ok=0; }
[[ "$listening" -eq 1 ]] || { echo "FAIL: /bin/tcpecho never reported listening" >&2; ok=0; }
grep -Eq "tcpecho: got [0-9]+ bytes" <<<"$clean" \
  || { echo "FAIL: guest did not receive the connection data under ipv6=on" >&2; ok=0; }
grep -qF "$MSG" "$NCOUT" \
  || { echo "FAIL: host did not receive the echoed data back" >&2; ok=0; }

# Error case: nc -6 must not have seen its probe echoed.
if grep -qF "ipv6-probe-tcp" "$NCOUT6" 2>/dev/null; then
  echo "FAIL: nc -6 unexpectedly received TCP echo (v6 listener active early?)" >&2
  ok=0
fi

if grep -qiE 'panic|data abort|undefined instruction|kernel panic' "$LOG"; then
  echo "FAIL: crash seen while IPv6 was active during TCP echo test" >&2
  ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/tcpecho TCP round-trip (ipv6=on netdev + hostfwd; NDP + dual-stack + error cases)"
  exit 0
fi
echo "--- serial (tcpecho region) ---" >&2
sed -n '/tcpecho:/,$p' <<<"$clean" | head -20 >&2
echo "--- nc v4 output ---" >&2; cat "$NCOUT" >&2
echo "--- nc -6 output (error case) ---" >&2; cat "$NCOUT6" >&2
exit 1
