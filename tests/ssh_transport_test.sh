#!/usr/bin/env bash
# ssh_transport_test.sh — SSH client transport acceptance.
#
# Boots a guest with virtio-net, first starts a temporary host OpenSSH server
# with an untrusted Ed25519 host key, then restarts it with a trusted fixture
# host key and runs guest /bin/ssh to 10.0.2.2:<port>. The client must reject
# the untrusted key, then complete identification, curve25519-sha256 KEX,
# ssh-ed25519 host-key signature verification, known_hosts trust pinning,
# strict-KEX sequence reset, chacha20-poly1305 key setup, and one encrypted
# ssh-userauth service request.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
PORT="${SSH_CLIENT_HOST_PORT:-$((26000 + ($$ % 20000)))}"
HOST_KEY_SRC="$ROOT/fixtures/ssh/ssh_client_host_ed25519"
HOST_KEY_DENY_SRC="$ROOT/fixtures/ssh/sshd_hc4_ed25519"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi
SSHD="${SSHD:-$(command -v sshd 2>/dev/null || true)}"
[[ -n "$SSHD" ]] || { echo "FAIL: sshd not found (needed for the host OpenSSH server)" >&2; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "FAIL: nc not found (needed to wait for host sshd)" >&2; exit 2; }
[[ -f "$HOST_KEY_SRC" ]] || { echo "FAIL: fixture host key missing: $HOST_KEY_SRC" >&2; exit 2; }
[[ -f "$HOST_KEY_DENY_SRC" ]] || { echo "FAIL: fixture host key missing: $HOST_KEY_DENY_SRC" >&2; exit 2; }

LOG="$(mktemp -t swiftos-ssh-client.XXXXXX)"
SSHD_LOG="$(mktemp -t swiftos-ssh-client-sshd.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-ssh-client-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-ssh-client-in.XXXXXX)"
HOSTDIR="$(mktemp -d -t swiftos-ssh-client-host.XXXXXX)"
mkfifo "$INFIFO"
QP=""
SSHD_PID=""

stop_all() {
  stop_host_sshd
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_all; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$SSHD_LOG" "$PIDFILE" "$INFIFO"; rm -rf "$HOSTDIR"' EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (ssh client driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -140 >&2 || true
  echo "--- host sshd log ---" >&2
  cat "$SSHD_LOG" >&2 2>/dev/null || true
  exit 1
}

send_line() {
  local line="$1" delay="${SSH_CLIENT_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${SSH_CLIENT_SEND_DELAY:-0.08}"
}

wait_host_port() {
  local n=0
  while (( n < 80 )); do
    nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1 && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

stop_host_sshd() {
  [[ -n "$SSHD_PID" ]] && { kill "$SSHD_PID" 2>/dev/null || true; sleep 0.2; kill -9 "$SSHD_PID" 2>/dev/null || true; }
  SSHD_PID=""
}

start_host_sshd() {
  local key_src="$1"
  stop_host_sshd
  cp "$key_src" "$HOSTDIR/host_ed25519"
  chmod 600 "$HOSTDIR/host_ed25519"
  cat >"$HOSTDIR/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $HOSTDIR/host_ed25519
PidFile $HOSTDIR/sshd.pid
PasswordAuthentication no
PubkeyAuthentication yes
KexAlgorithms curve25519-sha256
HostKeyAlgorithms ssh-ed25519
Ciphers chacha20-poly1305@openssh.com
MACs hmac-sha2-256
LogLevel DEBUG3
StrictModes no
UsePAM no
EOF
  chmod 600 "$HOSTDIR/sshd_config"
  "$SSHD" -t -f "$HOSTDIR/sshd_config" \
    || { echo "FAIL: temporary sshd_config did not validate" >&2; exit 2; }
  "$SSHD" -D -e -f "$HOSTDIR/sshd_config" >>"$SSHD_LOG" 2>&1 &
  SSHD_PID=$!
  disown "$SSHD_PID" 2>/dev/null || true
  wait_host_port || drive_fail "host sshd did not listen on 127.0.0.1:$PORT"
}

start_host_sshd "$HOST_KEY_DENY_SRC"

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
qemu_args+=(
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev user,id=n0
  -device virtio-net-device,netdev=n0
)
if [[ -n "${SSH_CLIENT_EXTRA_QEMU_ARGS:-}" ]]; then
  # Space-split only: callers pass QEMU options without embedded whitespace.
  # shellcheck disable=SC2206
  qemu_args+=(${SSH_CLIENT_EXTRA_QEMU_ARGS})
fi
qemu_args+=(-kernel "$KERNEL")

"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
send_line 'root'
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line "/bin/ssh 10.0.2.2 $PORT"
await "ssh: known_hosts host key mismatch" 120 || drive_fail "guest ssh did not reject an untrusted host key"
stop_host_sshd
start_host_sshd "$HOST_KEY_SRC"
send_line "/bin/ssh 10.0.2.2 $PORT"
await "ssh: transport ready (preauth)" 120 || true
exec 3>&-
stop_all
QP=""; SSHD_PID=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "ssh: connected to port $PORT" <<<"$clean" \
  || { echo "FAIL: guest ssh did not connect to the requested port" >&2; ok=0; }
grep -qF "ssh: server SSH-2.0-OpenSSH" <<<"$clean" \
  || { echo "FAIL: guest ssh did not receive an OpenSSH server banner" >&2; ok=0; }
grep -qF "ssh: host key signature verified" <<<"$clean" \
  || { echo "FAIL: guest ssh did not verify the Ed25519 host-key signature" >&2; ok=0; }
grep -qF "ssh: known_hosts host key mismatch" <<<"$clean" \
  || { echo "FAIL: guest ssh did not reject the untrusted host key" >&2; ok=0; }
grep -qF "ssh: host key matched /etc/ssh/known_hosts" <<<"$clean" \
  || { echo "FAIL: guest ssh did not match the host key in known_hosts" >&2; ok=0; }
if [[ -n "${SSH_CLIENT_EXPECT_RUNTIME_ENTROPY:-}" ]]; then
  grep -qF "virtio-rng: runtime entropy ready" <<<"$clean" \
    || { echo "FAIL: guest did not bring up virtio-rng" >&2; ok=0; }
  grep -qF "ssh: loaded runtime entropy from SYS_RANDOM" <<<"$clean" \
    || { echo "FAIL: guest ssh did not load runtime entropy" >&2; ok=0; }
  grep -qF "ssh: kex random context seeded runtime" <<<"$clean" \
    || { echo "FAIL: guest ssh did not mark KEX as runtime-seeded" >&2; ok=0; }
fi
grep -qF "ssh: strict KEX sequence reset" <<<"$clean" \
  || { echo "FAIL: guest ssh did not detect strict KEX" >&2; ok=0; }
grep -qF "ssh: negotiated curve25519-sha256 ssh-ed25519 chacha20-poly1305@openssh.com" <<<"$clean" \
  || { echo "FAIL: guest ssh did not report the expected modern algorithms" >&2; ok=0; }
grep -qF "ssh: encrypted service accepted" <<<"$clean" \
  || { echo "FAIL: guest ssh did not complete encrypted service request/accept" >&2; ok=0; }
grep -qF "ssh: transport ready (preauth)" <<<"$clean" \
  || { echo "FAIL: guest ssh did not complete the transport preflight" >&2; ok=0; }
grep -qF "Server listening on 127.0.0.1 port $PORT" "$SSHD_LOG" \
  || { echo "FAIL: host sshd log did not show the expected listener" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: /bin/ssh rejected an untrusted host key, then completed outbound OpenSSH transport/KEX preauth"
  exit 0
fi
echo "--- serial (ssh client region) ---" >&2
grep -iE 'ssh:|login:|panic|abort|M7' <<<"$clean" | tail -60 >&2 || true
echo "--- host sshd log ---" >&2
cat "$SSHD_LOG" >&2
exit 1
