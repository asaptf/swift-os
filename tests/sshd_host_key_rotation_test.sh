#!/usr/bin/env bash
# sshd_host_key_rotation_test.sh - SSHD deploy host-key seed rotation proof.
#
# Builds a temporary signed base image with a generated SSHD host-key seed,
# derives the matching OpenSSH known_hosts entry, and reuses the SSHD transport
# acceptance test to prove that host OpenSSH pins the rotated key.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
BASE_SEED="$ROOT/base/etc/ssh/ssh_host_ed25519_seed"
HOST_PORT="${SSHD_HOST_PORT:-$((26000 + ($$ % 18000)))}"

[[ -f "$ROOT/build/kernel.elf" ]] || { echo "FAIL: build/kernel.elf missing (make build)" >&2; exit 2; }
[[ -f "$BASE_SEED" ]] || { echo "FAIL: $BASE_SEED missing" >&2; exit 2; }
if [[ ! -x "$SSHKEY" ]]; then
  ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 || { echo "FAIL: cannot build sshkey tool" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-sshd-key-rotate.XXXXXX)"
SEED="$WORK/ssh_host_ed25519_seed"
IMG="$WORK/base-sshd-rotated.img"
BASE_ROOT="$WORK/base-root"
LOG="$WORK/base-image.log"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

"$SSHKEY" seed --out "$SEED" \
  || { echo "FAIL: could not generate rotated SSHD host-key seed" >&2; exit 2; }

base_pub="$("$SSHKEY" pubkey --seed-file "$BASE_SEED")" \
  || { echo "FAIL: could not derive default SSHD public key" >&2; exit 2; }
rotated_pub="$("$SSHKEY" pubkey --seed-file "$SEED")" \
  || { echo "FAIL: could not derive rotated SSHD public key" >&2; exit 2; }
if [[ "$base_pub" == "$rotated_pub" ]]; then
  echo "FAIL: generated SSHD host-key seed matched the default public key" >&2
  exit 2
fi

if ! ( cd "$ROOT" && make BASE_IMG="$IMG" BASE_ROOT="$BASE_ROOT" SSHD_HOST_SEED_FILE="$SEED" base-image ) >"$LOG" 2>&1; then
  echo "FAIL: could not build rotated SSHD base image" >&2
  cat "$LOG" >&2
  exit 2
fi

SSHD_BASE_IMG="$IMG" \
SSHD_HOST_SEED_SRC="$SEED" \
SSHD_HOST_PORT="$HOST_PORT" \
"$ROOT/tests/sshd_transport_test.sh" \
  || { echo "FAIL: rotated SSHD host-key image did not pass transport acceptance" >&2; exit 1; }

echo "PASS: SSHD host-key seed rotation built a custom base image and pinned the rotated key"
