#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# gguf_dump_test.sh — LM5a acceptance: the shared GGUF reader (userland/lib/gguf.swift)
# parses a real TinyLlama-1.1B-Chat Q4_K_M GGUF — header, llama hyperparameters,
# tokenizer summary, and the tensor table with ggml quant types. No QEMU.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/ggufdump"
GGUF="$ROOT/models/tinyllama-q4km.gguf"

[[ -x "$DUMP" ]] || { echo "FAIL: $DUMP missing (make ggufdump)" >&2; exit 2; }
[[ -f "$GGUF" ]] || { echo "FAIL: $GGUF missing (make tinyllama-gguf)" >&2; exit 2; }

out="$("$DUMP" "$GGUF")" || { echo "FAIL: ggufdump errored" >&2; echo "$out" >&2; exit 1; }

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }
check() { grep -qE -- "$1" <<<"$out" || fail "expected /$1/ in dump"; }

check 'version 3, 201 tensors'
check '^arch: llama'
check 'dim=2048 hidden=5632 layers=22 heads=32 kv=4 ctx=2048'
check 'tokenizer: model=llama tokens=32000 bos=1 eos=2'
# The Q4_K_M mix: 4-bit k-quant weights, 6-bit k-quant for the sensitive tensors,
# fp32 norms. Proves the tensor table + ggml types decode.
check 'token_embd.weight  \[2048x32000\]  Q4_K'
check 'output.weight  \[2048x32000\]  Q6_K'
check 'blk.0.attn_v.weight  \[2048x256\]  Q6_K'
check 'type histogram: F32=45 Q4_K=135 Q6_K=21'

if (( ok )); then
  echo "PASS: GGUF reader parses TinyLlama Q4_K_M (header + hyperparams + tokenizer + tensor types)"
  exit 0
fi
echo "--- dump ---" >&2; echo "$out" >&2
exit 1
