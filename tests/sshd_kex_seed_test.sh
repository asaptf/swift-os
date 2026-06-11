#!/usr/bin/env bash
# sshd_kex_seed_test.sh - SSHD deploy KEX seed provisioning proof.
#
# Builds a temporary signed base image with a generated SSHD KEX seed staged as
# /etc/ssh/ssh_kex_seed, then reuses the SSHD transport acceptance test to prove
# the daemon loads it and completes normal OpenSSH remote exec.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
HOST_PORT="${SSHD_HOST_PORT:-$((30000 + ($$ % 14000)))}"

[[ -f "$ROOT/build/kernel.elf" ]] || { echo "FAIL: build/kernel.elf missing (make build)" >&2; exit 2; }
if [[ ! -x "$SSHKEY" ]]; then
  ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 || { echo "FAIL: cannot build sshkey tool" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-sshd-kex-seed.XXXXXX)"
SEED="$WORK/ssh_kex_seed"
IMG="$WORK/base-sshd-kex-seed.img"
BASE_ROOT="$WORK/base-root"
LOG="$WORK/base-image.log"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

"$SSHKEY" seed --out "$SEED" \
  || { echo "FAIL: could not generate SSHD KEX seed" >&2; exit 2; }

if ! ( cd "$ROOT" && make BASE_IMG="$IMG" BASE_ROOT="$BASE_ROOT" SSHD_KEX_SEED_FILE="$SEED" base-image ) >"$LOG" 2>&1; then
  echo "FAIL: could not build SSHD KEX seed base image" >&2
  cat "$LOG" >&2
  exit 2
fi

SSHD_BASE_IMG="$IMG" \
SSHD_EXPECT_KEX_SEED=1 \
SSHD_HOST_PORT="$HOST_PORT" \
"$ROOT/tests/sshd_transport_test.sh" \
  || { echo "FAIL: SSHD KEX seed image did not pass transport acceptance" >&2; exit 1; }

echo "PASS: SSHD loaded a deploy KEX seed and completed OpenSSH session exec"
