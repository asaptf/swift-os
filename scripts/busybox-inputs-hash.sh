#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# busybox-inputs-hash.sh — compatibility wrapper around artifact-inputs-hash.sh
# for the busybox artifact. Prefer:
#   ./scripts/artifact-inputs-hash.sh busybox [--list|--check]
#
# Kept so existing Makefile / CI / build-busybox.sh call sites keep working.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/artifact-inputs-hash.sh" busybox "$@"
