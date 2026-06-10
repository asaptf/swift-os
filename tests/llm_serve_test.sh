#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# llm_serve_test.sh — acceptance for /bin/llmd, the TCP model-serving daemon
# (I3 of the AI-hosting proof arc: inference served over the network).
#
# Boots with a slirp NIC hostfwd'ing host TCP to guest 8080, logs in as root,
# starts /bin/llmd (weights file-backed mmap'd from /models, I2), then from the
# host asserts:
#   - POST /completion with "Once upon a time" streams back the generated story,
#     matching the llama2.c reference text (real inference over TCP);
#   - GET /health reports the model;
#   - GET /metrics reports requests/tokens_total and a tok/s figure;
#   - the server logged a per-request metrics line (ttft + rate) on serial.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/build/kernel.elf"
DTB="$ROOT/build/virt.dtb"
DISK="$ROOT/build/base.img"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_PORT="${LLMD_HOST_PORT:-$((24000 + ($$ % 20000)))}"
STORY_MARK="there was a little girl named Lily"

[[ -f "$KERNEL" ]] || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
if [[ ! -f "$DISK" ]]; then
  ( cd "$ROOT" && make base-image ) >/dev/null 2>&1 || { echo "FAIL: cannot build base.img" >&2; exit 2; }
fi
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl not found" >&2; exit 2; }

LOG="$(mktemp -t swiftos-llmd.XXXXXX)"
OC="$(mktemp -t swiftos-llmd-oc.XXXXXX)"   # /completion body
OH="$(mktemp -t swiftos-llmd-oh.XXXXXX)"   # /health body
OM="$(mktemp -t swiftos-llmd-om.XXXXXX)"   # /metrics body
PIDFILE="$(mktemp -t swiftos-llmd-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-llmd-in.XXXXXX)"
mkfifo "$INFIFO"
QP=""
stop_qemu() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; }
  fi
  [[ -n "$QP" ]] && wait "$QP" 2>/dev/null || true
}
trap 'stop_qemu; exec 3>&- 2>/dev/null || true; rm -f "$LOG" "$OC" "$OH" "$OM" "$PIDFILE" "$INFIFO"' EXIT

await() {  # await MARKER [MAXSEC]
  local marker="$1" max="${2:-30}" n=0
  while (( n < max * 10 )); do
    grep -qF "$marker" "$LOG" 2>/dev/null && return 0
    sleep 0.1; n=$((n + 1))
  done
  return 1
}

drive_fail() {
  echo "FAIL: $1" >&2
  echo "--- serial (llmd driver) ---" >&2
  sed 's/\r//' "$LOG" 2>/dev/null | tail -120 >&2 || true
  exit 1
}

qemu_args=("$QEMU" -M virt -cpu cortex-a72 -m 256M -nographic -no-reboot
  -pidfile "$PIDFILE"
  -global virtio-mmio.force-legacy=false)
if [[ -f "$DTB" ]]; then
  qemu_args+=(-device "loader,file=$DTB,addr=0x4FF00000,force-raw=on")
fi
qemu_args+=(-drive "file=$DISK,format=raw,if=none,id=swosbase,readonly=on"
  -device virtio-blk-device,drive=swosbase
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HOST_PORT}-:8080"
  -device virtio-net-device,netdev=n0
  -kernel "$KERNEL")
"${qemu_args[@]}" <"$INFIFO" >"$LOG" 2>&1 &
QP=$!
exec 3<>"$INFIFO"

await "M7 tty: type a line then Enter" 60 || drive_fail "tty demo did not become ready"
printf 'tty-line\n' >&3
await "M7 tty: running; press Ctrl-C" 40 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swift-os login:" 90 || drive_fail "login prompt did not appear"
printf 'root\n' >&3
await "Password:" 90 || drive_fail "password prompt did not appear"
printf 'swordfish\n' >&3
await "built-in shell (ash)" 120 || drive_fail "root shell did not start"
printf '/bin/llmd\n' >&3
# Startup parses the 32000-entry tokenizer into the lookup table under TCG.
await "llmd: serving on 8080" 240 || drive_fail "llmd never reported serving"

# Patient request loop: slirp + guest poll() can need a beat to be reachable.
# The served model is stories15M-q8 (I4): one 64-token completion takes several
# seconds under TCG (the cold first request also demand-pages ~17 MB of weights),
# so give curl a generous budget.
post_ok=0
for _ in 1 2 3; do
  if curl -s -m 180 -X POST --data "Once upon a time" \
       "http://127.0.0.1:${HOST_PORT}/completion" > "$OC" 2>/dev/null \
     && grep -qF "$STORY_MARK" "$OC"; then
    post_ok=1; break
  fi
  sleep 1
done
curl -s -m 10 "http://127.0.0.1:${HOST_PORT}/health" > "$OH" 2>/dev/null || true
curl -s -m 10 "http://127.0.0.1:${HOST_PORT}/metrics" > "$OM" 2>/dev/null || true
exec 3>&-
stop_qemu
QP=""

CLEAN="$(sed 's/\r//' "$LOG")"
ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

[[ "$post_ok" -eq 1 ]]                                  || fail "POST /completion did not return the reference story"
# stories15M-q8 reference (runq.c golden): richer than the 260K story.
grep -qF "She loved to play outside in the sunshine" "$OC" || fail "completion body diverged from the runq.c reference"
grep -qF "It was the sun!" "$OC"                        || fail "completion body diverged from the runq.c reference (tail)"
grep -qF "ok model dim=288" "$OH"                       || fail "GET /health did not report the model"
grep -qF "llmd: model int8 Q8_0 GS=32" <<<"$CLEAN"      || fail "llmd did not select the quantized engine"
# I5: the deliberately-corrupt generation 2 is rejected by sha256/size checks,
# and serving falls back to the verified generation 1 — the documented
# verify-and-roll-back bundle flow, exercised on every boot.
grep -qF "llmd: generation 2 rejected (model size/sha256 mismatch)" <<<"$CLEAN" \
                                                        || fail "corrupt generation 2 was not rejected"
# I7: the trust root shipped in the base image makes manifest signatures
# mandatory; gen 2's signature is valid (its payload hash is what fails), and
# gen 1 verifies through both layers.
grep -qF "llmd: trust root loaded (/etc/swos/model-signing.pub)" <<<"$CLEAN" \
                                                        || fail "trust root was not loaded"
grep -qF "llmd: bundle stories15M generation 1 verified (ed25519+sha256)" <<<"$CLEAN" \
                                                        || fail "generation 1 was not signature-verified"
grep -qE "requests [1-9]" "$OM"                         || fail "GET /metrics did not count the request"
grep -qE "tokens_total [1-9][0-9]*" "$OM"               || fail "GET /metrics did not count generated tokens"
grep -qE "last_tok_s [0-9]+" "$OM"                      || fail "GET /metrics missing a tok/s figure"
grep -qF "llmd: weights mmap'd file-backed" <<<"$CLEAN" || fail "weights not loaded via file-backed mmap"
grep -qE "llmd: served [0-9]+ tokens ttft=[0-9]+ ms rate=[0-9]+ tok/s" <<<"$CLEAN" \
                                                        || fail "per-request serving metrics line missing on serial"

if [[ "$ok" -eq 1 ]]; then
  RATE="$(grep -oE 'rate=[0-9]+ tok/s' <<<"$CLEAN" | head -1)"
  TTFT="$(grep -oE 'ttft=[0-9]+ ms' <<<"$CLEAN" | head -1)"
  echo "PASS: /bin/llmd served inference over TCP (story matches reference; ${TTFT:-ttft n/a}, ${RATE:-rate n/a})"
  exit 0
fi
echo "--- serial (llmd region) ---" >&2
sed -n '/llmd:/,$p' <<<"$CLEAN" | head -40 >&2
echo "--- completion body ---" >&2; cat "$OC" >&2
echo "--- health ---" >&2; cat "$OH" >&2
echo "--- metrics ---" >&2; cat "$OM" >&2
exit 1
