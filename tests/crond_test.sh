#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# crond_test.sh — CR1 acceptance for the native Swift cron daemon /bin/crond.
#
# Boots the packed base image with a writable, SWDATAFS-stamped /data disk and a
# slirp NIC, then proves two things:
#
#   1. The default /etc/crontab (shipped, all comments) parses to zero jobs:
#      a crond launched with no arguments logs "crond: loaded 0 job(s)".
#
#   2. Behavior: we launch a crond against a baked test crontab. It must
#        - fire an @reboot job once at start (-> "crond:reboot-marker"),
#        - fire an @every 3s job repeatedly (-> >=2 "crond:tick" lines),
#        - run each job via `/bin/sh -c`, appending to /data/crond/last-run so
#          the durable tier ends up with >=2 lines (proves real job execution +
#          /data writes, not just scheduling).
#
# crond is opt-in (not in the default /etc/swos/services), so the test starts it
# by hand from the login shell rather than relying on boot auto-start.
#
# A job runs as `/bin/sh -c "<command>"`, which the kernel maps to busybox; the
# spawned job inherits crond's stdout, so its echoes reach the serial console.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-crond.XXXXXX)"
LOG="$WORK/serial.log"
DATA_IMG="$WORK/data.img"
PIDFILE="$WORK/qemu.pid"
INFIFO="$WORK/in.fifo"; mkfifo "$INFIFO"
QP=""

# Fresh, stamped data disk: 32 MiB of zeros with the "SWDATAFS" magic at byte 0;
# the kernel formats it on first mount and exposes it as /data.
dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=32 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null

stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -rf "$WORK"' EXIT

dtb_args=()
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

await_regex_count() {  # await_regex_count REGEX COUNT [MAXSEC]
  local regex="$1" want="$2" max="${3:-30}" n=0 got=0
  while (( n < max * 10 )); do
    got="$(sed 's/\r//' "$LOG" 2>/dev/null | grep -Ec -- "$regex" || true)"
    (( got >= want )) && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (tail) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -80 >&2
  exit 1
}

# 0.5s between lines: the canonical tty pacing for this harness — shorter delays
# let lines collide in the serial input and the shell drops commands.
send() { printf '%s\n' "$1" >&3; sleep 0.5; }

"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
  -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false \
  ${dtb_args[@]+"${dtb_args[@]}"} \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" \
  -device virtio-blk-device,drive=swosdata \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

# /data must come up early (kernel mount marker, before the tty handoff).
await "D1 OK: datafs mounted at /data" 90 || fail "datafs not mounted at /data"

# Log in as root (same handoff the other base-image tests use). swos-init starts
# the configured services (incl. crond) right after the tty demo, just before the
# login prompt — so the system-crond assertions come after we reach the shell.
await "M7 tty: type a line then Enter" 90 || fail "no tty line prompt"
send 'tty-line'
await "M7 tty: running; press Ctrl-C" 60  || fail "no tty Ctrl-C prompt"
printf '\003' >&3
await "swift-os login:" 90                || fail "no login prompt"
send 'root'
await "Password:" 90                       || fail "no password prompt"
send 'swordfish'
await "Welcome to swift-os, root" 120     || fail "root login did not complete"
await "built-in shell (ash)" 120          || fail "root shell did not start"

# The default /etc/crontab is all comments -> a no-arg crond loads zero jobs.
send '/bin/crond &'
await "crond: loaded 0 job(s)" 30         || fail "default /etc/crontab did not parse to zero jobs"
send 'kill %1 2>/dev/null'

# Launch a crond against the baked test crontab (/etc/crontab.test). It is
# read from the signed base image, so driving it needs only one short, quote-free
# command over the fragile serial tty (writing a multi-line crontab byte by byte
# over the console is unreliable). The @every job appends to /data on each run.
send '/bin/crond /etc/crontab.test &'

await "crond: loaded 2 job(s)" 60         || fail "crond did not parse the 2-job test crontab"
await "crond:reboot-marker" 30            || fail "@reboot job did not fire at start"
await_regex_count "crond:tick" 2 40       || fail "@every 3s job did not fire repeatedly (<2 ticks)"

# Stop the background crond so the tick output (and the file) settle, then read
# the durable file back. Each tick appended a "crond:durable" line to
# /data/crond/last-run (via the job's own `>>`, so this string reaches the log
# ONLY through cat, never through the job's stdout). Seeing it >=2 times proves
# >=2 lines persisted on the /data tier.
send 'kill %1 2>/dev/null'
sleep 1
send 'cat /data/crond/last-run'
await_regex_count "crond:durable" 2 20    || fail "/data/crond/last-run did not accumulate >=2 durable lines"

exec 3>&-
stop_qemu
QP=""

echo "PASS: /bin/crond — default crontab parse + @reboot + @every + durable /data job output (CR1)"
exit 0
