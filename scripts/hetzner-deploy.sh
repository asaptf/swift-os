#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hetzner deploy pipeline orchestrator (P1.2).
#
#   ./scripts/hetzner-deploy.sh build      # build candidate + evidence
#   ./scripts/hetzner-deploy.sh preflight  # build + local QEMU regression
#   ./scripts/hetzner-deploy.sh health     # SSH health on live SwiftOS
#   HETZNER_CONFIRM=1 ./scripts/hetzner-deploy.sh promote
#   HETZNER_CONFIRM=1 ./scripts/hetzner-deploy.sh rollback
#
# Configure via build/hetzner-deploy/deploy.env (see fixtures/hetzner/deploy.env.example).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="${1:-}"
shift || true

usage() {
  cat <<'EOF'
Usage: hetzner-deploy.sh <command>

Commands:
  build       Build deploy candidate (disk + manifest + evidence)
  preflight   build + make hetzner-deploy-test (local QEMU gate)
  health      SSH health check against HETZNER_HOST (SwiftOS)
  promote     Upload, flash, reboot, health (needs HETZNER_CONFIRM=1)
  rollback    Flash saved remote rollback image (needs HETZNER_CONFIRM=1)
EOF
}

case "$CMD" in
  build)
    exec "$ROOT/scripts/hetzner-deploy-build.sh" "$@"
    ;;
  preflight)
    "$ROOT/scripts/hetzner-deploy-build.sh"
    "$ROOT/tests/hetzner_deploy_test.sh"
    ;;
  health)
    exec "$ROOT/scripts/hetzner-deploy-health.sh" "$@"
    ;;
  promote)
    exec "$ROOT/scripts/hetzner-deploy-promote.sh" "$@"
    ;;
  rollback)
    # shellcheck source=scripts/hetzner-deploy-common.sh
    source "$ROOT/scripts/hetzner-deploy-common.sh"
    hetzner_deploy_load_env "$ROOT"
    [[ "${HETZNER_CONFIRM:-0}" == "1" ]] || { echo "FAIL: set HETZNER_CONFIRM=1" >&2; exit 2; }
    [[ -n "$HETZNER_HOST" ]] || { echo "FAIL: HETZNER_HOST not set" >&2; exit 2; }
    rollback="${HETZNER_REMOTE_IMAGE}.rollback"
    hetzner_deploy_ssh_linux "test -f '$rollback'" \
      || { echo "FAIL: no remote rollback at $rollback" >&2; exit 2; }
    hetzner_deploy_ssh_linux \
      "dd if='$rollback' of='$HETZNER_DISK' bs=4M conv=fsync status=none && sync && (reboot -nf || echo b > /proc/sysrq-trigger)" \
      || true
    sleep 15
    exec "$ROOT/scripts/hetzner-deploy-health.sh"
    ;;
  ""|help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    usage >&2
    exit 2
    ;;
esac