#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# fetch-tinyllama-gguf.sh — fetch a pre-quantized TinyLlama-1.1B-Chat GGUF
# (Q4_K_M) for the swift-os inference engine (LM5). LM5 is about *reading* the
# mainstream GGUF / k-quant format, not producing it, so we pull a ready file
# (like scripts/fetch-model.sh pulls the stories checkpoints). ~640 MB, kept out
# of git (see .gitignore: /models/). Idempotent: a no-op when already present.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)/models"
OUT="$DIR/tinyllama-q4km.gguf"
URL="${TINYLLAMA_GGUF_URL:-https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf}"
mkdir -p "$DIR"

if [ -f "$OUT" ] && [ "$(wc -c < "$OUT")" -ge 600000000 ]; then
    echo "have tinyllama-q4km.gguf ($(wc -c < "$OUT") bytes)"
    exit 0
fi
echo "fetching TinyLlama Q4_K_M GGUF ..."
curl -fL --retry 3 --max-time 1200 -o "$OUT" "$URL"
if [ "$(wc -c < "$OUT")" -lt 600000000 ]; then
    echo "error: gguf smaller than expected" >&2; exit 1
fi
echo "gguf fetch OK -> $OUT"
