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
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${TCP_ECHO_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${TCP_ECHO_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
MSG="swos-tcp"
HOST_PORT="${TCP_ECHO_HOST_PORT:-$((21000 + ($$ % 20000)))}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
command -v nc >/dev/null 2>&1 || { echo "FAIL: nc not found (needed to connect)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-tcp.XXXXXX)"
NCOUT="$(mktemp -t swiftos-tcp-nc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-tcp-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-tcp-in.XXXXXX)"; mkfifo "$INFIFO"
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

await_regex() {  # await_regex REGEX [MAXSEC]
  local regex="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    sed 's/\r//' "$LOG" 2>/dev/null | grep -Eq -- "$regex" && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (tcpecho driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | sed -n '/M7 tty:/,$p' >&2 || true
  exit 1
}


# Boot QEMU with its console read from a FIFO that we hold open on fd 3, so the
# main script can drive the login *reactively* (below) instead of on a fixed
# timeline. Opening the FIFO read-write (3<>) never blocks and keeps it open; QEMU
# is the only process that read()s it, so every byte we write reaches the guest.
qemu_args+=(
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:5555"
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL"
)
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# Wait for each stage's prompt before sending its input, rather than using fixed
# sleeps: on a cold `make test` boot a fixed schedule can lag enough that a line
# lands in the wrong reader and the guest never reaches tcpecho ("never reported
# listening"). Skip the M7 tty demo, log in as root, then run tcpecho.
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "timed out waiting for tty line prompt"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 20 || drive_fail "timed out waiting for tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 60 || drive_fail "timed out waiting for login prompt"
send_line 'root'
await "Password:" 60 || drive_fail "timed out waiting for password prompt"
send_line 'swordfish'
await "Welcome to swift-os, root" 60 || drive_fail "root login did not complete"
await "M12c: shell ready" 60 || drive_fail "root shell did not start"
send_line '/bin/tcpecho'

# Wait for the guest to listen, then connect + send a line from the host.
listening=0
await "tcpecho: listening on 5555" 80 && listening=1

# Connect with a patient timeout + bounded retry. The virtio-net driver is polled,
# so the guest only services the wire while blocked in a syscall; tcpecho prints
# "listening" just *before* it enters accept(), and the host's hostfwd connect
# resolves instantly against slirp regardless of guest state. So a connect can land
# in that startup gap and the guest-side SYN/ARP handshake then races the listener
# reaching accept() — and on a cold, post-build `make test` host, QEMU is starved
# enough that the handshake + echo can take several seconds of wall-clock. The
# original single `nc -w3` gave up mid-handshake, with no recovery for a one-shot
# server (the flake). The `-w` here is generous so the *same* connection that sent
# the data waits out a slow handshake and receives the echo (a short timeout risks
# the guest consuming its one accept just after nc gave up — data read, echo lost).
# The retry then only has to cover an attempt that fails to connect outright; we
# stop as soon as the echo returns, or once the guest has spent its one accept.
if [[ "$listening" -eq 1 ]]; then
  for _ in $(seq 1 4); do
    : > "$NCOUT"
    printf '%s\n' "$MSG" | nc -w8 127.0.0.1 "$HOST_PORT" >"$NCOUT" 2>/dev/null || true
    grep -qF "$MSG" "$NCOUT" && break                      # echo came back → done
    grep -Eq "tcpecho: got [0-9]+ bytes" "$LOG" && break   # one-shot server spent
    sleep 1                                                # brief backoff, then retry
  done
fi

# Let the guest flush its "got N bytes" line before we tear QEMU down (bounded;
# emitted right after the echo we just received, so it normally returns at once).
await_regex "tcpecho: got [0-9]+ bytes" 20 || true
exec 3>&-          # close the guest's console stdin (QEMU survives the EOF)
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
