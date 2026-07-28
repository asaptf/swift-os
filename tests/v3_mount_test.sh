#!/usr/bin/env bash
# v3_mount_test.sh — V3a acceptance: runtime, capability-gated mount()/unmount().
#
# A "media"-labeled datafs disk is present but left UNMOUNTED at boot (an
# authoritative-but-empty manifest lists nothing for it), so it is enumerated yet
# not grafted — exactly the state a runtime mount() operates on.
#
# Boot 1 (no manifest): media auto-mounts at /mnt/media (V2a default). We write a
#   comment-only manifest to /data so media is NOT auto-mounted next boot.
# Boot 2 (manifest authoritative, lists nothing): media is enumerated but
#   unmounted. /bin/mountprobe then exercises the V3 syscalls:
#     * mount media at /mnt/store (rc=0), read/write a file under it;
#     * a BUSY unmount (the shell cwd is inside /mnt/store) is refused with EBUSY;
#     * once idle (cwd back at /), unmount succeeds (rc=0) and /mnt/store is gone.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

FILEMARK="swiftos-V3A-file-9k2x"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-v3mnt.XXXXXX)"
DATA_IMG="$WORK/data.img"        # volume 0 -> /data (unlabeled, holds the manifest)
DATA2_IMG="$WORK/data2.img"      # labeled "media", mounted at runtime
PIDFILE="$(mktemp -t swiftos-v3mnt-pid.XXXXXX)"
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
}

# ---- Boot 1: media auto-mounts; write a comment-only manifest so it won't next --
start_boot "$WORK/b1.log" "$WORK/in1"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "media disk not auto-mounted on boot 1"
login
send 'mkdir -p /data/.system'
send 'echo "# v3a: media is mounted at runtime, not at boot" > /data/.system/mounts'
send 'cat /data/.system/mounts'
await "v3a: media is mounted at runtime" 30 || fail "boot 1: comment manifest not written to /data"
send 'sync'; send 'exit'; sleep 0.8; stop_qemu

# ---- Boot 2: media enumerated but unmounted; drive the runtime mount syscalls ---
start_boot "$WORK/b2.log" "$WORK/in2"
await "V2 OK: mount manifest applied" 60 || fail "boot 2: manifest not read from /data"
login

# media must NOT be mounted at boot (manifest authoritative, lists nothing).
send 'cat /mnt/media/x 2>/dev/null || echo V3-MEDIA-UNMOUNTED'
await "V3-MEDIA-UNMOUNTED" 30 || fail "boot 2: media should be unmounted at boot"

# Runtime mount media at /mnt/store.
send 'mountprobe mount media /mnt/store'
await "MP: mount rc=0" 30 || fail "runtime mount(media -> /mnt/store) failed"
await "V3 OK: runtime mount" 30 || fail "kernel did not report the runtime mount"
send 'ls /mnt'
await "store" 30 || fail "/mnt/store not present after runtime mount"

# Read/write the freshly mounted volume.
send "echo $FILEMARK > /mnt/store/v3.txt"
send 'cat /mnt/store/v3.txt'
await "$FILEMARK" 30 || fail "read/write of the runtime-mounted volume failed"

# Busy unmount: a process cwd inside the subtree must refuse with EBUSY (-16).
send 'cd /mnt/store'
send 'mountprobe unmount /mnt/store'
await "MP: unmount rc=-16" 30 || fail "busy unmount was NOT refused with EBUSY"

# Idle unmount: cwd back at /, the unmount succeeds and /mnt/store disappears.
send 'cd /'
send 'mountprobe unmount /mnt/store'
await "MP: unmount rc=0" 30 || fail "idle unmount did not succeed"
await "V3 OK: runtime unmount" 30 || fail "kernel did not report the runtime unmount"
send 'cat /mnt/store/v3.txt 2>/dev/null || echo V3-NO-STORE'
await "V3-NO-STORE" 30 || fail "/mnt/store still reachable after unmount"
send 'exit'; sleep 0.3; stop_qemu

echo "PASS: runtime mount + read/write + busy-EBUSY + idle unmount (V3a acceptance)"
exit 0
