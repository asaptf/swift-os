#!/usr/bin/env bash
# sshd_authorized_keys_test.sh - SSHD deploy authorized_keys provisioning proof.
#
# Builds a temporary signed base image with a generated deploy SSH public key in
# /etc/ssh/authorized_keys, then proves that OpenSSH can authenticate with that
# key while the default HC5 fixture key is rejected.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSHKEY="${SSHKEY:-$ROOT/build/sshkey}"
SSH_KEYGEN="${SSH_KEYGEN:-ssh-keygen}"
HOST_PORT="${SSHD_HOST_PORT:-$((28000 + ($$ % 16000)))}"
DENY_KEY="$ROOT/fixtures/ssh/sshd_hc5_ed25519"

[[ -f "$ROOT/build/kernel.elf" ]] || { echo "FAIL: build/kernel.elf missing (make build)" >&2; exit 2; }
[[ -f "$DENY_KEY" ]] || { echo "FAIL: $DENY_KEY missing" >&2; exit 2; }
command -v "$SSH_KEYGEN" >/dev/null 2>&1 || { echo "FAIL: ssh-keygen not found" >&2; exit 2; }
if [[ ! -x "$SSHKEY" ]]; then
  ( cd "$ROOT" && make build/sshkey ) >/dev/null 2>&1 || { echo "FAIL: cannot build sshkey tool" >&2; exit 2; }
fi

WORK="$(mktemp -d -t swiftos-sshd-authkeys.XXXXXX)"
ALLOW_KEY="$WORK/deploy_ed25519"
AUTHORIZED_KEYS="$WORK/authorized_keys"
IMG="$WORK/base-sshd-authkeys.img"
BASE_ROOT="$WORK/base-root"
LOG="$WORK/base-image.log"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

"$SSH_KEYGEN" -q -t ed25519 -N '' -C swiftos-hc21-deploy-key -f "$ALLOW_KEY" \
  || { echo "FAIL: could not generate deploy SSH key" >&2; exit 2; }
{
  printf 'restrict,no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding '
  cat "$ALLOW_KEY.pub"
  printf 'command="/bin/id" '
  cat "$DENY_KEY.pub"
} >"$AUTHORIZED_KEYS"

if ! ( cd "$ROOT" && make BASE_IMG="$IMG" BASE_ROOT="$BASE_ROOT" SSHD_AUTHORIZED_KEYS_FILE="$AUTHORIZED_KEYS" base-image ) >"$LOG" 2>&1; then
  echo "FAIL: could not build SSHD authorized_keys base image" >&2
  cat "$LOG" >&2
  exit 2
fi

SSHD_BASE_IMG="$IMG" \
SSHD_ALLOW_KEY_SRC="$ALLOW_KEY" \
SSHD_DENY_KEY_SRC="$DENY_KEY" \
SSHD_HOST_PORT="$HOST_PORT" \
"$ROOT/tests/sshd_transport_test.sh" \
  || { echo "FAIL: deploy authorized_keys image did not pass SSHD acceptance" >&2; exit 1; }

echo "PASS: SSHD authorized_keys accepted safe deploy options and rejected an unsupported forced-command key"
