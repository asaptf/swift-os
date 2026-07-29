#!/usr/bin/env bash
# v2_manifest_test.sh — V2b acceptance: the declarative mount manifest
# /data/.system/mounts drives where labeled volumes mount, with guardrails.
#
# Boot 1 (no manifest): the "media"-labeled disk auto-mounts at /mnt/media (V2a
#   default). A file is written under it, then a manifest `media /mnt/store` is
#   created on /data.
# Boot 2 (manifest present): the manifest is authoritative — the media disk now
#   mounts at /mnt/store (the file follows the disk to its new mountpoint) and is
#   NOT at /mnt/media. Then the manifest is rewritten to a forbidden mountpoint
#   `media /etc/evil`.
# Boot 3 (bad manifest): the /mnt-only guardrail refuses the entry, so the media
#   disk is left unmounted (no /mnt/store, no /mnt/media) and /etc is untouched.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

FILEMARK="swiftos-V2B-file-3w7p"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-v2man.XXXXXX)"
DATA_IMG="$WORK/data.img"        # volume 0 -> /data (unlabeled, holds the manifest)
DATA2_IMG="$WORK/data2.img"      # labeled "media"
PIDFILE="$(mktemp -t swiftos-v2man-pid.XXXXXX)"
QP=""; CURLOG=""

dd if=/dev/zero of="$DATA_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
dd if=/dev/zero of="$DATA2_IMG" bs=1048576 count=16 2>/dev/null
printf 'SWDATAFS' | dd of="$DATA2_IMG" bs=1 seek=0 conv=notrunc 2>/dev/null
printf '\005'     | dd of="$DATA2_IMG" bs=1 seek=60 conv=notrunc 2>/dev/null
printf 'media'    | dd of="$DATA2_IMG" bs=1 seek=61 conv=notrunc 2>/dev/null

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

await() { local marker="$1" max="${2:-60}" n=0
  while (( n < max * 10 )); do grep -qF "$marker" "$CURLOG" 2>/dev/null && return 0; sleep 0.1; n=$((n + 1)); done
  return 1
}
send() { printf '%s\n' "$1" >&3; sleep 0.2; }

fail() {
  echo "FAIL: $1" >&2
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$CURLOG" 2>/dev/null | sed -n '/D1/,$p' | tail -40 >&2 || true
  exit 1
}

start_boot() { local log="$1" fifo="$2"
  rm -f "$fifo"; mkfifo "$fifo"; CURLOG="$log"
  "$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot \
    -pidfile "$PIDFILE" -global virtio-mmio.force-legacy=false "${dtb_args[@]}" \
    -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" -device virtio-blk-device,drive=swosbase \
    -drive "file=$DATA_IMG,format=raw,if=none,id=swosdata" -device virtio-blk-device,drive=swosdata \
    -drive "file=$DATA2_IMG,format=raw,if=none,id=swosdata2" -device virtio-blk-device,drive=swosdata2 \
    -kernel "$KERNEL" <"$fifo" >"$log" 2>&1 &
  QP=$!; exec 3<>"$fifo"
}

login() {
  await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || fail "no tty line prompt"
  send 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
  printf '\003' >&3; sleep 0.15
  await "swift-os login:" 90 || fail "no login prompt"
  send 'root'; await "Password:" 90 || fail "no password prompt"
  send 'swordfish'; await "Welcome to swift-os, root" 120 || fail "root login did not complete"
  await_shell_ready "$CURLOG" 60 || fail "guest shell not reading after login"
}

# ---- Boot 1: auto-mount at /mnt/media, write a file, create the manifest -----
start_boot "$WORK/b1.log" "$WORK/in1"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "media disk not auto-mounted on boot 1"
login
send 'ls /mnt'
await "media" 30 || fail "boot 1: media did not auto-mount at /mnt/media"
send "echo $FILEMARK > /mnt/media/f.txt"
send 'mkdir -p /data/.system'
send 'echo "media /mnt/store" > /data/.system/mounts'
send 'cat /data/.system/mounts'
await "media /mnt/store" 30 || fail "boot 1: manifest not written to /data"
send 'sync'; send 'exit'; sleep 0.8; stop_qemu

# ---- Boot 2: manifest remaps media -> /mnt/store; /mnt/media absent ----------
start_boot "$WORK/b2.log" "$WORK/in2"
await "V2 OK: mount manifest applied" 60 || fail "boot 2: manifest not read from /data"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "boot 2: media disk not mounted per manifest"
login
send 'ls /mnt'
await "store" 30 || fail "boot 2: media did not mount at /mnt/store per manifest"
send 'cat /mnt/store/f.txt'
await "$FILEMARK" 30 || fail "boot 2: file did not follow the disk to /mnt/store"
send 'cat /mnt/media/f.txt 2>/dev/null || echo V2B-NO-MEDIA-b2'
await "V2B-NO-MEDIA-b2" 30 || fail "boot 2: /mnt/media still present (manifest not authoritative)"
# Rewrite the manifest to a forbidden mountpoint for boot 3.
send 'echo "media /etc/evil" > /data/.system/mounts'
send 'sync'; send 'exit'; sleep 0.8; stop_qemu

# ---- Boot 3: guardrail refuses /etc/evil; media unmounted; /etc untouched ----
start_boot "$WORK/b3.log" "$WORK/in3"
await "V2 OK: mount manifest applied" 60 || fail "boot 3: manifest not read"
await "V2: manifest mountpoint refused" 60 || fail "boot 3: forbidden mountpoint was NOT refused (guardrail failed)"
login
send 'cat /mnt/store/f.txt 2>/dev/null || echo V2B-NO-STORE-b3'
await "V2B-NO-STORE-b3" 30 || fail "boot 3: media wrongly mounted at /mnt/store"
send 'cat /etc/motd >/dev/null 2>&1 && echo V2B-ETC-OK-b3'
await "V2B-ETC-OK-b3" 30 || fail "boot 3: /etc was overmounted/clobbered by the manifest"
send 'exit'; sleep 0.3; stop_qemu

echo "PASS: mount manifest remaps by label + /mnt-only guardrail refuses bad mountpoints (V2b acceptance)"
exit 0
