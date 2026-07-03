#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# prod_boot_test.sh — P1.4 acceptance: production service manifest autostarts
# nginx, sshd, inputd, and llmd under swos-init supervision (headless).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
BASE_IMG="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
TIMEOUT="${TIMEOUT:-180}"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$BASE_IMG" ]] || { echo "FAIL: $BASE_IMG missing (make base-image-prod)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-prod-boot.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-prod-boot-pid.XXXXXX)"
QP=""

cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
  rm -f "$LOG" "$PIDFILE"
}
trap cleanup EXIT

dtb_args=()
if [[ ! -f "$DTB" ]]; then
  tmp_dtb="$DTB.tmp"
  mkdir -p "$(dirname "$DTB")"
  "$QEMU" -M "virt,dumpdtb=$tmp_dtb" -cpu cortex-a72 -m 256M -nographic >/dev/null 2>&1
  mv "$tmp_dtb" "$DTB"
fi
[[ -f "$DTB" ]] && dtb_args=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")

"$QEMU" -M virt -cpu cortex-a72 -m 512M -nographic -no-reboot \
  -global virtio-mmio.force-legacy=false \
  "${dtb_args[@]}" \
  -drive "file=$BASE_IMG,format=raw,if=none,id=swosbase,readonly=on" \
  -device virtio-blk-device,drive=swosbase \
  -netdev user,id=net0,hostfwd=tcp::18080-:8080 \
  -device virtio-net-device,netdev=net0 \
  -kernel "$KERNEL" -serial "file:$LOG" -pidfile "$PIDFILE" & QP=$!

await() {
  local marker="$1" max="${2:-120}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}

dump_tail() {
  echo "--- serial tail ---" >&2
  sed 's/\r//' "$LOG" | tail -80 >&2
}

EXPECT=(
  "swos-init: started nginx"
  "swos-init: started sshd"
  "swos-init: started inputd"
  "swos-init: started llmd"
  "swos-init: supervision active"
  "sshd: listening on 22"
  "llmd: serving on 8080"
)

for line in "${EXPECT[@]}"; do
  await "$line" "$TIMEOUT" || {
    echo "FAIL: missing marker: $line" >&2
    dump_tail
    exit 1
  }
done

if grep -qF "swos-init: starting console-login session" "$LOG" 2>/dev/null; then
  echo "FAIL: prod profile handed off to console-login (expected headless supervision)" >&2
  dump_tail
  exit 1
fi

if command -v curl >/dev/null 2>&1; then
  curl -fsS "http://127.0.0.1:18080/health" >/dev/null 2>&1 || {
    echo "FAIL: llmd /health not reachable via hostfwd" >&2
    dump_tail
    exit 1
  }
fi

echo "PASS: prod boot profile — supervised nginx, sshd, inputd, llmd (headless)"