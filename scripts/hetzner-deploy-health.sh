#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Health-check a Hetzner target after promote (or an existing SwiftOS server).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/hetzner-deploy-common.sh
source "$ROOT/scripts/hetzner-deploy-common.sh"
hetzner_deploy_load_env "$ROOT"

[[ -n "$HETZNER_HOST" ]] || { echo "FAIL: HETZNER_HOST not set" >&2; exit 2; }
hetzner_deploy_require_file "$HETZNER_KNOWN_HOSTS" "known_hosts missing — run hetzner-deploy-build first"
hetzner_deploy_require_file "$HETZNER_SSH_IDENTITY" "SSH identity missing"

TIMEOUT="${HETZNER_HEALTH_TIMEOUT:-180}"
INTERVAL="${HETZNER_HEALTH_INTERVAL:-5}"
deadline=$((SECONDS + TIMEOUT))

echo "==> waiting for SSH on $HETZNER_HOST:$HETZNER_SSH_PORT (mode=$HETZNER_TARGET_MODE)"
ready=0
while (( SECONDS < deadline )); do
  if hetzner_deploy_ssh_swiftos /bin/echo HC-HEALTH-PING >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep "$INTERVAL"
done
if [[ "$ready" -ne 1 ]]; then
  echo "FAIL: SSH health ping timed out after ${TIMEOUT}s" >&2
  exit 1
fi

ID_OUT="$(mktemp -t swiftos-hc-id.XXXXXX)"
NET_OUT="$(mktemp -t swiftos-hc-net.XXXXXX)"
trap 'rm -f "$ID_OUT" "$NET_OUT"' EXIT

hetzner_deploy_ssh_swiftos /bin/id >"$ID_OUT"
hetzner_deploy_ssh_swiftos /bin/netinfo >"$NET_OUT"

grep -qF 'principal=1(root)' "$ID_OUT" \
  || { echo "FAIL: /bin/id missing principal=1(root)" >&2; cat "$ID_OUT" >&2; exit 1; }

grep -qE 'ready (yes|true)' "$NET_OUT" \
  || { echo "FAIL: /bin/netinfo not ready" >&2; cat "$NET_OUT" >&2; exit 1; }

{
  echo "timestamp: $(date -u +%FT%TZ)"
  echo "host: $HETZNER_HOST"
  echo "result: pass"
  echo "checks:"
  echo "  - /bin/echo HC-HEALTH-PING"
  echo "  - /bin/id principal=1(root)"
  echo "  - /bin/netinfo ready"
  echo "--- /bin/id ---"
  cat "$ID_OUT"
  echo "--- /bin/netinfo ---"
  cat "$NET_OUT"
} | tee "$DEPLOY_DIR/health.txt"

mkdir -p "$HETZNER_EVIDENCE_DIR"
cp "$DEPLOY_DIR/health.txt" "$HETZNER_EVIDENCE_DIR/health.txt"

echo "hetzner-deploy-health: OK"