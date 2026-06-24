#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# os_update_test.sh — OS-4 acceptance: reflash-free OS update over HTTPS.
#
# The operator path on a RUNNING store-booted box (no Rescue / no dd):
#   /bin/swupdate os https://host/os.swsys
#   swupdate --(TLS 1.3)--> fetch the signed SWSYS bundle, verify its Ed25519
#            signature + payload SHA against the baked OS key, then stream the
#            base image into the INACTIVE A/B slot (kernel staging syscalls) and
#            activate it. The kernel enforces the monotonic anti-rollback floor.
#
# One store-booted session with guest networking (slirp -> host TLS server):
#   1. a TAMPERED bundle is rejected on signature; no slot is staged;
#   2. an OLDER bundle (version <= the store's floor of 5) is refused by the
#      kernel anti-rollback at stage-begin;
#   3. a VALID newer bundle (version 7) is staged into slot B and activated.
#
# The bundle's base half is the tiny signed SWOSBASE fixture (build/test-base.img):
# this test exercises fetch+verify+stage+activate; that a staged REAL base image
# verifies and boots after reboot is covered by ab_stage_test. cache=writethrough
# makes the slot write + manifest write-back durable.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE="$ROOT/build/base.img"
USTORE="$ROOT/build/updatestore"
SYSPACK="$ROOT/build/syspack"
FIXTURE="$ROOT/build/test-base.img"
KSLOT="$ROOT/build/kernel-slot.bin"   # OS-1c-3: SWSYS v2 carries the real padded kernel slot
SEED="$ROOT/models/dev-image-signing.seed"
QEMU="${QEMU:-qemu-system-aarch64}"
OPENSSL="${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}"
PYTHON="${PYTHON:-python3}"
TLS_PORT="${TLS_PORT:-$(( (RANDOM % 2000) + 44000 ))}"

[[ -f "$KERNEL" ]]  || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE" ]]    || { echo "FAIL: $BASE missing (make base-image)" >&2; exit 2; }
[[ -x "$USTORE" ]]  || { echo "FAIL: $USTORE missing (make updatestore)" >&2; exit 2; }
[[ -x "$SYSPACK" ]] || { echo "FAIL: $SYSPACK missing (make syspack)" >&2; exit 2; }
[[ -f "$FIXTURE" ]] || { echo "FAIL: $FIXTURE missing (make build/test-base.img)" >&2; exit 2; }
[[ -f "$KSLOT" ]]   || { echo "FAIL: $KSLOT missing (make build/kernel-slot.bin)" >&2; exit 2; }
[[ -f "$SEED" ]]    || { echo "FAIL: $SEED missing" >&2; exit 2; }
command -v "$PYTHON" >/dev/null 2>&1 || { echo "SKIP: python3 not found" >&2; exit 0; }
[[ -x "$OPENSSL" ]] || OPENSSL="$(command -v openssl 2>/dev/null || true)"
[[ -n "$OPENSSL" ]] || { echo "SKIP: openssl not found" >&2; exit 0; }
if [[ ! -f "$DTB" ]]; then
  ( cd "$ROOT" && make build/virt.dtb ) >/dev/null 2>&1 || { echo "FAIL: cannot build virt.dtb" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-osupd.XXXXXX)"
STORE="$WORK/store.img"; LOG="$WORK/serial.log"; PIDFILE="$WORK/pid"
INFIFO="$WORK/in"; mkfifo "$INFIFO"; SRV="$WORK/srv"; mkdir -p "$SRV"
QP=""; SRVPID=""
cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Build the three SWSYS v2 bundles (the real padded kernel slot + its v4 manifest
# ride along; this test applies only the base half). good=version 7 (> floor 5);
# old=version 3 (<= floor); bad=good
# with a flipped body byte so the Ed25519 signature fails.
"$SYSPACK" create "$KSLOT" "$FIXTURE" "$SRV/good.swsys" --version 7 --seed "$SEED" >/dev/null \
  || { echo "FAIL: syspack good bundle" >&2; exit 2; }
"$SYSPACK" create "$KSLOT" "$FIXTURE" "$SRV/old.swsys" --version 3 --seed "$SEED" >/dev/null \
  || { echo "FAIL: syspack old bundle" >&2; exit 2; }
cp "$SRV/good.swsys" "$SRV/bad.swsys"
# Flip a byte well past the 64-byte signature + 72-byte header (in the payload).
python3 - "$SRV/bad.swsys" <<'EOF'
import sys
p=sys.argv[1]; b=bytearray(open(p,'rb').read()); b[200]^=0xFF; open(p,'wb').write(b)
EOF

# Update store: slots = base.img, anti-rollback floor 5.
"$USTORE" "$STORE" A "$BASE" "$BASE" --min-version 5 >/dev/null \
  || { echo "FAIL: could not build store" >&2; exit 2; }

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=swiftos \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1 \
  || { echo "SKIP: openssl could not make a cert" >&2; exit 0; }
"$PYTHON" "$ROOT/tests/site_update_server.py" "$TLS_PORT" "$WORK/cert.pem" "$WORK/key.pem" "$SRV" >/dev/null 2>&1 &
SRVPID=$!

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() { local m="$1" max="${2:-30}" n=0; while (( n < max*10 )); do grep -qF "$m" "$LOG" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
send() { sleep 0.3; local s="$1" i; for (( i=0; i<${#s}; i++ )); do printf '%s' "${s:i:1}" >&3; sleep 0.03; done; }
to_shell() {
  await "M7 tty: type a line then Enter" 60 || return 1
  send $'tty-line\n'
  await "M7 tty: running; press Ctrl-C" 40 || return 1
  send $'\003'
  await "swift-os login:" 90 || return 1
  send $'root\n'; await "Password:" 90 || return 1
  send $'swordfish\n'; await "M12c: shell ready" 120 || return 1
  return 0
}
run_until() {  # run_until "cmd" "marker" [tries] [maxsec]
  local cmd="$1" marker="$2" tries="${3:-5}" max="${4:-25}" i
  for (( i=0; i<tries; i++ )); do send "$cmd"$'\n'; await "$marker" "$max" && return 0; done
  return 1
}

: > "$LOG"
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
  -drive "file=$STORE,format=raw,if=none,id=swosstore,cache=writethrough" \
  -device virtio-blk-device,drive=swosstore \
  -netdev "user,id=n0" -device virtio-net-device,netdev=n0 \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }
URL="https://10.0.2.2:$TLS_PORT"

if to_shell; then
  await "update-store: SWOSBOOT manifest valid, active slot A" 30 || fail "did not boot slot A"
  # Guest networking warms up via DHCP; the run_until retries below tolerate the
  # short delay (the first successful HTTPS fetch confirms the link is up).

  # --insecure: the mock HTTPS server uses a self-signed cert outside the system
  # trust store; the SWSYS payload is Ed25519-signed regardless (that's what these
  # cases exercise). TLS verify-by-default is covered by tls_truststore_test.sh.

  # 1. Tampered bundle -> signature rejected, nothing staged.
  run_until "/bin/swupdate os $URL/bad.swsys --insecure" "swupdate: os bundle signature INVALID" 4 25 \
    || fail "tampered bundle was not rejected on signature"
  grep -qF "update-store: staged base image" "$LOG" && fail "tampered bundle staged a slot"

  # 2. Older bundle (version 3 <= floor 5) -> kernel anti-rollback refusal.
  run_until "/bin/swupdate os $URL/old.swsys --insecure" "anti-rollback" 4 25 \
    || fail "older bundle was not refused by anti-rollback"

  # 3. Valid newer bundle (version 7) -> staged into slot B and activated.
  run_until "/bin/swupdate os $URL/good.swsys --insecure" "OS base image staged + activated" 4 30 \
    || fail "valid bundle did not stage + activate"
  await "version 7) into slot B" 5 || fail "kernel did not record the staged version/slot"
  await "update-store: activated slot B (on trial)" 5 || fail "inactive slot was not activated"
else
  fail "could not reach a shell"
fi
exec 3>&-

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: OS-4 update over HTTPS — fetch+verify SWSYS, anti-rollback + bad-sig rejected, base staged + activated"
  exit 0
fi
echo "--- serial ---" >&2
sed 's/\r//' "$LOG" | grep -iE 'swupdate|update-store|net-dhcp|active slot' >&2 | tail -30
exit 1
