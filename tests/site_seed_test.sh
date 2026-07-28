#!/usr/bin/env bash
# site_seed_test.sh — M-A acceptance: reflash-free site updates, seed + recovery.
#
# swos-init runs `/bin/swupdate seed` at boot, before any service. This test
# proves three things on a running box (no Rescue / no dd):
#   1. Fresh /data: seed copies the baked default site into /data/www/current and
#      nginx (prod config, docroot /data/www/current) serves it byte-for-byte.
#   2. Atomicity/recovery: a crash *between* the two renames of an atomic swap
#      (current already moved to prev, next staged) is finished on the next boot
#      (next -> current), never leaving a half-updated docroot.
#   3. The recovered content lives on /data and survives the reboot.
#
# Boot 1 uses a FRESH data disk; boot 2 reuses the SAME disk, so persistence and
# crash-recovery are exercised across a real power cycle.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
BAKED="$ROOT/build/nginx-root/usr/share/nginx/html/index.html"
QEMU="${QEMU:-qemu-system-aarch64}"
CONF="/usr/etc/nginx/nginx-prod.conf"
NEWMARK="swiftos-SITE-UPDATE-RECOVERED-7q2v"
HOST_PORT="${HOST_PORT:-$(( (RANDOM % 20000) + 20000 ))}"

[[ -f "$KERNEL" ]]   || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }
[[ -f "$BAKED" ]]    || { echo "FAIL: $BAKED missing (baked default site)" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-siteseed.XXXXXX)"
DATA_IMG="$WORK/data.img"
PIDFILE="$(mktemp -t swiftos-siteseed-pid.XXXXXX)"
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
send() { printf '%s\n' "$1" >&3; sleep 0.2; }

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
  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || fail "no tty line prompt"
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
  sleep 4   # the busybox console is slow; let nginx exec and bind before curling
  grep -qiE "\[emerg\]|\[alert\]" "$CURLOG" && fail "nginx fatal error"
}

curl_body() {  # curl_body OUTFILE  -> 0 if a non-empty body was fetched
  local body="$1" i
  for i in $(seq 1 60); do
    if curl -s -m 5 "http://127.0.0.1:${HOST_PORT}/" -o "$body" 2>/dev/null; then
      [[ -s "$body" ]] && return 0
    fi
    sleep 0.5
  done
  return 1
}

# ---- Boot 1: fresh /data -> seed from baked default, serve it --------------
# `swupdate seed` runs inside swos-init, which executes after the interactive tty
# demo is dismissed (handled by login) and just before the login prompt — so we
# log in first, then assert the seed message is already on the serial log.
start_boot "$WORK/boot1.log" "$WORK/in1"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 1)"
login
await "swupdate: seed: seeded /data/www/current from baked default" 5 \
  || fail "boot 1 did not seed /data/www/current from the baked default"
start_nginx
curl_body "$WORK/body1" || fail "nginx did not serve the seeded docroot on boot 1"
cmp -s "$WORK/body1" "$BAKED" \
  || fail "boot 1 served content differs from the baked default site"
echo "ok: fresh /data seeded and served the baked default"
stop_qemu

# ---- Boot 2: same disk -> stage a crash-interrupted atomic swap ------------
# No nginx here (it would starve the single-core console), so the staging
# commands run promptly. We leave the disk in exactly the state a power loss
# *between the two renames* would: current already moved to prev, next staged.
start_boot "$WORK/boot2.log" "$WORK/in2"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 2)"
login
# Use the busybox applets (bare names), which handle -p / dir rename cleanly.
send 'mkdir -p /data/www/next'
send "echo $NEWMARK > /data/www/next/index.html"
# The split literal (ST''AGED) prints as STAGED in the command *output* but not in
# the echoed *input* line, so await matches only the completed command.
send "mv /data/www/current /data/www/prev && echo ST''AGED_OK"
await "STAGED_OK" 30 || fail "staging the interrupted swap did not complete"
sleep 1
stop_qemu

# ---- Boot 3: same disk -> seed recovers the interrupted swap ---------------
start_boot "$WORK/boot3.log" "$WORK/in3"
await "D1 OK: datafs mounted at /data" 60 || fail "datafs not mounted (boot 3)"
login
await "swupdate: seed: completed interrupted update (next -> current)" 5 \
  || fail "boot 3 did not recover the interrupted swap (next -> current)"
start_nginx
curl_body "$WORK/body3" || fail "nginx did not serve a docroot on boot 3"
grep -qF "$NEWMARK" "$WORK/body3" \
  || fail "recovered docroot did NOT serve the staged new content after reboot"
echo "ok: crash-interrupted swap recovered to current and served after reboot"

echo "PASS: site seed + atomic-swap recovery survive reboot without reflash (M-A)"
exit 0
