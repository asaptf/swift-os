#!/usr/bin/env bash
# ipv6_tcp_echo_test.sh — IPv6-enabled TCP smoke.
#
# Boots with slirp netdev `ipv6=on` to exercise EUI-64 link-local/NDP setup.
# When this QEMU on this host cannot bind the IPv6 hostfwd literals used below
# (common on Darwin and on Linux runners without usable IPv6), fall back to the
# dedicated IPv6 smoke test. The decision is a capability probe, not an OS-name
# check: hosts that can bind `[::1]` hostfwd still run the full echo body.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MSG="swos-ipv6-tcp"

# shellcheck source=tests/lib/ipv6_hostfwd.sh
source "$ROOT/tests/lib/ipv6_hostfwd.sh"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
command -v nc >/dev/null 2>&1 || { echo "FAIL: nc not found (needed to connect)" >&2; exit 2; }

skip_to_ipv6_smoke() {
  local why="$1"
  if ! "$ROOT/tests/ipv6_smoke_test.sh" >/dev/null; then
    echo "FAIL: IPv6 TCP echo hostfwd skipped ($why), and IPv6 smoke failed" >&2
    exit 1
  fi
  echo "PASS: IPv6 TCP echo hostfwd skipped (capability probe: $why); IPv6 link-local/NDP smoke passed"
  exit 0
}

PROBE_REASON=""
if ! PROBE_REASON="$(qemu_ipv6_hostfwd_available)"; then
  skip_to_ipv6_smoke "${PROBE_REASON:-QEMU refused IPv6 hostfwd}"
fi

LOG="$(mktemp -t swiftos-ipv6-tcp.XXXXXX)"
NCOUT="$(mktemp -t swiftos-ipv6-tcp-nc.XXXXXX)"
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
trap 'stop_qemu; exec 3>&- 2>/dev/null; rm -f "$LOG" "$NCOUT" "$PIDFILE" "$INFIFO"' EXIT

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

# Dump enough log for CI: QEMU startup refusals live at the top; guest traffic
# near "tcpecho:". Keep both bounded so a full serial dump is not required.
dump_fail_log() {
  echo "--- qemu/serial (first 40 lines) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | head -40 >&2 || true
  echo "--- serial (tcpecho region) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/tcpecho:/,$p' | head -20 >&2 || true
  if [[ ! -s "$LOG" ]]; then
    echo "(log empty — QEMU likely exited before producing serial output)" >&2
  fi
  echo "--- nc output ---" >&2
  cat "$NCOUT" 2>/dev/null >&2 || true
}

# Boot with ipv6=on plus IPv4 hostfwd for the echo path and IPv6 hostfwd
# literals when the probe above accepted them. True nc -6 AF_INET6 echo
# tightening still belongs here on hosts that can bind the rules.
qemu_args+=(
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev "user,id=n0,ipv6=on,hostfwd=tcp:127.0.0.1:5555-:5555,hostfwd=tcp:[::1]:5555-:5555,hostfwd=tcp:[::1]:5556-:5556"
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL"
)
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# If QEMU dies immediately after the probe claimed success (race/port steal),
# fail loudly with the log head rather than five empty-serial assertions.
for _ in $(seq 1 30); do
  if ! kill -0 "$QP" 2>/dev/null; then
    wait "$QP" 2>/dev/null || true
    QP=""
    echo "FAIL: QEMU exited before guest boot (see log head for hostfwd/startup errors)" >&2
    dump_fail_log
    exit 1
  fi
  if [[ -s "$LOG" ]] && ! grep -qiE 'Invalid host forwarding|Could not set up host forwarding' "$LOG" 2>/dev/null; then
    break
  fi
  if grep -qiE 'Invalid host forwarding|Could not set up host forwarding' "$LOG" 2>/dev/null; then
    stop_qemu
    QP=""
    echo "FAIL: QEMU refused hostfwd after capability probe (unexpected; see log)" >&2
    dump_fail_log
    exit 1
  fi
  sleep 0.1
done

# Wait for each stage's prompt before sending (reactive, not fixed sleeps).
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" && printf 'tty-line\n'     >&3
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

# Patient connect + send + echo over IPv4 hostfwd while the NIC runs with ipv6=on.
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

exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "net-a: virtio-net up, MAC" <<<"$clean" \
  || { echo "FAIL: virtio-net probe did not run (dual-stack not exercised)" >&2; ok=0; }
grep -qF "net: IPv6 link-local configured" <<<"$clean" \
  || { echo "FAIL: kernel did not log IPv6 link-local (EUI-64 + NDP/RA)" >&2; ok=0; }
[[ "$listening" -eq 1 ]] || { echo "FAIL: /bin/tcpecho never reported listening" >&2; ok=0; }
grep -Eq "tcpecho: got [0-9]+ bytes" <<<"$clean" \
  || { echo "FAIL: guest did not receive the connection data under ipv6=on" >&2; ok=0; }
grep -qF "$MSG" "$NCOUT" \
  || { echo "FAIL: host did not receive the echoed data back" >&2; ok=0; }

if grep -qiE 'panic|data abort|undefined instruction|kernel panic' "$LOG"; then
  echo "FAIL: crash seen while IPv6 was active during TCP echo test" >&2
  ok=0
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/tcpecho TCP round-trip under ipv6=on netdev (NDP + dual-stack smoke)"
  exit 0
fi
dump_fail_log
exit 1
