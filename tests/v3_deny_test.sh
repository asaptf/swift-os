#!/usr/bin/env bash
# v3_deny_test.sh — V3c acceptance: mount()/unmount() are capability-gated, so an
# unprivileged principal is denied with EACCES while a privileged one still works.
#
# Boot 1 (no manifest): the "media" disk auto-mounts at /mnt/media (V2a default);
#   we write a comment-only manifest so media is NOT auto-mounted next boot.
# Boot 2 (manifest lists nothing): media is enumerated but unmounted.
#   * `mountprobe denytest` drops capConsole (login to a non-console principal),
#     then mount AND unmount both return EACCES (-13), and /mnt/store is NOT
#     created (the gate refuses before any mount work);
#   * a fresh, still-privileged `mountprobe mount` then succeeds (rc=0) — proving
#     the disk was mountable and the denial was purely the capability gate.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image)" >&2; exit 2; }

WORK="$(mktemp -d -t swiftos-v3deny.XXXXXX)"
DATA_IMG="$WORK/data.img"        # volume 0 -> /data (unlabeled, holds the manifest)
DATA2_IMG="$WORK/data2.img"      # labeled "media"
PIDFILE="$(mktemp -t swiftos-v3deny-pid.XXXXXX)"
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
  await "M7 tty: type a line then Enter" 60 || fail "no tty line prompt"
  send 'tty-line'
  await "M7 tty: running; press Ctrl-C" 40 || fail "no tty Ctrl-C prompt"
  printf '\003' >&3; sleep 0.15
  await "swift-os login:" 90 || fail "no login prompt"
  send 'root'; await "Password:" 90 || fail "no password prompt"
  send 'swordfish'; await "Welcome to swift-os, root" 120 || fail "root login did not complete"
}

# ---- Boot 1: media auto-mounts; seed a comment-only manifest -------------------
start_boot "$WORK/b1.log" "$WORK/in1"
await "V1 OK: datafs volume mounted under /mnt" 60 || fail "media disk not auto-mounted on boot 1"
login
send 'mkdir -p /data/.system'
send 'echo "# v3c: media is mounted at runtime, not at boot" > /data/.system/mounts'
send 'sync'; send 'exit'; sleep 0.8; stop_qemu

# ---- Boot 2: unprivileged mount/unmount denied; privileged mount succeeds -------
start_boot "$WORK/b2.log" "$WORK/in2"
await "V2 OK: mount manifest applied" 60 || fail "boot 2: manifest not read"
login

# Unprivileged (capConsole dropped): mount AND unmount both EACCES (-13).
send 'mountprobe denytest media /mnt/store'
await "MP: mount rc=-13" 30 || fail "unprivileged mount was NOT denied with EACCES"
await "MP: unmount rc=-13" 30 || fail "unprivileged unmount was NOT denied with EACCES"
# The denied mount created nothing.
send 'cat /mnt/store/x 2>/dev/null || echo V3-DENY-NO-STORE'
await "V3-DENY-NO-STORE" 30 || fail "denied mount still created /mnt/store"

# Privileged (fresh process, still root): the same mount now succeeds — the disk
# was mountable, so the denial above was purely the capability gate.
send 'mountprobe mount media /mnt/store'
await "MP: mount rc=0" 30 || fail "privileged mount of the same volume failed"
await "V3 OK: runtime mount" 30 || fail "kernel did not report the privileged mount"
send 'exit'; sleep 0.3; stop_qemu

echo "PASS: unprivileged mount/unmount denied (EACCES), privileged mount allowed (V3c acceptance)"
exit 0
