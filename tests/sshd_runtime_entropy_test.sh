#!/usr/bin/env bash
# sshd_runtime_entropy_test.sh — SSHD KEX uses runtime virtio-rng entropy.
#
# Reuses the full OpenSSH remote-command acceptance path, but attaches a QEMU
# virtio-rng device and requires the guest to surface SYS_RANDOM-backed entropy
# before marking SSHD's KEX context as runtime-seeded.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SSHD_EXPECT_RUNTIME_ENTROPY=1 \
SSHD_EXTRA_QEMU_ARGS="-object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0" \
  "$ROOT/tests/sshd_transport_test.sh"
