#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# llm_serve_disk_test.sh — LM3c acceptance: /bin/llmd serves a model delivered
# off the dedicated model disk (not the base), under a larger-RAM inference
# profile.
#
# Boots the inference profile: a bigger -m (real models need RAM headroom), the
# base disk, the signed model disk (LM3a/LM3b, mounted read-only at /srv/models),
# and a slirp NIC hostfwd'ing host TCP to guest 8080. Logs in, starts /bin/llmd,
# and asserts:
#   - llmd reports "serving from model disk /srv/models" (LM3c chose the disk
#     bundle over the base bundle), and
#   - a POST /completion returns the stories15M runq.c reference story — i.e. the
#     disk-delivered model actually runs end to end.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
MODEL_IMG="$ROOT/build/model.img"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_PORT="${HOST_PORT:-18080}"
STORY_MARK="Once upon a time"
INFER_MEM="${INFER_MEM:-1024M}"

[[ -f "$KERNEL" ]]    || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$MODEL_IMG" ]] || { echo "FAIL: $MODEL_IMG missing (make model-image)" >&2; exit 2; }
[[ -f "$DISK" ]]      || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-llmddisk.XXXXXX)"
OC="$(mktemp -t swiftos-llmddisk-oc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-llmddisk-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-llmddisk-in.XXXXXX)"; mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$OC" "$PIDFILE" "$INFIFO"' EXIT

await() {
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -50 >&2 || true
  exit 1
}
send_line() {
  local line="$1" delay="${SLEEP_CHAR_DELAY:-0.01}" i
  for (( i = 0; i < ${#line}; i++ )); do printf '%s' "${line:i:1}" >&3; sleep "$delay"; done
  printf '\n' >&3
  sleep "${SLEEP_SEND_DELAY:-0.08}"
}

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m "$INFER_MEM" -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
[[ -f "$DTB" ]] && qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -drive "file=$MODEL_IMG,format=raw,if=none,id=swosmodel,readonly=on"
  -device virtio-blk-device,drive=swosmodel
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8080"
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL")
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "LM3b: model disk mounted read-only at /srv/models" 60 \
  || drive_fail "model disk not mounted at /srv/models"
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
send_line 'root'
await "Password:" 90 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "M12c: shell ready" 120 || drive_fail "root shell did not start"
send_line '/bin/llmd'
await "llmd: serving from model disk /srv/models" 60 \
  || drive_fail "llmd did not choose the model-disk bundle"
await "llmd: serving on 8080" 240 || drive_fail "llmd never reported serving"

post_ok=0
for _ in 1 2 3; do
  if curl -s -m 180 -X POST --data "$STORY_MARK" \
       "http://127.0.0.1:${HOST_PORT}/completion" > "$OC" 2>/dev/null \
     && grep -qF "$STORY_MARK" "$OC"; then
    post_ok=1; break
  fi
  sleep 1
done
exec 3>&-; stop_qemu; QP=""

CLEAN="$(sed 's/\r//' "$LOG")"
ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

grep -qF "llmd: serving from model disk /srv/models" <<<"$CLEAN" || fail "llmd did not serve from the model disk"
[[ "$post_ok" -eq 1 ]]                                            || fail "POST /completion did not return a story"
grep -qF "She loved to play outside in the sunshine" "$OC"        || fail "disk-served completion diverged from the runq.c reference"

if (( ok )); then
  echo "PASS: /bin/llmd served the disk-delivered model from /srv/models (-m $INFER_MEM); story matches reference"
  exit 0
fi
echo "--- serial (llmd region) ---" >&2
sed -n '/llmd:/,$p' <<<"$CLEAN" | head -40 >&2
echo "--- completion body ---" >&2; cat "$OC" >&2
exit 1
