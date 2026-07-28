#!/usr/bin/env bash
# sshd_supervision_test.sh - swos-init SSHD restart supervision proof.
#
# Builds a temporary base image whose service manifest uses the opt-in
# `sshd-once` token. The first SSH session makes /bin/sshd exit after serving
# one connection; swos-init must notice the child exit, restart it, and allow a
# second host OpenSSH command to complete.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
QEMU="${QEMU:-qemu-system-aarch64}"
SSH="${SSH:-ssh}"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
HOST_PORT="${SSHD_HOST_PORT:-$((30000 + ($$ % 14000)))}"
KEY_SRC="$ROOT/fixtures/ssh/sshd_hc5_ed25519"
HOST_SEED_SRC="$ROOT/base/etc/ssh/ssh_host_ed25519_seed"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$KEY_SRC" ]] || { echo "FAIL: $KEY_SRC missing" >&2; exit 2; }
[[ -f "$HOST_SEED_SRC" ]] || { echo "FAIL: $HOST_SEED_SRC missing" >&2; exit 2; }
command -v "$SSH" >/dev/null 2>&1 || { echo "FAIL: ssh client not found" >&2; exit 2; }
if [[ ! -x "$SSHKEY" ]]; then
  ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 || { echo "FAIL: cannot build sshkey tool" >&2; exit 2; }
fi
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-sshd-supervision.XXXXXX)"
LOG="$WORK/serial.log"
IDOUT="$WORK/id.out"
IDERR="$WORK/id.err"
ECHOOUT="$WORK/echo.out"
ECHOERR="$WORK/echo.err"
KEY="$WORK/allow-key"
KNOWN_HOSTS="$WORK/known-hosts"
SERVICES="$WORK/services"
IMG="$WORK/base-sshd-supervised.img"
BASE_ROOT="$WORK/base-root"
PIDFILE="$WORK/qemu.pid"
INFIFO="$WORK/qemu.in"
mkfifo "$INFIFO"
cp "$KEY_SRC" "$KEY"
chmod 600 "$KEY"
printf 'sshd-once\n' >"$SERVICES"
"$SSHKEY" known-host --host "[127.0.0.1]:$HOST_PORT" \
  --seed-file "$HOST_SEED_SRC" >"$KNOWN_HOSTS" \
  || { echo "FAIL: could not derive SwiftOS SSHD known_hosts entry" >&2; exit 2; }

if ! ( cd "$ROOT" && make BASE_IMG="$IMG" BASE_ROOT="$BASE_ROOT" SWOS_SERVICES_FILE="$SERVICES" base-image ) >"$WORK/base-image.log" 2>&1; then
  echo "FAIL: could not build supervised SSHD base image" >&2
  cat "$WORK/base-image.log" >&2
  exit 2
fi

QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -rf "$WORK"' EXIT

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
qemu_args+=(
  -drive "file=$IMG,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:22"
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL"
)

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

await_count() {
  local marker="$1" want="$2" max="${3:-30}" n=0
  while (( n < max * 10 )); do
    local got
    got="$(grep -cF "$marker" "$LOG" 2>/dev/null || true)"
    [[ "$got" -ge "$want" ]] && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (sshd supervision) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -160 >&2 || true
  echo "--- id stdout ---" >&2
  cat "$IDOUT" >&2 2>/dev/null || true
  echo "--- id stderr ---" >&2
  cat "$IDERR" >&2 2>/dev/null || true
  echo "--- echo stdout ---" >&2
  cat "$ECHOOUT" >&2 2>/dev/null || true
  echo "--- echo stderr ---" >&2
  cat "$ECHOERR" >&2 2>/dev/null || true
  exit 1
}

ssh_common=(
  -F /dev/null -vvv -p "$HOST_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o GlobalKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes
  -o PreferredAuthentications=publickey
  -o PasswordAuthentication=no
  -o PubkeyAuthentication=yes
  -o NumberOfPasswordPrompts=0
  -o KexAlgorithms=curve25519-sha256
  -o HostKeyAlgorithms=ssh-ed25519
  -o Ciphers=chacha20-poly1305@openssh.com
  -o MACs=hmac-sha2-256
)

send_line() {
  local line="$1" delay="${SSHD_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do
    printf '%s' "${line:i:1}" >&3
    sleep "$delay"
  done
  printf '\n' >&3
  sleep "${SSHD_SEND_DELAY:-0.08}"
}

"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swos-init: starting configured services" 90 || drive_fail "swos-init did not start"
await "swos-init: supervision active" 90 || drive_fail "swos-init did not enter supervision mode"
await "swos-init: started sshd-once pid" 90 || drive_fail "supervisor did not start sshd-once"
await "sshd: listening on 22 (session exec preflight)" 120 || drive_fail "supervised sshd did not listen"
await "sshd: once mode enabled" 30 || drive_fail "supervised sshd did not enter once mode"

"$SSH" "${ssh_common[@]}" -i "$KEY" \
  root@127.0.0.1 /bin/id >"$IDOUT" 2>"$IDERR" </dev/null
id_rc=$?

await "sshd: once mode complete; exiting" 30 || drive_fail "sshd --once did not exit after first session"
await "swos-init: service sshd-once pid" 30 || drive_fail "supervisor did not observe sshd-once exit"
await_count "swos-init: started sshd-once pid" 2 40 || drive_fail "supervisor did not restart sshd-once"
await_count "sshd: listening on 22 (session exec preflight)" 2 40 || drive_fail "restarted sshd did not listen"
await_count "sshd: once mode enabled" 2 40 || drive_fail "restarted sshd did not enter once mode"

"$SSH" "${ssh_common[@]}" -i "$KEY" \
  root@127.0.0.1 /bin/echo HC14-RESTART >"$ECHOOUT" 2>"$ECHOERR" </dev/null
echo_rc=$?

await_count "sshd: once mode complete; exiting" 2 30 || true
exec 3>&-
stop_qemu
QP=""

clean="$(sed 's/\r//' "$LOG")"
ok=1
grep -qF "swos-init: supervision active" <<<"$clean" \
  || { echo "FAIL: swos-init supervision marker missing" >&2; ok=0; }
grep -qF "swos-init: service sshd-once pid" <<<"$clean" \
  || { echo "FAIL: swos-init did not log sshd-once exit" >&2; ok=0; }
[[ "$(grep -cF "swos-init: started sshd-once pid" <<<"$clean")" -ge 2 ]] \
  || { echo "FAIL: swos-init did not start sshd-once twice" >&2; ok=0; }
[[ "$(grep -cF "sshd: listening on 22 (session exec preflight)" <<<"$clean")" -ge 2 ]] \
  || { echo "FAIL: serial log does not show two sshd listen cycles" >&2; ok=0; }
[[ "$(grep -cF "sshd: once mode enabled" <<<"$clean")" -ge 2 ]] \
  || { echo "FAIL: serial log does not show two sshd once-mode cycles" >&2; ok=0; }
grep -qF "principal=1(root)" "$IDOUT" \
  || { echo "FAIL: first supervised ssh /bin/id did not run as root" >&2; ok=0; }
[[ "$id_rc" -eq 0 ]] \
  || { echo "FAIL: first supervised ssh exited with $id_rc, expected 0" >&2; ok=0; }
grep -qFx "HC14-RESTART" "$ECHOOUT" \
  || { echo "FAIL: restarted sshd did not run /bin/echo" >&2; ok=0; }
[[ "$echo_rc" -eq 0 ]] \
  || { echo "FAIL: second supervised ssh exited with $echo_rc, expected 0" >&2; ok=0; }
grep -qF "Host '[127.0.0.1]:$HOST_PORT' is known and matches the ED25519 host key." "$IDERR" "$ECHOERR" \
  || { echo "FAIL: host OpenSSH did not pin the supervised SwiftOS host key" >&2; ok=0; }
grep -qF "Authenticated to 127.0.0.1" "$IDERR" \
  || { echo "FAIL: first supervised ssh did not authenticate" >&2; ok=0; }
grep -qF "Authenticated to 127.0.0.1" "$ECHOERR" \
  || { echo "FAIL: restarted supervised ssh did not authenticate" >&2; ok=0; }

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: swos-init restarted sshd-once and OpenSSH completed commands before and after restart"
  exit 0
fi

echo "--- serial (sshd supervision region) ---" >&2
grep -iE 'swos-init:|sshd:|panic|abort|M7' <<<"$clean" | tail -80 >&2 || true
exit 1
