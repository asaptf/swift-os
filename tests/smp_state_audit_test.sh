#!/usr/bin/env bash
# smp_state_audit_test.sh - S0c executable coverage check for the SMP globals audit.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/docs/SMP_STATE_AUDIT.md"
SCANNER="$ROOT/scripts/smp-global-audit.py"

[[ -f "$DOC" ]] || { echo "FAIL: $DOC missing" >&2; exit 1; }
[[ -x "$SCANNER" ]] || { echo "FAIL: $SCANNER missing or not executable" >&2; exit 1; }

SCAN="$(mktemp -t swiftos-smp-audit-scan.XXXXXX)"
DOC_ENTRIES="$(mktemp -t swiftos-smp-audit-doc.XXXXXX)"
trap 'rm -f "$SCAN" "$DOC_ENTRIES"' EXIT

"$SCANNER" | sort -u >"$SCAN"
grep -oE '`kernel/[^`]+:[A-Za-z_][A-Za-z0-9_]*`' "$DOC" \
  | tr -d '`' \
  | sort -u >"$DOC_ENTRIES"

missing=0
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  if ! grep -qF "\`$entry\`" "$DOC"; then
    echo "FAIL: docs/SMP_STATE_AUDIT.md does not cover $entry" >&2
    missing=1
  fi
done <"$SCAN"

stale=0
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  if ! grep -qxF "$entry" "$SCAN"; then
    echo "FAIL: docs/SMP_STATE_AUDIT.md has stale manifest entry $entry" >&2
    stale=1
  fi
done <"$DOC_ENTRIES"

if [[ "$missing" -ne 0 || "$stale" -ne 0 ]]; then
  exit 1
fi

count="$(wc -l <"$SCAN" | tr -d '[:space:]')"
echo "PASS: SMP mutable global audit covers $count scanned entries with no stale doc entries"
