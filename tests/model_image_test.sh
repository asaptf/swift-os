#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# model_image_test.sh — LM3a host acceptance for the packed "model disk".
#
# The model bundle is too big for the RAM-loaded base image and for datafs
# (~4 MiB file cap), so it ships as its own signed SWOSBASE packed read-only
# image (build/model.img), mounted read-only at /srv/models by LM3b and served
# by LM3c. This host check verifies the image was built correctly — without
# QEMU — by asserting it is a valid SWOSBASE packed FS that carries the model
# bundle entries and the provenance sentinel. The Ed25519 signature is verified
# by the kernel at mount time (LM3c), the same way the base image is.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="$ROOT/build/model.img"
SENTINEL="SWOS-MODEL-DISK-v1"

[[ -f "$IMG" ]] || { echo "FAIL: $IMG missing (make model-image)" >&2; exit 2; }

ok=1
fail() { echo "FAIL: $1" >&2; ok=0; }

# 1. Sector-0 magic identifies it as a packed SWOSBASE image the kernel mounts.
magic="$(dd if="$IMG" bs=1 count=8 2>/dev/null)"
[[ "$magic" == "SWOSBASE" ]] || fail "sector-0 magic is '$magic', expected SWOSBASE"

# 2. Big enough to actually hold the 17 MB model.bin (proves it's not empty and
#    that the packed FS has no ~4 MiB datafs-style cap).
size="$(wc -c < "$IMG")"
if (( size < 17000000 )); then
  fail "image is only $size bytes; expected >= ~17 MB (the model payload)"
else
  echo "  model.img size: $size bytes"
fi

# 3. The packed string table carries the bundle entry names + the sentinel.
for needle in "$SENTINEL" "stories15M" "model.bin" "tokenizer.bin" "manifest.toml" "MODEL-DISK-ID"; do
  if grep -qa -- "$needle" "$IMG"; then
    echo "  found: $needle"
  else
    fail "model image is missing the entry/marker '$needle'"
  fi
done

if (( ok )); then
  echo "PASS: build/model.img is a valid signed SWOSBASE model disk (bundle + sentinel present)"
  exit 0
fi
exit 1
