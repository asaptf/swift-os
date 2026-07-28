#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# llm_serve_gguf_test.sh — LM5d acceptance: serve the TinyLlama Q4_K_M GGUF end
# to end off the dedicated model disk (the mainstream GGUF / k-quant format).
#
# Boots the inference profile, the base disk, the signed GGUF model disk
# (build/model-gguf.img, bundle tinyllama-gguf, mounted read-only at /srv/models
# by LM3b), and a slirp NIC hostfwd'ing host TCP to guest 8080. Logs in, starts
# /bin/llmd, and asserts:
#   - llmd serves from the disk, selects the tinyllama-gguf bundle, and loads the
#     GGUF k-quant engine (GGUFLlama), and
#   - a short POST /completion?n=N returns a COHERENT answer ("The capital of
#     France is" -> "Paris"), with a tokens/sec rate logged.
#
# The GGUF engine re-dequantizes the compressed (~0.6 GB) model every token, which
# is heavy under QEMU-TCG (tens of seconds per forward), so we ask for very few
# tokens with a large curl window; the criterion is coherence, not throughput.
# This also confirms the Q4_K/Q6_K dequant is correct under +neon (not just host).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
KERNEL="$ROOT/build/kernel.elf"
# The kernel sizes RAM from the DTB's /memory node, so the inference profile
# needs a DTB that advertises the larger window (the 2 GiB one) to match -m;
# the default 256 MiB DTB would starve the 1.1 GB model load. 2 GiB covers the
# model's ~1.15 GB peak; the kernel's high-RAM enabler makes RAM above the 1 GiB
# linear-map boundary usable for the model's data pages.
DTB="${DTB:-$ROOT/build/virt-2048.dtb}"
DISK="$ROOT/build/base.img"
MODEL_IMG="$ROOT/build/model-gguf.img"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_PORT="${HOST_PORT:-18092}"
INFER_MEM="${INFER_MEM:-2048M}"
# The GGUF path re-dequantizes the whole (compressed) model every token, which is
# heavy under QEMU-TCG (~10 s per forward pass). `n` caps TOTAL positions (prompt
# + generated), so it must exceed the prompt length (~6–7 tokens) to emit any
# generated token; 12 gets a few generated tokens past the prompt ("…Paris").
# The criterion is coherence, not length; a large curl window covers the latency.
GEN_TOKENS="${GEN_TOKENS:-12}"
CURL_TIMEOUT="${CURL_TIMEOUT:-1200}"
PROMPT="${PROMPT:-The capital of France is}"
EXPECT="${EXPECT:-Paris}"

[[ -f "$KERNEL" ]]    || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$MODEL_IMG" ]] || { echo "FAIL: $MODEL_IMG missing (make model-gguf-image)" >&2; exit 2; }
[[ -f "$DISK" ]]      || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-gg.XXXXXX)"
OC="$(mktemp -t swiftos-gg-oc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-gg-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-gg-in.XXXXXX)"; mkfifo "$INFIFO"
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

await "LM3b: model disk mounted read-only at /srv/models" 120 \
  || drive_fail "model disk not mounted at /srv/models"
await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || drive_fail "tty demo did not become ready"
send_line 'tty-line'
await "M7 tty: running; press Ctrl-C" 60 || drive_fail "tty demo did not accept input"
printf '\003' >&3
await "swift-os login:" 120 || drive_fail "login prompt did not appear"
send_line 'root'
await "Password:" 120 || drive_fail "password prompt did not appear"
send_line 'swordfish'
await "M12c: shell ready" 180 || drive_fail "root shell did not start"
send_line '/bin/llmd'
await "llmd: serving from model disk /srv/models" 120 \
  || drive_fail "llmd did not choose the model-disk bundle"
# The 1.1 GB payload is integrity-hashed at startup (kernel + llmd) before serve.
await "llmd: serving on 8080" 1200 || drive_fail "llmd never reported serving (model load/verify too slow?)"

post_ok=0
for _ in 1 2 3; do
  if curl -s -m "$CURL_TIMEOUT" -X POST --data "$PROMPT" \
       "http://127.0.0.1:${HOST_PORT}/completion?n=${GEN_TOKENS}" > "$OC" 2>/dev/null \
     && grep -qF "$EXPECT" "$OC"; then
    post_ok=1; break
  fi
  sleep 1
done
# Give the serving log line time to flush after the response completes.
await "llmd: served " 60 || true
exec 3>&-; stop_qemu; QP=""

CLEAN="$(sed 's/\r//' "$LOG")"
ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

grep -qF "llmd: serving from model disk /srv/models" <<<"$CLEAN" || fail "llmd did not serve from the model disk"
grep -qE "llmd: bundle tinyllama-gguf"               <<<"$CLEAN" || fail "llmd did not select the tinyllama-gguf bundle"
grep -qE "llmd: model GGUF k-quant"                  <<<"$CLEAN" || fail "llmd did not load the GGUF k-quant engine"
[[ "$post_ok" -eq 1 ]]                                            || fail "POST /completion did not return a coherent answer containing '$EXPECT'"
grep -qE "llmd: served [0-9]+ tokens .* rate=[0-9]+ tok/s" <<<"$CLEAN" || fail "llmd did not log a tokens/sec rate"

if (( ok )); then
  rate="$(grep -oE 'rate=[0-9]+ tok/s' <<<"$CLEAN" | tail -1)"
  echo "PASS: TinyLlama Q4_K_M GGUF served from /srv/models (-m $INFER_MEM); coherent answer ('$EXPECT'); $rate"
  echo "  completion: $(sed 's/\r//' "$OC" | tr '\n' ' ')"
  exit 0
fi
echo "--- serial (llmd region) ---" >&2
sed -n '/llmd:/,$p' <<<"$CLEAN" | head -40 >&2
echo "--- completion body ---" >&2; cat "$OC" >&2
exit 1
