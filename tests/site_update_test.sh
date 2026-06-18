#!/usr/bin/env bash
# site_update_test.sh — SU-C acceptance: reflash-free site update over SSH.
#
# The full operator path on a RUNNING box (no Rescue / no dd):
#   operator --(SSH, pinned key)--> /bin/swupdate site https://host/bundle.swsite
#   swupdate --(TLS 1.3)--> fetch bundle, verify Ed25519 sig vs baked pubkey,
#            atomically swap /data/www/current, nginx serves it immediately.
#
# Proves:
#   1. a TAMPERED bundle fetched over HTTPS is rejected (ssh exits nonzero) and the
#      docroot stays the baked default;
#   2. a VALID signed bundle is applied via the SSH trigger and nginx serves the
#      new content within seconds;
#   3. the new content survives a reboot.
#
# The SSH trigger is gated by the operator key (bounded-exec allowlist); the
# content by the bundle signature. nginx is started on the serial console (a
# foreground daemon can't be driven through a one-shot exec session). SKIPs if
# ssh/openssl/python3 are unavailable.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
GOOD_BUNDLE="$ROOT/build/site-test.swsite"
BAD_BUNDLE="$ROOT/build/site-test-bad.swsite"
QEMU="${QEMU:-qemu-system-aarch64}"
SSH="${SSH:-ssh}"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
OPENSSL="${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}"
PYTHON="${PYTHON:-python3}"
CONF="/usr/etc/nginx/nginx-prod.conf"
NEWMARK="SWSITE-BUNDLE-APPLIED-9z4k"
BAKED_MARK="nginx package"
KEY_ALLOW_SRC="${SSHD_ALLOW_KEY_SRC:-$ROOT/fixtures/ssh/sshd_hc5_ed25519}"
HOST_SEED_SRC="${SSHD_HOST_SEED_SRC:-$ROOT/base/etc/ssh/ssh_host_ed25519_seed}"
SSH_PORT="${SSH_PORT:-$(( 26000 + ($$ % 16000) ))}"
HTTP_PORT="${HTTP_PORT:-$(( (RANDOM % 16000) + 20000 ))}"
TLS_PORT="${TLS_PORT:-$(( (RANDOM % 2000) + 44000 ))}"

[[ -f "$KERNEL" ]]      || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]]    || { echo "FAIL: $BASE_IMG missing (make base-image INCLUDE_SITE_TEST=1)" >&2; exit 2; }
[[ -f "$GOOD_BUNDLE" ]] || { echo "FAIL: $GOOD_BUNDLE missing" >&2; exit 2; }
[[ -f "$BAD_BUNDLE" ]]  || { echo "FAIL: $BAD_BUNDLE missing" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }
command -v "$SSH" >/dev/null 2>&1 || { echo "SKIP: ssh client not found" >&2; exit 0; }
command -v "$PYTHON" >/dev/null 2>&1 || { echo "SKIP: python3 not found" >&2; exit 0; }
[[ -x "$OPENSSL" ]] || OPENSSL="$(command -v openssl 2>/dev/null || true)"
[[ -n "$OPENSSL" ]] || { echo "SKIP: openssl not found" >&2; exit 0; }
[[ -x "$SSHKEY" ]] || ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 || { echo "FAIL: cannot build sshkey" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-siteupd.XXXXXX)"
DATA_IMG="$WORK/data.img"
PIDFILE="$WORK/pid"
KEY_ALLOW="$WORK/key"; KNOWN_HOSTS="$WORK/known_hosts"; SRV="$WORK/srv"
mkdir -p "$SRV"
cp "$GOOD_BUNDLE" "$SRV/site.swsite"
cp "$BAD_BUNDLE"  "$SRV/bad.swsite"
cp "$KEY_ALLOW_SRC" "$KEY_ALLOW"; chmod 600 "$KEY_ALLOW"
QP=""; SRVPID=""; CURLOG=""

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=swiftos \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1 \
  || { echo "SKIP: openssl could not make a cert" >&2; exit 0; }
"$SSHKEY" known-host --host "[127.0.0.1]:$SSH_PORT" --seed-file "$HOST_SEED_SRC" >"$KNOWN_HOSTS" \
  || { echo "FAIL: could not derive known_hosts" >&2; exit 2; }

dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=32 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  QP=""; exec 3>&- 2>/dev/null || true
}
cleanup() { stop_qemu; [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# Host HTTPS server the guest fetches bundles from (10.0.2.2 via slirp).
"$PYTHON" "$ROOT/tests/site_update_server.py" "$TLS_PORT" "$WORK/cert.pem" "$WORK/key.pem" "$SRV" >/dev/null 2>&1 &
SRVPID=$!

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() { local m="$1" max="${2:-60}" n=0; while (( n < max*10 )); do grep -qF "$m" "$CURLOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
send() { printf '%s\n' "$1" >&3; sleep 0.4; }
fail() { echo "FAIL: $1" >&2; echo "--- serial tail ---" >&2; sed 's/\r//' "$CURLOG" 2>/dev/null | tail -50 >&2; exit 1; }

ssh_common=( -F /dev/null -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=8
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o GlobalKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no
  -o KexAlgorithms=curve25519-sha256 -o HostKeyAlgorithms=ssh-ed25519
  -o Ciphers=chacha20-poly1305@openssh.com -o MACs=hmac-sha2-256 )

ssh_swupdate() {  # ssh_swupdate URLPATH -> sets $ssh_rc
  "$SSH" "${ssh_common[@]}" -i "$KEY_ALLOW" root@127.0.0.1 \
    "/bin/swupdate site https://10.0.2.2:$TLS_PORT/$1" >"$WORK/sshout" 2>"$WORK/ssherr"
  ssh_rc=$?
}

start_boot() {  # start_boot LOGFILE INFIFO
  local log="$1" fifo="$2"; rm -f "$fifo"; mkfifo "$fifo"; CURLOG="$log"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false ${dtb_args[@]+"${dtb_args[@]}"} \
    -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" -device virtio-blk-device,drive=swosbase \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" -device virtio-blk-device,drive=swosdata \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${HTTP_PORT}-:80" \
    -device virtio-net-device,netdev=n0 \
    -kernel "$KERNEL" <"$fifo" >"$log" 2>&1 &
  QP=$!; exec 3<>"$fifo"
}

login() {
  await "M7 tty: type a line then Enter" 60 || fail "no tty prompt"
  send 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
  printf '\003' >&3; sleep 0.15
  await "sshd: listening on 22 (session exec preflight)" 120 || fail "sshd did not listen"
  await "swift-os login:" 90 || fail "no login prompt"
  send 'root'; await "Password:" 90 || fail "no password prompt"
  send 'swordfish'; await "Welcome to swift-os, root" 120 || fail "login failed"
}

start_nginx() { send "/sbin/nginx -c $CONF &"; sleep 4; grep -qiE "\[emerg\]|\[alert\]" "$CURLOG" && fail "nginx fatal error"; }

poll_for() {  # poll_for OUTFILE NEEDLE [MAXSEC]
  local body="$1" needle="$2" max="${3:-90}" i
  for i in $(seq 1 "$max"); do
    if curl -s -m 5 "http://127.0.0.1:${HTTP_PORT}/" -o "$body" 2>/dev/null && grep -qF "$needle" "$body"; then return 0; fi
    sleep 1
  done
  return 1
}

# ---- Boot 1: SSH-triggered update over HTTPS -------------------------------
start_boot "$WORK/boot1.log" "$WORK/in1"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 1)"
login
start_nginx
poll_for "$WORK/baked" "$BAKED_MARK" 60 || fail "baseline (baked default) not served"

# 1. Tampered bundle over SSH must be refused; docroot stays the baked default.
ssh_swupdate "bad.swsite"
[[ "$ssh_rc" -ne 0 ]] || fail "ssh swupdate site (tampered) unexpectedly succeeded"
curl -s -m 5 "http://127.0.0.1:${HTTP_PORT}/" -o "$WORK/afterbad" 2>/dev/null
grep -qF "$BAKED_MARK" "$WORK/afterbad" || fail "tampered bundle altered the docroot"
echo "ok: tampered bundle over SSH rejected, docroot unchanged"

# 2. Valid bundle over SSH applies and nginx serves the new content.
ssh_swupdate "site.swsite"
[[ "$ssh_rc" -eq 0 ]] || fail "ssh swupdate site (valid) failed rc=$ssh_rc: $(cat "$WORK/ssherr")"
poll_for "$WORK/body1" "$NEWMARK" 60 || fail "new content not served after SSH update"
echo "ok: valid bundle applied via SSH trigger and served"
stop_qemu

# ---- Boot 2: applied content persists across reboot ------------------------
start_boot "$WORK/boot2.log" "$WORK/in2"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 2)"
login
start_nginx
poll_for "$WORK/body2" "$NEWMARK" 60 || fail "updated content did NOT survive reboot"
echo "ok: SSH-applied content survived reboot"

echo "PASS: reflash-free site update over SSH (fetch+verify+swap) + persistence (SU-C)"
exit 0
