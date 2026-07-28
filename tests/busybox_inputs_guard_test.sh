#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# busybox_inputs_guard_test.sh — static guard: every tree-owned source that
# scripts/build-busybox.sh compiles/links (or feeds via -isystem) must be
# covered by scripts/busybox-inputs-hash.sh, and the Makefile / CI bootstrap
# must refuse an unstamped or content-stale build/busybox.elf.
#
# This is intentionally non-tautological: adding e.g.
#   $GCC -c "$ROOT/userland/lib/newfile.c" ...
# to build-busybox.sh without registering newfile.c in the hash enumerator
# makes this test fail.
#
# Portable to macOS /bin/bash 3.2 (no mapfile / associative arrays).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_SCRIPT="$ROOT/scripts/build-busybox.sh"
HASH_SCRIPT="$ROOT/scripts/busybox-inputs-hash.sh"
MAKEFILE="$ROOT/Makefile"
BOOTSTRAP="$ROOT/scripts/ci-bootstrap.sh"
CI_FAST="$ROOT/.github/workflows/ci-fast.yml"
CI_NIGHTLY="$ROOT/.github/workflows/ci-nightly.yml"
TMPDIR_GUARD="$(mktemp -d "${TMPDIR:-/tmp}/busybox-inputs-guard.XXXXXX")"
trap 'rm -rf "$TMPDIR_GUARD"' EXIT

for f in "$BUILD_SCRIPT" "$HASH_SCRIPT" "$MAKEFILE" "$BOOTSTRAP" "$CI_FAST" "$CI_NIGHTLY"; do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: required file missing: $f" >&2
    exit 1
  fi
done

if [[ ! -x "$HASH_SCRIPT" ]]; then
  echo "FAIL: $HASH_SCRIPT must be executable" >&2
  exit 1
fi

# --- discover tree-owned inputs from the build script itself -----------------
# Only the paths that actually feed the binary:
#   - compile units:  $GCC ... -c "$ROOT/path"
#   - link script:    -T "$ROOT/path"
#   - isystem tree:   -isystem $COMPAT with COMPAT="$ROOT/userland/compat"
# Do NOT treat WORK=/tarball/SRC paths under userland/busybox as tracked
# tree inputs — those are pinned upstream by BUSYBOX_VERSION.
DISCOVERED="$TMPDIR_GUARD/discovered.txt"
: >"$DISCOVERED"

# Compile inputs: -c "$ROOT/..."
while IFS= read -r line; do
  rel="$(printf '%s\n' "$line" | sed -n 's/.*-c[[:space:]]*"\$ROOT\/\([^"]*\)".*/\1/p')"
  [[ -n "$rel" ]] && printf '%s\n' "$rel" >>"$DISCOVERED"
done < <(rg -n -- '-c[[:space:]]*"\$ROOT/' "$BUILD_SCRIPT" || true)

# Link script: -T "$ROOT/..."
while IFS= read -r line; do
  rel="$(printf '%s\n' "$line" | sed -n 's/.*-T[[:space:]]*"\$ROOT\/\([^"]*\)".*/\1/p')"
  [[ -n "$rel" ]] && printf '%s\n' "$rel" >>"$DISCOVERED"
done < <(rg -n -- '-T[[:space:]]*"\$ROOT/' "$BUILD_SCRIPT" || true)

# isystem $COMPAT → require COMPAT to be userland/compat and cover that tree
if rg -q 'COMPAT="\$ROOT/userland/compat"' "$BUILD_SCRIPT" \
  && rg -q -- '-isystem \$COMPAT' "$BUILD_SCRIPT"; then
  printf '%s\n' "userland/compat" >>"$DISCOVERED"
else
  echo "FAIL: expected COMPAT=\$ROOT/userland/compat used as -isystem in build-busybox.sh" >&2
  exit 1
fi

# Also catch -isystem "$ROOT/..." direct forms (future-proof).
while IFS= read -r line; do
  rel="$(printf '%s\n' "$line" | sed -n 's/.*-isystem[[:space:]]*"\$ROOT\/\([^"]*\)".*/\1/p')"
  [[ -n "$rel" ]] && printf '%s\n' "$rel" >>"$DISCOVERED"
done < <(rg -n -- '-isystem[[:space:]]*"\$ROOT/' "$BUILD_SCRIPT" || true)

LC_ALL=C sort -u "$DISCOVERED" -o "$DISCOVERED"

if [[ ! -s "$DISCOVERED" ]]; then
  echo "FAIL: could not discover any compile/link/isystem inputs from $BUILD_SCRIPT" >&2
  exit 1
fi

# Must have discovered at least the known compile units (guards against a
# broken regex silently matching nothing useful).
for required in \
  userland/lib/crt0_newlib.S \
  userland/lib/newlib_syscalls.c \
  userland/compat/stubs.c \
  userland/user_newlib.ld \
  userland/compat; do
  if ! grep -Fxq -- "$required" "$DISCOVERED"; then
    echo "FAIL: discovery missed expected input $required (regex too narrow?)" >&2
    exit 1
  fi
done

# Tracked set from the hash enumerator (must stay the single source of truth).
TRACKED="$TMPDIR_GUARD/tracked.txt"
"$HASH_SCRIPT" --list | LC_ALL=C sort -u >"$TRACKED"
if [[ ! -s "$TRACKED" ]]; then
  echo "FAIL: $HASH_SCRIPT --list produced no paths" >&2
  exit 1
fi

missing=0
disc_count=0
while IFS= read -r disc; do
  [[ -z "$disc" ]] && continue
  disc_count=$((disc_count + 1))
  if [[ -d "$ROOT/$disc" ]]; then
    # Directory input (isystem tree): every regular file must be tracked.
    while IFS= read -r f; do
      rel="${f#"$ROOT"/}"
      if ! grep -Fxq -- "$rel" "$TRACKED"; then
        echo "FAIL: build-busybox.sh feeds $rel via $disc, but busybox-inputs-hash.sh does not track it" >&2
        missing=1
      fi
    done < <(find "$ROOT/$disc" -type f | LC_ALL=C sort)
  elif [[ -f "$ROOT/$disc" ]]; then
    if ! grep -Fxq -- "$disc" "$TRACKED"; then
      echo "FAIL: build-busybox.sh references $disc, but busybox-inputs-hash.sh does not track it" >&2
      missing=1
    fi
  else
    # Path may be a future file; still require registration.
    if ! grep -Fxq -- "$disc" "$TRACKED"; then
      echo "FAIL: build-busybox.sh references $disc (missing on disk), untracked by busybox-inputs-hash.sh" >&2
      missing=1
    fi
  fi
done <"$DISCOVERED"

if [[ "$missing" -ne 0 ]]; then
  echo "FAIL: register new busybox inputs in scripts/busybox-inputs-hash.sh list_file_inputs" >&2
  exit 1
fi

tracked_count="$(wc -l <"$TRACKED" | tr -d ' ')"

# Hash script must actually hash (not just list) and be deterministic.
h1="$("$HASH_SCRIPT")"
h2="$("$HASH_SCRIPT")"
case "$h1" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    if [[ ${#h1} -ne 64 || "$h1" != "$h2" ]]; then
      echo "FAIL: busybox-inputs-hash.sh must print a stable 64-hex digest (got: $h1)" >&2
      exit 1
    fi
    ;;
  *)
    echo "FAIL: busybox-inputs-hash.sh must print a stable 64-hex digest (got: $h1)" >&2
    exit 1
    ;;
esac

# --- Makefile must content-check, not mere existence -------------------------
for needle in \
  'busybox-inputs-hash.sh' \
  'busybox.inputs-hash' \
  'busybox.inputs-expected' \
  'busybox is STALE' \
  'busybox is UNSTAMPED'; do
  if ! grep -Fq -- "$needle" "$MAKEFILE"; then
    echo "FAIL: Makefile busybox freshness rule missing needle: $needle" >&2
    exit 1
  fi
done

recipe="$(awk '/^\$\(BUILD\)\/busybox\.elf:/{flag=1; next} flag && /^[^[:space:]#]/{exit} flag{print}' "$MAKEFILE")"
if ! grep -q 'inputs-hash\|inputs-expected\|STALE\|UNSTAMPED' <<<"$recipe"; then
  echo "FAIL: \$(BUILD)/busybox.elf recipe does not content-check inputs" >&2
  exit 1
fi

# --- CI bootstrap must not skip on mere file presence ------------------------
if ! grep -Fq 'busybox-inputs-hash.sh' "$BOOTSTRAP"; then
  echo "FAIL: ci-bootstrap.sh must invoke busybox-inputs-hash.sh before skipping" >&2
  exit 1
fi
if ! grep -Fq 'inputs-hash matches' "$BOOTSTRAP"; then
  echo "FAIL: ci-bootstrap.sh must require inputs-hash match, not mere presence" >&2
  exit 1
fi
if ! grep -Fq -- '--check' "$BOOTSTRAP"; then
  echo "FAIL: ci-bootstrap.sh must call busybox-inputs-hash.sh --check" >&2
  exit 1
fi

# --- CI cache must store the stamp and hash tree-owned inputs ----------------
for yml in "$CI_FAST" "$CI_NIGHTLY"; do
  for needle in \
    'build/busybox.inputs-hash' \
    'scripts/busybox-inputs-hash.sh' \
    'userland/lib/crt0_newlib.S' \
    'userland/lib/newlib_syscalls.c' \
    'userland/user_newlib.ld' \
    'userland/compat/**'; do
    if ! grep -Fq -- "$needle" "$yml"; then
      echo "FAIL: $yml cache config missing $needle" >&2
      exit 1
    fi
  done
done

# build script must write the stamp after a successful link
if ! grep -Fq 'busybox-inputs-hash.sh' "$BUILD_SCRIPT" \
  || ! grep -Fq 'busybox.inputs-hash' "$BUILD_SCRIPT"; then
  echo "FAIL: build-busybox.sh must write build/busybox.inputs-hash after linking" >&2
  exit 1
fi

echo "PASS: busybox inputs are content-tracked (discovered ${disc_count} build-script path(s), tracked ${tracked_count} file(s))"
