#!/usr/bin/env bash
# site_bundle_test.sh — SU-B acceptance: signed-bundle apply over /data.
#
# `/bin/swupdate apply-local <bundle.swsite>` verifies a bundle's Ed25519
# signature (against the baked /etc/swupdate/site-root.pub) and payload SHA-256,
# unpacks it into /data/www/next, and atomically swaps it into /data/www/current.
# This test (image built with INCLUDE_SITE_TEST=1, which bakes a signed test
# bundle + a tampered copy under /usr/share/swupdate-test) proves:
#   1. a TAMPERED bundle is rejected and /data/www/current is left unchanged;
#   2. a VALID signed bundle is applied and nginx serves the new content;
#   3. the applied content survives a reboot (it lives on /data).
#
# nginx is started only after the apply commands so the single-core console is
# not starved while we drive swupdate.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
BAKED="$ROOT/build/nginx-root/usr/share/nginx/html/index.html"
QEMU="${QEMU:-qemu-system-aarch64}"
CONF="/usr/etc/nginx/nginx-prod.conf"
GOOD="/usr/share/swupdate-test/site.swsite"
BAD="/usr/share/swupdate-test/site-bad.swsite"
NEWMARK="SWSITE-BUNDLE-APPLIED-9z4k"
BAKED_MARK="nginx package"      # substring of the baked default index.html
HOST_PORT="${HOST_PORT:-$(( (RANDOM % 20000) + 20000 ))}"

[[ -f "$KERNEL" ]]   || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image INCLUDE_SITE_TEST=1)" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-sitebundle.XXXXXX)"
DATA_IMG="$WORK/data.img"
PIDFILE="$(mktemp -t swiftos-sitebundle-pid.XXXXXX)"
QP=""; CURLOG=""

dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=32 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  QP=""
  exec 3>&- 2>/dev/null || true
}
cleanup() { stop_qemu; rm -rf "$WORK" "$PIDFILE"; }
trap cleanup EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$CURLOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
send() { printf '%s\n' "$1" >&3; sleep 0.4; }

fail() {
  echo "FAIL: $1" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$CURLOG" 2>/dev/null | tail -40 >&2 || true
  exit 1
}

start_boot() {  # start_boot LOGFILE INFIFO
  local log="$1" fifo="$2"
  rm -f "$fifo"; mkfifo "$fifo"
  CURLOG="$log"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" \
    -global virtio-mmio.force-legacy=false \
    ${dtb_args[@]+"${dtb_args[@]}"} \
    -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" \
    -device virtio-blk-device,drive=swosbase \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" \
    -device virtio-blk-device,drive=swosdata \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:80" \
    -device virtio-net-device,netdev=n0 \
    -kernel "$KERNEL" <"$fifo" >"$log" 2>&1 &
  QP=$!
  exec 3<>"$fifo"
}

login() {
  await "M7 tty: type a line then Enter" 60 || fail "no tty line prompt"
  send 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
  printf '\003' >&3; sleep 0.15
  await "swift-os login:" 90 || fail "no login prompt"
  send 'root'
  await "Password:" 90 || fail "no password prompt"
  send 'swordfish'
  await "Welcome to swift-os, root" 120 || fail "root login did not complete"
}

start_nginx() {
  send "/sbin/nginx -c $CONF &"
  sleep 4
  grep -qiE "\[emerg\]|\[alert\]" "$CURLOG" && fail "nginx fatal error"
}

curl_body() {  # curl_body OUTFILE — tolerant of a slow boot/nginx start under host load
  local body="$1" i
  for i in $(seq 1 150); do
    if curl -s -m 5 "http://127.0.0.1:${HOST_PORT}/" -o "$body" 2>/dev/null; then
      [[ -s "$body" ]] && return 0
    fi
    sleep 0.5
  done
  return 1
}

# ---- Boot 1: reject tampered bundle, apply the valid one -------------------
start_boot "$WORK/boot1.log" "$WORK/in1"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 1)"
login
await "swupdate: seed: seeded /data/www/current from baked default" 5 \
  || fail "boot 1 did not seed the baked default"

# Assertions are over the NETWORK (curl), not the busybox console — QEMU's serial
# stdout is heavily buffered, so late command output is unreliable, but nginx
# serving /data/www/current per request reflects the on-disk swap immediately.

# poll_for OUTFILE NEEDLE [MAXSEC] — curl until the body contains NEEDLE.
poll_for() {
  local body="$1" needle="$2" max="${3:-90}" i
  for i in $(seq 1 "$max"); do
    if curl -s -m 5 "http://127.0.0.1:${HOST_PORT}/" -o "$body" 2>/dev/null \
       && grep -qF "$needle" "$body"; then return 0; fi
    sleep 1
  done
  return 1
}

start_nginx
# Baseline: current is the baked default site.
curl_body "$WORK/baked" || fail "nginx did not serve the seeded baseline"
grep -qF "$BAKED_MARK" "$WORK/baked" || fail "baseline docroot is not the baked default"

# Run the apply commands in the BACKGROUND (&): the busybox console returns to its
# prompt immediately, so the next command we send isn't swallowed by a still-running
# foreground process's stdin. We observe the result over the network (curl).

# 1. Tampered bundle must be refused; the docroot must stay byte-identical to the
#    baked default (a wrongly-applied corrupt bundle would change/break it).
send "/bin/swupdate apply-local $BAD &"
sleep 15                       # the signature check fails fast; let it run
curl_body "$WORK/afterbad" || fail "nginx did not serve after the tampered apply"
cmp -s "$WORK/afterbad" "$WORK/baked" \
  || fail "tampered bundle altered the docroot (should have been rejected)"
echo "ok: tampered bundle rejected, current unchanged"

# 2. Valid signed bundle applies and nginx serves the new content (poll waits out
#    the background apply + the atomic swap).
send "/bin/swupdate apply-local $GOOD &"
poll_for "$WORK/body1" "$NEWMARK" 90 || fail "valid bundle content not served after apply"
echo "ok: valid bundle applied and served"
stop_qemu

# ---- Boot 2: applied content persists across reboot ------------------------
start_boot "$WORK/boot2.log" "$WORK/in2"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 2)"
login
await "swupdate: seed: /data/www/current present" 30 \
  || fail "boot 2 did not find the persisted docroot"
start_nginx
curl_body "$WORK/body2" || fail "nginx did not serve on boot 2"
grep -qF "$NEWMARK" "$WORK/body2" || fail "applied bundle content did NOT survive reboot"
echo "ok: applied bundle content survived reboot"

echo "PASS: signed site-bundle apply + reject + persistence (SU-B)"
exit 0
