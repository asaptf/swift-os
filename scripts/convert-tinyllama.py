# SPDX-License-Identifier: Apache-2.0
#
# convert-tinyllama.py — host-side HF -> llama2.c v0 (legacy fp32) converter for
# the swift-os inference engine (LM4a).
#
# Why Python (not Swift, the project default): the only way to read a Hugging
# Face Llama checkpoint and undo its RoPE weight permutation is the PyTorch /
# transformers stack, which has no Swift binding. This is host build tooling
# (like scripts/fetch-model.sh, which is shell), not OS code. The OS-side
# quantization stays in the tested Swift tool (tools/quantize.swift): this
# script only emits the legacy fp32 .bin that quantizer already consumes.
#
# Karpathy's own export.py `load_hf_model` is WRONG for a grouped-query model
# such as TinyLlama-1.1B (32 attention heads, 4 KV heads): it hard-codes
# n_kv_heads = n_attention_heads and calls permute_reverse with full-dim
# defaults, which mangles wk. This converter applies the RoPE un-permutation
# with the correct per-projection head count and dims, so the GQA weights come
# out in the exact layout runq.c / the swift-os engine expect.
#
# Output is the legacy "v0" format (28-byte 7-int header) that tools/quantize.swift
# reads; the freq_cis tables it writes are zero-filled because both runq.c-style
# quantization and the swift-os engine recompute RoPE on the fly (base 10000) and
# never read them — only their byte length matters so downstream offsets line up.
#
# Usage: convert-tinyllama.py <hf-model-id-or-path> <out-fp32.bin> <out-tokenizer.bin>

import sys
import struct

import torch
from transformers import AutoModelForCausalLM


def die(msg):
    sys.stderr.write("convert-tinyllama: " + msg + "\n")
    sys.exit(1)


if len(sys.argv) != 4:
    die("usage: convert-tinyllama.py <hf-model> <out-fp32.bin> <out-tokenizer.bin>")

model_id = sys.argv[1]
out_path = sys.argv[2]
tok_path = sys.argv[3]

print(f"convert-tinyllama: loading {model_id} (fp32) ...", flush=True)
hf = AutoModelForCausalLM.from_pretrained(model_id, torch_dtype=torch.float32)
hf.eval()
cfg = hf.config
sd = hf.state_dict()

dim = cfg.hidden_size
n_layers = cfg.num_hidden_layers
n_heads = cfg.num_attention_heads
n_kv_heads = getattr(cfg, "num_key_value_heads", n_heads)
vocab = cfg.vocab_size
hidden = cfg.intermediate_size
max_seq_len = cfg.max_position_embeddings
head_size = dim // n_heads
kv_dim = n_kv_heads * head_size

shared = torch.equal(sd["model.embed_tokens.weight"], sd["lm_head.weight"])
print(
    f"convert-tinyllama: dim={dim} hidden={hidden} layers={n_layers} "
    f"heads={n_heads} kv_heads={n_kv_heads} vocab={vocab} seq={max_seq_len} "
    f"head_size={head_size} kv_dim={kv_dim} shared_classifier={shared}",
    flush=True,
)


# HF stores wq/wk permuted for its split-half RoPE; reverse it so the layout is
# the interleaved-pair layout llama2.c uses. `heads`/`d1` must match the
# projection: for wq that is (n_heads, dim); for a GQA wk it is (n_kv_heads, kv_dim).
def permute_reverse(w, heads, d1, d2):
    return w.view(heads, 2, d1 // heads // 2, d2).transpose(1, 2).reshape(d1, d2)


def w(name):
    return sd[name].to(torch.float32).contiguous()


out = open(out_path, "wb")


def write_fp32(t):
    # little-endian float32, row-major — matches serialize_fp32 in export.py
    out.write(t.detach().to(torch.float32).numpy().astype("<f4").tobytes())


# Header: 7 int32. Negative vocab signals a non-shared classifier (llama2.c
# convention that quantize.swift / the engine decode).
hdr_vocab = vocab if shared else -vocab
out.write(struct.pack("iiiiiii", dim, hidden, n_layers, n_heads,
                       n_kv_heads, hdr_vocab, max_seq_len))

# Token embeddings.
write_fp32(w("model.embed_tokens.weight"))

# Attention block, grouped by tensor across all layers (legacy_export order).
for i in range(n_layers):
    write_fp32(w(f"model.layers.{i}.input_layernorm.weight"))
for i in range(n_layers):
    write_fp32(permute_reverse(w(f"model.layers.{i}.self_attn.q_proj.weight"),
                               n_heads, dim, dim))
for i in range(n_layers):
    write_fp32(permute_reverse(w(f"model.layers.{i}.self_attn.k_proj.weight"),
                               n_kv_heads, kv_dim, dim))
for i in range(n_layers):
    write_fp32(w(f"model.layers.{i}.self_attn.v_proj.weight"))
for i in range(n_layers):
    write_fp32(w(f"model.layers.{i}.self_attn.o_proj.weight"))

# FFN block.
for i in range(n_layers):
    write_fp32(w(f"model.layers.{i}.post_attention_layernorm.weight"))
for i in range(n_layers):
    write_fp32(w(f"model.layers.{i}.mlp.gate_proj.weight"))   # w1
for i in range(n_layers):
    write_fp32(w(f"model.layers.{i}.mlp.down_proj.weight"))   # w2
for i in range(n_layers):
    write_fp32(w(f"model.layers.{i}.mlp.up_proj.weight"))     # w3

# Final norm.
write_fp32(w("model.norm.weight"))

# Legacy freq_cis tables: written zero-filled (see header comment). Lengths must
# equal seq_len * (head_size/2) each so quantize.swift's skip math is exact.
freq_floats = max_seq_len * (head_size // 2)
zeros = torch.zeros(freq_floats, dtype=torch.float32)
write_fp32(zeros)   # freq_cis_real
write_fp32(zeros)   # freq_cis_imag

# Classifier (only when not tied to the embeddings).
if not shared:
    write_fp32(w("lm_head.weight"))

out.close()
import os
print(f"convert-tinyllama: wrote {out_path} ({os.path.getsize(out_path)} bytes)", flush=True)

# ---- tokenizer.bin (Karpathy llama2.c format) --------------------------------
# TinyLlama uses the stock Llama-2 32k SentencePiece tokenizer; we export from
# the model's own tokenizer.model (loaded with the SentencePiece library, not
# the HF fast tokenizer) so the bundle is self-consistent and matches the byte
# layout the swift-os LlamaTokenizer reads.
print("convert-tinyllama: exporting tokenizer ...", flush=True)
import sentencepiece as spm
import os.path as _osp

if _osp.isfile(_osp.join(model_id, "tokenizer.model")):
    spm_path = _osp.join(model_id, "tokenizer.model")
else:
    from huggingface_hub import hf_hub_download
    spm_path = hf_hub_download(repo_id=model_id, filename="tokenizer.model")

sp = spm.SentencePieceProcessor(model_file=spm_path)
n_words = sp.get_piece_size()
bos_id = sp.bos_id()
eos_id = sp.eos_id()

tokens, scores = [], []
for i in range(n_words):
    t = sp.id_to_piece(i)
    s = sp.get_score(i)
    if i == bos_id:
        t = "\n<s>\n"
    elif i == eos_id:
        t = "\n</s>\n"
    t = t.replace("▁", " ")   # SentencePiece whitespace marker -> space
    b = t.encode("utf-8")
    tokens.append(b)
    scores.append(s)

max_token_length = max(len(b) for b in tokens)
with open(tok_path, "wb") as f:
    f.write(struct.pack("I", max_token_length))
    for b, s in zip(tokens, scores):
        f.write(struct.pack("fI", s, len(b)))
        f.write(b)
print(f"convert-tinyllama: wrote {tok_path} ({n_words} tokens, "
      f"max_token_length={max_token_length})", flush=True)
