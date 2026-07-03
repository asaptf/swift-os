#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Upload a deploy candidate, flash the boot disk, reboot, and verify health.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/hetzner-deploy-common.sh
source "$ROOT/scripts/hetzner-deploy-common.sh"
hetzner_deploy_load_env "$ROOT"

[[ -n "$HETZNER_HOST" ]] || { echo "FAIL: HETZNER_HOST not set" >&2; exit 2; }
[[ "${HETZNER_CONFIRM:-0}" == "1" ]] || {
  echo "FAIL: destructive promote requires HETZNER_CONFIRM=1" >&2
  exit 2
}

hetzner_deploy_require_file "$DISK_IMG" "disk image missing — run hetzner-deploy-build"
hetzner_deploy_require_file "$HETZNER_SSH_IDENTITY" "SSH identity missing"

local_sha="$(hetzner_deploy_sha256_file "$DISK_IMG")"
echo "==> uploading $DISK_IMG ($local_sha)"

hetzner_deploy_ssh_linux "mkdir -p $(dirname "$HETZNER_REMOTE_IMAGE")"
scp -P "$HETZNER_SSH_PORT" -i "$HETZNER_SSH_IDENTITY" "$DISK_IMG" \
  "$(hetzner_deploy_ssh_target):$HETZNER_REMOTE_IMAGE"

remote_sha="$(hetzner_deploy_ssh_linux "sha256sum '$HETZNER_REMOTE_IMAGE' | awk '{print \$1}'")"
[[ "$remote_sha" == "$local_sha" ]] || {
  echo "FAIL: remote sha256 mismatch (local=$local_sha remote=$remote_sha)" >&2
  exit 1
}

echo "==> backing up previous remote image (best effort)"
hetzner_deploy_ssh_linux \
  "test -f '$HETZNER_REMOTE_IMAGE' && cp '$HETZNER_REMOTE_IMAGE' '${HETZNER_REMOTE_IMAGE}.rollback' || true"

echo "==> flashing $HETZNER_DISK (this replaces the running OS disk)"
hetzner_deploy_ssh_linux \
  "dd if='$HETZNER_REMOTE_IMAGE' of='$HETZNER_DISK' bs=4M conv=fsync status=none && sync && echo DD-OK-REBOOTING && (reboot -nf || echo b > /proc/sysrq-trigger)" \
  || true

echo "==> waiting for reboot + SwiftOS health"
sleep 15
"$ROOT/scripts/hetzner-deploy-health.sh"

cat >"$DEPLOY_DIR/promotion.txt" <<EOF
promoted_at: $(date -u +%FT%TZ)
host: $HETZNER_HOST
disk: $HETZNER_DISK
image: $DISK_IMG
sha256: $local_sha
rollback_remote: ${HETZNER_REMOTE_IMAGE}.rollback
EOF
cp "$DEPLOY_DIR/promotion.txt" "$HETZNER_EVIDENCE_DIR/promotion.txt"

echo "hetzner-deploy-promote: OK"