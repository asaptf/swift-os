#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# multisector_test.sh — U1f-2a acceptance: the virtio-blk driver now serves every
# base-image read through multi-sector requests (blkDoMulti / virtioBlkReadRange),
# moving whole runs of sectors per virtio request instead of one at a time.
#
# This is exercised end-to-end, not by a synthetic probe: with a multi-sector
# read path backing the read-only base, a SINGLE wrong byte anywhere fails one of
# the image's cryptographic checks, so a clean boot proves byte-exact transfers
# across read sizes that span chunk boundaries:
#   - the signed [header|entries|strings] region (Ed25519)  -> "signature verified"
#   - a small payload file (/etc/motd, < 1 sector)          -> motd content
#   - busybox.elf (~1.1 MB ≈ 18 of the 64 KiB multi-sector chunks), loaded by
#     execResolve via virtioBlkReadRange in one call: the ash shell only launches
#     if that large, multi-chunk read is byte-exact -> "built-in shell (ash)"
#
# A regression in the multi-sector logic (off-by-one sector count, chunk-boundary
# copy slip, capacity clamp) corrupts one of these and the matching marker never
# appears.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$DISK" ]]   || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-msec-log.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-msec-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-msec-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$PIDFILE" "$INFIFO"' EXIT

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

# Byte-by-byte serial drive (see tests/ab_activate_test.sh): the emulated PL011 RX
# FIFO drops bursts, so settle then write one char at a time.
send() {
  sleep 0.3
  local s="$1" i
  for (( i = 0; i < ${#s}; i++ )); do printf '%s' "${s:i:1}" >&3; sleep 0.03; done
}

: > "$LOG"
"$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot -pidfile "$PIDFILE" \
  -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
  -drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -kernel "$KERNEL" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!; exec 3<>"$INFIFO"

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# Signed metadata region read byte-exact (Ed25519 over header|entries|strings).
await "base image signature verified (ed25519)" 60 || fail "base image signature did not verify (multi-sector metadata read)"
await "M11c: read-only base mounted from disk" 30 || fail "base did not mount"
# A small payload file read correctly during the non-interactive demo.
await "cat /etc/motd: Welcome to swift-os." 60 || fail "etc/motd content wrong (multi-sector payload read)"
# A small ELF loaded + run via virtioBlkReadRange.
await "M6 OK: ELF process exited, code 7" 60 || fail "demo ELF did not load/run (multi-sector ELF read)"

# The large multi-chunk read: launching the ash shell loads busybox.elf (~1.1 MB)
# through a single virtioBlkReadRange spanning ~18 of the 64 KiB chunks.
if await "M7 tty: type a line then Enter" 60; then
  send $'tty-line\n'
  await "M7 tty: running; press Ctrl-C" 40 || fail "could not pass ttydemo"
  send $'\003'
  await "swift-os login:" 90 || fail "no login prompt"
  send $'root\n'
  await "Password:" 90 || fail "no password prompt"
  send $'swordfish\n'
  await "built-in shell (ash)" 120 || fail "busybox shell did not launch (large multi-chunk ELF read corrupted)"
  send $'cat /etc/motd\n'
  await "Welcome to swift-os." 30 || fail "shell could not read /etc/motd"
else
  fail "did not reach ttydemo"
fi
exec 3>&-; stop_qemu; QP=""

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: multi-sector virtio-blk — signed metadata, payload files, and a ~1.1 MB busybox ELF all read byte-exact through multi-sector requests"
  exit 0
fi
echo "--- serial (last boot) ---" >&2
sed 's/\r//' "$LOG" | tail -40 >&2
exit 1
