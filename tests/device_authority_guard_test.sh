#!/usr/bin/env bash
# device_authority_guard_test.sh - C5f static guard for metadata-only device grants.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HANDLE_SWIFT="$ROOT/kernel/vfs/handle.swift"
VFS_SWIFT="$ROOT/kernel/vfs/vfs.swift"
DRVSVC_C="$ROOT/userland/drvsvcdemo.c"
DRIVER_TEST="$ROOT/tests/driver_service_test.sh"

for needle in \
  'func deviceMetadataGrantRights() -> Rights' \
  'r.insert(.getattr)' \
  'r.insert(.transfer)' \
  'func deviceGrantHasHardwareAuthorityRights(_ r: Rights) -> Bool' \
  'r.contains(.map)' \
  'r.contains(.read)' \
  'r.contains(.write)' \
  'r.contains(.execute)' \
  'r.contains(.duplicate)' \
  'r.contains(.setattr)'; do
  if ! grep -Fq -- "$needle" "$HANDLE_SWIFT"; then
    echo "FAIL: C5f handle authority guard missing $needle." >&2
    exit 1
  fi
done

if ! grep -Fq 'deviceMetadataGrantRights()' "$VFS_SWIFT"; then
  echo "FAIL: C5f VFS device claim path must use the shared metadata-only rights helper." >&2
  exit 1
fi

for needle in \
  'drvsvc: C5f device grant rights metadata-only' \
  'C5f OK: device grant rights stayed metadata-only'; do
  if ! grep -Fq -- "$needle" "$DRVSVC_C" "$DRIVER_TEST"; then
    echo "FAIL: C5f runtime marker/test expectation missing $needle." >&2
    exit 1
  fi
done

echo "PASS: C5f metadata-only device grant rights contract is statically guarded"
