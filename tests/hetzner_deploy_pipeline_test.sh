#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# hetzner_deploy_pipeline_test.sh — P1.2 local gate for the deploy build stage.
#
# Verifies hetzner-deploy-build produces a complete public handoff bundle without
# touching a real server. Uses a fixture authorized key for reproducibility.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_DIR="$ROOT/build/hetzner-deploy"
EVIDENCE="$DEPLOY_DIR/evidence"
FIXTURE_KEY="$ROOT/fixtures/ssh/sshd_hc5_ed25519.pub"

fail() { echo "FAIL: $1" >&2; exit 1; }
require_file() { [[ -f "$1" ]] || fail "missing file $1"; }
require_contains() { grep -qF "$2" "$1" || fail "$1 missing: $2"; }

[[ -f "$FIXTURE_KEY" ]] || fail "fixture authorized key missing"

HETZNER_AUTHORIZED_KEYS="$FIXTURE_KEY" \
HETZNER_DEPLOY_DIR="$DEPLOY_DIR" \
HETZNER_EVIDENCE_DIR="$EVIDENCE" \
  "$ROOT/scripts/hetzner-deploy-build.sh" \
  || fail "hetzner-deploy-build failed"

require_file "$DEPLOY_DIR/manifest.txt"
require_file "$DEPLOY_DIR/artifacts-sha256.txt"
require_file "$DEPLOY_DIR/release-manifest.json"
require_file "$ROOT/build/swift-os.img"
require_file "$ROOT/build/hetzner-update-store.img"
require_file "$DEPLOY_DIR/known_hosts"
require_file "$EVIDENCE/manifest.txt"
require_file "$EVIDENCE/secrets-omitted.txt"

require_contains "$DEPLOY_DIR/manifest.txt" "hcloud-prod-supervised"
require_contains "$DEPLOY_DIR/manifest.txt" "hetzner-update-store.img"
require_contains "$DEPLOY_DIR/artifacts-sha256.txt" "swift-os.img"
require_contains "$DEPLOY_DIR/artifacts-sha256.txt" "hetzner-update-store.img"
require_contains "$EVIDENCE/secrets-omitted.txt" "ssh_host_ed25519_seed"

[[ ! -f "$EVIDENCE/ssh_host_ed25519_seed" ]] \
  || fail "private host seed leaked into evidence"

echo "PASS: hetzner deploy pipeline build stage produced a complete public handoff bundle"