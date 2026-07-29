#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# llm_chat_test.sh — LM6b acceptance: the chat template + sampler served over HTTP.
#
# Boots the inference profile with the Q8 TinyLlama model disk (build/model-tinyllama.img,
# faster per token than the GGUF path), the base disk, and a slirp NIC. Logs in,
# starts /bin/llmd, and asserts:
#   - llmd serves the tinyllama bundle from /srv/models;
#   - POST /chat (with ?temp/&top_k/&top_p/&seed sampling params) wraps the body in
#     the TinyLlama chat template and returns a sampled, on-answer reply — for
#     "What is the capital of France?" the reply contains "<|assistant|>" and
#     "Paris" — and llmd logs a tokens/sec rate.
# A low temperature + fixed seed keep this factual question reproducible.
#
# 1.1B params single-core under QEMU-TCG is slow, and the kernel + llmd each hash
# the 1.1 GB payload once at startup (integrity), so the timeouts here are large
# on purpose; the criterion is coherence, not an exact reference match.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib/timeouts.sh
source "$ROOT/tests/lib/timeouts.sh"
SEND_CHAR_DELAY="${SLEEP_CHAR_DELAY:-0.01}"
SEND_SEND_DELAY="${SLEEP_SEND_DELAY:-0.08}"
# shellcheck source=tests/lib/send_line.sh
source "$ROOT/tests/lib/send_line.sh"
KERNEL="$ROOT/build/kernel.elf"
# The kernel sizes RAM from the DTB's /memory node, so the inference profile
# needs a DTB that advertises the larger window (the 2 GiB one) to match -m;
# the default 256 MiB DTB would starve the 1.1 GB model load. 2 GiB covers the
# model's ~1.15 GB peak; the kernel's high-RAM enabler makes RAM above the 1 GiB
# linear-map boundary usable for the model's data pages.
DTB="${DTB:-$ROOT/build/virt-2048.dtb}"
DISK="$ROOT/build/base.img"
MODEL_IMG="$ROOT/build/model-tinyllama.img"
QEMU="${QEMU:-qemu-system-aarch64}"
HOST_PORT="${HOST_PORT:-18093}"
INFER_MEM="${INFER_MEM:-2048M}"
# LM6b: exercise POST /chat (chat template + sampling). A low temperature + fixed
# seed keeps a factual question reproducible and on-answer. n caps total positions
# (chat template ~22 tokens + generated), so it must comfortably exceed the prompt.
GEN_TOKENS="${GEN_TOKENS:-48}"
SAMPLE_Q="${SAMPLE_Q:-temp=0.3&top_k=40&top_p=0.9&seed=7}"
PROMPT="${PROMPT:-What is the capital of France?}"
EXPECT="${EXPECT:-Paris}"

[[ -f "$KERNEL" ]]    || { echo "FAIL: $KERNEL missing (make build)" >&2; exit 2; }
[[ -f "$MODEL_IMG" ]] || { echo "FAIL: $MODEL_IMG missing (make model-tinyllama-image)" >&2; exit 2; }
[[ -f "$DISK" ]]      || { echo "FAIL: $DISK missing (make base-image)" >&2; exit 2; }

LOG="$(mktemp -t swiftos-chat.XXXXXX)"
OC="$(mktemp -t swiftos-chat-oc.XXXXXX)"
PIDFILE="$(mktemp -t swiftos-chat-pid.XXXXXX)"
INFIFO="$(mktemp -u -t swiftos-chat-in.XXXXXX)"; mkfifo "$INFIFO"
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
await_shell_ready "$LOG" 60 || drive_fail "guest shell not reading after login"
send_line '/bin/llmd'
await "llmd: serving from model disk /srv/models" 120 \
  || drive_fail "llmd did not choose the model-disk bundle"
# The 1.1 GB payload is integrity-hashed at startup (kernel + llmd) before serve.
await "llmd: serving on 8080" 1200 || drive_fail "llmd never reported serving (model load/verify too slow?)"

post_ok=0
for _ in 1 2 3; do
  if curl -s -m 600 -X POST --data "$PROMPT" \
       "http://127.0.0.1:${HOST_PORT}/chat?n=${GEN_TOKENS}&${SAMPLE_Q}" > "$OC" 2>/dev/null \
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
grep -qE "llmd: bundle tinyllama"                    <<<"$CLEAN" || fail "llmd did not select the tinyllama bundle"
[[ "$post_ok" -eq 1 ]]                                            || fail "POST /chat did not return a coherent reply containing '$EXPECT'"
# The reply must include the assistant marker (chat template applied) + the answer.
grep -qF "<|assistant|>" "$OC"                                    || fail "chat reply missing the <|assistant|> marker (template not applied)"
grep -qE "llmd: served [0-9]+ tokens .* rate=[0-9]+ tok/s" <<<"$CLEAN" || fail "llmd did not log a tokens/sec rate"

if (( ok )); then
  rate="$(grep -oE 'rate=[0-9]+ tok/s' <<<"$CLEAN" | tail -1)"
  echo "PASS: TinyLlama /chat sampled reply from /srv/models (-m $INFER_MEM); on-answer ('$EXPECT'); $rate"
  echo "  reply: $(sed 's/\r//' "$OC" | tr '\n' ' ')"
  exit 0
fi
echo "--- serial (llmd region) ---" >&2
sed -n '/llmd:/,$p' <<<"$CLEAN" | head -40 >&2
echo "--- chat reply body ---" >&2; cat "$OC" >&2
exit 1
