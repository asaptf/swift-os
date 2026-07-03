#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Shared helpers for the Hetzner deploy pipeline (P1.2).

set -euo pipefail

hetzner_deploy_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

hetzner_deploy_load_env() {
  local root="$1"
  DEPLOY_DIR="${HETZNER_DEPLOY_DIR:-$root/build/hetzner-deploy}"
  if [[ -f "$DEPLOY_DIR/deploy.env" ]]; then
    # shellcheck disable=SC1090
    source "$DEPLOY_DIR/deploy.env"
  elif [[ -f "$root/fixtures/hetzner/deploy.env" ]]; then
    # shellcheck disable=SC1090
    source "$root/fixtures/hetzner/deploy.env"
  fi

  DEPLOY_DIR="${HETZNER_DEPLOY_DIR:-$DEPLOY_DIR}"
  DISK_IMG="${HETZNER_DISK_IMAGE:-$root/build/swift-os.img}"
  HETZNER_UPDATE_STORE_IMG="${HETZNER_UPDATE_STORE_IMAGE:-$root/build/hetzner-update-store.img}"
  KERNEL_ELF="$root/build/kernel.elf"
  BASE_IMG="$root/build/base.img"
  DTB="$root/build/virt.dtb"
  SSHKEY="${HETZNER_SSHKEY:-$root/build/sshkey}"

  HETZNER_HOST="${HETZNER_HOST:-}"
  HETZNER_SSH_USER="${HETZNER_SSH_USER:-root}"
  HETZNER_SSH_PORT="${HETZNER_SSH_PORT:-22}"
  HETZNER_DISK="${HETZNER_DISK:-/dev/sda}"
  HETZNER_REMOTE_IMAGE="${HETZNER_REMOTE_IMAGE:-/root/swift-os.img}"
  HETZNER_AUTHORIZED_KEYS="${HETZNER_AUTHORIZED_KEYS:-$HOME/.ssh/id_ed25519.pub}"
  HETZNER_SSH_IDENTITY="${HETZNER_SSH_IDENTITY:-$HOME/.ssh/id_ed25519}"
  HETZNER_TARGET_MODE="${HETZNER_TARGET_MODE:-swiftos}"
  HETZNER_HOST_SEED="${HETZNER_HOST_SEED:-$DEPLOY_DIR/ssh_host_ed25519_seed}"
  HETZNER_KNOWN_HOSTS="${HETZNER_KNOWN_HOSTS:-$DEPLOY_DIR/known_hosts}"
  HETZNER_EVIDENCE_DIR="${HETZNER_EVIDENCE_DIR:-$DEPLOY_DIR/evidence}"
}

hetzner_deploy_require_file() {
  local path="$1" msg="$2"
  [[ -f "$path" ]] || { echo "FAIL: $msg ($path)" >&2; exit 2; }
}

hetzner_deploy_sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

hetzner_deploy_ssh_target() {
  printf '%s@%s' "$HETZNER_SSH_USER" "$HETZNER_HOST"
}

hetzner_deploy_ssh_linux() {
  ssh -p "$HETZNER_SSH_PORT" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -i "$HETZNER_SSH_IDENTITY" \
    "$(hetzner_deploy_ssh_target)" "$@"
}

hetzner_deploy_ssh_swiftos() {
  ssh -p "$HETZNER_SSH_PORT" \
    -F /dev/null \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$HETZNER_KNOWN_HOSTS" \
    -o GlobalKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -i "$HETZNER_SSH_IDENTITY" \
    "$(hetzner_deploy_ssh_target)" "$@"
}