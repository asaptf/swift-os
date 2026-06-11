#!/usr/bin/env bash
# ssh_runtime_entropy_test.sh — SSH client KEX uses runtime virtio-rng entropy.
#
# Reuses the outbound OpenSSH transport acceptance path, but attaches a QEMU
# virtio-rng device and requires /bin/ssh to consume SYS_RANDOM-backed entropy
# before completing strict-KEX and encrypted service-request preauth.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SSH_CLIENT_EXPECT_RUNTIME_ENTROPY=1 \
SSH_CLIENT_EXTRA_QEMU_ARGS="-object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-device,rng=rng0" \
  "$ROOT/tests/ssh_transport_test.sh"
