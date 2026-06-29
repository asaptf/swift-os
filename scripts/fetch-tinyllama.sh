#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# fetch-tinyllama.sh — fetch + convert TinyLlama-1.1B-Chat to the swift-os
# inference engine's legacy fp32 .bin + tokenizer.bin (LM4a). The Swift
# quantizer (tools/quantize.swift) then turns the fp32 file into the served v2
# Q8 checkpoint.
#
# This is host build tooling, like scripts/fetch-model.sh. It is Python-backed
# (scripts/convert-tinyllama.py) because reading a Hugging Face checkpoint and
# undoing its RoPE weight permutation needs the PyTorch/transformers stack,
# which has no Swift binding. The conversion is GQA-correct (TinyLlama has 32
# attention heads but 4 KV heads), unlike Karpathy's upstream export.py.
#
# The model (~1.1 GB Q8, ~4.4 GB fp32 intermediate) and the venv are kept out of
# git (see .gitignore: /models/). A self-contained venv is provisioned under
# models/lm4venv on first run (torch + transformers + sentencepiece + hub),
# ~5 GB of downloads. Idempotent: re-running is a no-op when the outputs already
# exist and are large enough, so it is safe to depend on from a make rule.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/models"
VENV="$DIR/lm4venv"
MODEL_ID="${TINYLLAMA_HF_ID:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}"
FP32="$DIR/tinyllama-fp32.bin"
TOK="$DIR/tinyllama-tokenizer.bin"
PY="${PYTHON:-python3}"

mkdir -p "$DIR"

# Idempotent: both artifacts present and plausibly complete -> done.
if [ -f "$FP32" ] && [ "$(wc -c < "$FP32")" -ge 4000000000 ] \
   && [ -f "$TOK" ] && [ "$(wc -c < "$TOK")" -ge 400000 ]; then
    echo "have tinyllama fp32 + tokenizer ($(wc -c < "$FP32") bytes)"
    exit 0
fi

if [ ! -x "$VENV/bin/python" ]; then
    echo "fetch-tinyllama: provisioning venv at $VENV ..."
    "$PY" -m venv "$VENV"
    "$VENV/bin/pip" install --upgrade pip -q
    "$VENV/bin/pip" install -q torch transformers sentencepiece huggingface_hub safetensors numpy
fi

echo "fetch-tinyllama: converting $MODEL_ID ..."
"$VENV/bin/python" "$ROOT/scripts/convert-tinyllama.py" "$MODEL_ID" "$FP32" "$TOK"
echo "fetch-tinyllama OK -> $FP32 + $TOK"
