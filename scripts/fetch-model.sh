#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# fetch-model.sh — fetch the tiny TinyStories test checkpoint (stories260K) and
# tokenizer (tok512) used by the swift-os inference engine: the host TDD test
# (tests/llm_engine_test.swift) and the /bin/llm demo. These are small,
# permissively published test artifacts from Andrej Karpathy's llama2.c /
# tinyllamas. They are fetched on demand and kept out of git (see .gitignore),
# the same way the newlib sysroot and busybox sources are.
#
# Idempotent: re-running is a no-op when the files are already present and large
# enough, so it is safe to depend on from `make test` without re-downloading.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)/models"
HF="${MODEL_HF_BASE:-https://huggingface.co/karpathy/tinyllamas/resolve/main}"
GH="${MODEL_GH_BASE:-https://raw.githubusercontent.com/karpathy/llama2.c/master}"
mkdir -p "$DIR"

fetch() { # name min_bytes url
    local name="$1" min="$2" url="$3" path="$DIR/$1"
    if [ -f "$path" ] && [ "$(wc -c < "$path")" -ge "$min" ]; then
        echo "have $name ($(wc -c < "$path") bytes)"
        return 0
    fi
    echo "fetching $name ..."
    curl -fL --retry 3 --max-time 600 -o "$path" "$url"
    if [ "$(wc -c < "$path")" -lt "$min" ]; then
        echo "error: $name is smaller than expected ($min bytes)" >&2
        exit 1
    fi
}

# Tiny test checkpoint + its 512-entry tokenizer (I0/I1 goldens).
fetch stories260K.bin 1000000 "$HF/stories260K/stories260K.bin"
fetch tok512.bin 6000 "$HF/stories260K/tok512.bin"
# The served model (I4): stories15M + the full 32000-entry Llama-2 tokenizer.
fetch stories15M.bin 60000000 "$HF/stories15M.bin"
fetch tokenizer.bin 400000 "$GH/tokenizer.bin"
echo "model fetch OK -> $DIR"
