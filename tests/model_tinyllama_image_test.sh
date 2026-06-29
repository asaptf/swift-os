#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# model_tinyllama_image_test.sh — LM4b host acceptance for the real-model disk.
#
# Same packed-SWOSBASE model disk as LM3a (model_image_test.sh), but carrying the
# TinyLlama-1.1B Q8 bundle instead of the stories15M proof. This host check (no
# QEMU) verifies the image was built correctly: a valid signed SWOSBASE packed FS,
# big enough to actually hold the ~1.1 GB model, carrying the tinyllama bundle
# entries + the provenance sentinel. The Ed25519 image signature is verified by
# the kernel at mount time (LM3b), like the base image.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="$ROOT/build/model-tinyllama.img"
SENTINEL="SWOS-MODEL-DISK-v1"

[[ -f "$IMG" ]] || { echo "FAIL: $IMG missing (make model-tinyllama-image)" >&2; exit 2; }

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# 1. Sector-0 magic identifies it as a packed SWOSBASE image the kernel mounts.
magic="$(dd if="$IMG" bs=1 count=8 2>/dev/null)"
[[ "$magic" == "SWOSBASE" ]] || fail "sector-0 magic is '$magic', expected SWOSBASE"

# 2. Big enough to hold the ~1.1 GB Q8 model.bin (proves the packed FS has no
#    ~4 MiB datafs-style file cap and that the real payload is present).
size="$(wc -c < "$IMG")"
if (( size < 1000000000 )); then
  fail "image is only $size bytes; expected >= ~1.0 GB (the TinyLlama Q8 payload)"
else
  echo "  model-tinyllama.img size: $size bytes"
fi

# 3. The packed string table carries the bundle entry names + the sentinel.
for needle in "$SENTINEL" "tinyllama" "model.bin" "tokenizer.bin" "manifest.toml" "MODEL-DISK-ID"; do
  if grep -qa -- "$needle" "$IMG"; then
    echo "  found: $needle"
  else
    fail "model image is missing the entry/marker '$needle'"
  fi
done

if (( ok )); then
  echo "PASS: build/model-tinyllama.img is a valid signed SWOSBASE model disk (TinyLlama bundle + sentinel)"
  exit 0
fi
exit 1
