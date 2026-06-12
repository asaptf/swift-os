#!/usr/bin/env bash
# hetzner_deploy_bundle_test.sh - HC31 Hetzner deploy evidence bundle proof.
#
# Runs the SSHD static-IPv6 deploy preflight with evidence capture enabled and
# verifies that the resulting handoff bundle contains the public, reproducible
# deployment records while omitting private deploy seed material.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t swiftos-hcloud-bundle.XXXXXX)"
EVIDENCE="$WORK/evidence"
OUT="$WORK/preflight.out"
ERR="$WORK/preflight.err"

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  echo "--- preflight stdout ---" >&2
  cat "$OUT" >&2 2>/dev/null || true
  echo "--- preflight stderr ---" >&2
  cat "$ERR" >&2 2>/dev/null || true
  if [[ -d "$EVIDENCE" ]]; then
    echo "--- evidence files ---" >&2
    find "$EVIDENCE" -maxdepth 1 -type f -print | sort >&2
  fi
  exit 1
}

require_file() {
  [[ -f "$EVIDENCE/$1" ]] || fail "missing evidence file $1"
}

require_contains() {
  local file="$1" needle="$2"
  grep -qF "$needle" "$EVIDENCE/$file" \
    || fail "$file does not contain expected marker: $needle"
}

HOSTFWD="${SSHD_DEPLOY_IPV6_HOSTFWD:-off}"
if ! SSHD_DEPLOY_EVIDENCE_DIR="$EVIDENCE" \
     SSHD_DEPLOY_IPV6_HOSTFWD="$HOSTFWD" \
     "$ROOT/tests/sshd_deploy_preflight_test.sh" >"$OUT" 2>"$ERR"; then
  fail "SSHD deploy preflight with evidence capture failed"
fi

for file in manifest.txt git-head.txt git-status.txt artifacts-sha256.txt \
            artifacts-size.txt validation.txt serial.log net-ipv6 services \
            authorized_keys secrets-omitted.txt; do
  require_file "$file"
done

require_contains manifest.txt "SwiftOS Hetzner Cloud deploy preflight evidence"
require_contains manifest.txt "profile: hcloud-sshd-static-ipv6"
require_contains manifest.txt "sshd listener: /bin/sshd -6 on guest TCP/22"
require_contains manifest.txt "Provider-routed Hetzner IPv6 SSH acceptance still requires a real cloud run."
require_contains validation.txt "result: pass"
require_contains validation.txt "guest gate: /bin/netinfo --check --require-static6"
require_contains net-ipv6 "address=2001:db8:0:3df1::1/64"
require_contains net-ipv6 "gateway=fe80::1"
require_contains services "sshd6"
require_contains serial.log "netinfo: check ok"
require_contains serial.log "sshd: listening on 22 (IPv6 session exec preflight)"
require_contains serial.log "virtio-rng: runtime entropy ready"
require_contains serial.log "net-hc23 OK: static IPv6"
require_contains artifacts-sha256.txt "kernel.elf"
require_contains artifacts-sha256.txt "virt.dtb"
require_contains artifacts-sha256.txt "base-sshd-deploy.img"
require_contains secrets-omitted.txt "ssh_host_ed25519_seed"
require_contains secrets-omitted.txt "ssh_kex_seed"
require_contains secrets-omitted.txt "deploy login private key"

for secret in ssh_host_ed25519_seed ssh_kex_seed deploy_ed25519; do
  [[ ! -e "$EVIDENCE/$secret" ]] || fail "private material leaked into evidence bundle: $secret"
done

echo "PASS: Hetzner deploy evidence bundle captured public preflight records and omitted private seeds"
