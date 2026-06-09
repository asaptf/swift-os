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
BASE="${MODEL_BASE_URL:-https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K}"
mkdir -p "$DIR"

fetch() { # name min_bytes
    local name="$1" min="$2" path="$DIR/$1"
    if [ -f "$path" ] && [ "$(wc -c < "$path")" -ge "$min" ]; then
        echo "have $name ($(wc -c < "$path") bytes)"
        return 0
    fi
    echo "fetching $name ..."
    curl -fL --retry 3 --max-time 120 -o "$path" "$BASE/$name"
    if [ "$(wc -c < "$path")" -lt "$min" ]; then
        echo "error: $name is smaller than expected ($min bytes)" >&2
        exit 1
    fi
}

fetch stories260K.bin 1000000
fetch tok512.bin 6000
echo "model fetch OK -> $DIR"
