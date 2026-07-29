#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# busybox_inputs_guard_test.sh — static guard for every CI-cached artifact that
# embeds the freestanding runtime (busybox, sqlite, nginx, openssl, and the
# weekly heavy ports: ncurses, glib, mc, bash, zsh).
#
# For each covered build script, every tree-owned source that is compiled/linked
# (or fed via -isystem / -T) must be covered by scripts/artifact-inputs-hash.sh,
# and the Makefile / CI bootstrap / cache config must refuse or rebuild an
# unstamped or content-stale artifact.
#
# This is intentionally non-tautological: adding e.g.
#   $GCC -c "$ROOT/userland/lib/newfile.c" ...
# to build-sqlite.sh without registering newfile.c in the hash enumerator
# makes this test fail.
#
# Portable to macOS /bin/bash 3.2 (no mapfile / associative arrays).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HASH_SCRIPT="$ROOT/scripts/artifact-inputs-hash.sh"
BB_WRAPPER="$ROOT/scripts/busybox-inputs-hash.sh"
MAKEFILE="$ROOT/Makefile"
BOOTSTRAP="$ROOT/scripts/ci-bootstrap.sh"
CI_FAST="$ROOT/.github/workflows/ci-fast.yml"
CI_NIGHTLY="$ROOT/.github/workflows/ci-nightly.yml"
CI_PORTS="$ROOT/.github/workflows/ci-ports.yml"
TMPDIR_GUARD="$(mktemp -d "${TMPDIR:-/tmp}/ported-inputs-guard.XXXXXX")"
trap 'rm -rf "$TMPDIR_GUARD"' EXIT

for f in "$HASH_SCRIPT" "$BB_WRAPPER" "$MAKEFILE" "$BOOTSTRAP" "$CI_FAST" "$CI_NIGHTLY" "$CI_PORTS"; do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: required file missing: $f" >&2
    exit 1
  fi
done

if [[ ! -x "$HASH_SCRIPT" ]]; then
  echo "FAIL: $HASH_SCRIPT must be executable" >&2
  exit 1
fi
if [[ ! -x "$BB_WRAPPER" ]]; then
  echo "FAIL: $BB_WRAPPER must be executable" >&2
  exit 1
fi

NAMES="$("$HASH_SCRIPT" --names)"
expected_names=$'busybox\nsqlite\nnginx\nopenssl\nncurses\nglib\nmc\nbash\nzsh'
if [[ "$NAMES" != "$expected_names" ]]; then
  echo "FAIL: artifact-inputs-hash.sh --names must list busybox sqlite nginx openssl ncurses glib mc bash zsh" >&2
  echo "  got: $(printf '%s' "$NAMES" | tr '\n' ' ')" >&2
  exit 1
fi

# Compatibility wrapper must delegate to the shared enumerator for busybox.
if ! grep -Fq 'artifact-inputs-hash.sh' "$BB_WRAPPER"; then
  echo "FAIL: busybox-inputs-hash.sh must wrap artifact-inputs-hash.sh" >&2
  exit 1
fi
wrap_h="$("$BB_WRAPPER")"
direct_h="$("$HASH_SCRIPT" busybox)"
if [[ "$wrap_h" != "$direct_h" ]]; then
  echo "FAIL: busybox-inputs-hash.sh must produce the same digest as artifact-inputs-hash.sh busybox" >&2
  exit 1
fi

# --- discover tree-owned inputs from a build script --------------------------
# Only the paths that actually feed the binary:
#   - compile units:  $CC ... -c "$ROOT/path"
#   - link script:    -T "$ROOT/path"  (or -T $ROOT/path)
#   - isystem tree:   -isystem $COMPAT / $OVERLAY with known roots
# Do NOT treat WORK=/tarball/SRC paths as tracked tree inputs — those are
# pinned upstream by the version env var hashed into the stamp.
discover_inputs() {
  local build_script="$1"
  local out="$2"
  : >"$out"

  # Compile inputs: -c "$ROOT/..."
  while IFS= read -r line; do
    rel="$(printf '%s\n' "$line" | sed -n 's/.*-c[[:space:]]*"\$ROOT\/\([^"]*\)".*/\1/p')"
    [[ -n "$rel" ]] && printf '%s\n' "$rel" >>"$out"
  done < <(rg -n -- '-c[[:space:]]*"\$ROOT/' "$build_script" || true)

  # Link script: -T "$ROOT/..."
  while IFS= read -r line; do
    rel="$(printf '%s\n' "$line" | sed -n 's/.*-T[[:space:]]*"\$ROOT\/\([^"]*\)".*/\1/p')"
    [[ -n "$rel" ]] && printf '%s\n' "$rel" >>"$out"
  done < <(rg -n -- '-T[[:space:]]*"\$ROOT/' "$build_script" || true)

  # Link script unquoted: -T $ROOT/...
  while IFS= read -r line; do
    rel="$(printf '%s\n' "$line" | sed -n 's/.*-T[[:space:]]*\$ROOT\/\([^"'"'"'[:space:]]*\).*/\1/p')"
    [[ -n "$rel" ]] && printf '%s\n' "$rel" >>"$out"
  done < <(rg -n -- '-T[[:space:]]*\$ROOT/' "$build_script" || true)

  # isystem $COMPAT → require COMPAT to be userland/compat and cover that tree
  if rg -q 'COMPAT="\$ROOT/userland/compat"' "$build_script" \
    && rg -q -- '-isystem \$COMPAT|"\$COMPAT"|\$COMPAT' "$build_script"; then
    printf '%s\n' "userland/compat" >>"$out"
  fi

  # nginx overlay isystem / patch tree
  if rg -q 'OVERLAY="\$ROOT/userland/nginx/swiftos"' "$build_script"; then
    printf '%s\n' "userland/nginx/swiftos" >>"$out"
  fi

  # Also catch -isystem "$ROOT/..." direct forms (future-proof).
  while IFS= read -r line; do
    rel="$(printf '%s\n' "$line" | sed -n 's/.*-isystem[[:space:]]*"\$ROOT\/\([^"]*\)".*/\1/p')"
    [[ -n "$rel" ]] && printf '%s\n' "$rel" >>"$out"
  done < <(rg -n -- '-isystem[[:space:]]*"\$ROOT/' "$build_script" || true)

  LC_ALL=C sort -u "$out" -o "$out"
}

# cache_yml_list: space-separated paths to workflow files that must cache this
# artifact. cache_path: path fragment under build/ (or a full path) that the
# workflow cache `path:` block must list (e.g. build/busybox.elf, build/sqlite-root).
check_artifact() {
  local name="$1"
  local build_script="$2"
  local stamp_name="$3"        # e.g. busybox.inputs-hash
  local mode="$4"              # refuse | rebuild
  local cache_yml_list="$5"
  local cache_path="$6"

  if [[ ! -f "$build_script" ]]; then
    echo "FAIL: build script missing for $name: $build_script" >&2
    exit 1
  fi

  local discovered="$TMPDIR_GUARD/${name}-discovered.txt"
  discover_inputs "$build_script" "$discovered"

  if [[ ! -s "$discovered" ]]; then
    echo "FAIL: could not discover any compile/link/isystem inputs from $build_script" >&2
    exit 1
  fi

  # Must have discovered at least the known runtime units (guards against a
  # broken regex silently matching nothing useful).
  for required in \
    userland/lib/crt0_newlib.S \
    userland/lib/newlib_syscalls.c \
    userland/user_newlib.ld \
    userland/compat; do
    if ! grep -Fxq -- "$required" "$discovered"; then
      # stubs.c may be listed as the file or covered via the compat tree
      if [[ "$required" == "userland/compat" ]]; then
        if grep -Fxq -- "userland/compat/stubs.c" "$discovered"; then
          continue
        fi
      fi
      echo "FAIL: $name discovery missed expected input $required (regex too narrow?)" >&2
      echo "  discovered:" >&2
      sed 's/^/    /' "$discovered" >&2
      exit 1
    fi
  done

  # stubs.c must be compiled by every covered script (runtime embed).
  if ! rg -q 'userland/compat/stubs\.c' "$build_script"; then
    echo "FAIL: $build_script does not compile userland/compat/stubs.c" >&2
    exit 1
  fi

  local tracked="$TMPDIR_GUARD/${name}-tracked.txt"
  "$HASH_SCRIPT" "$name" --list | LC_ALL=C sort -u >"$tracked"
  if [[ ! -s "$tracked" ]]; then
    echo "FAIL: $HASH_SCRIPT $name --list produced no paths" >&2
    exit 1
  fi

  local missing=0
  local disc_count=0
  while IFS= read -r disc; do
    [[ -z "$disc" ]] && continue
    disc_count=$((disc_count + 1))
    if [[ -d "$ROOT/$disc" ]]; then
      while IFS= read -r f; do
        rel="${f#"$ROOT"/}"
        if ! grep -Fxq -- "$rel" "$tracked"; then
          echo "FAIL: $build_script feeds $rel via $disc, but artifact-inputs-hash.sh $name does not track it" >&2
          missing=1
        fi
      done < <(find "$ROOT/$disc" -type f | LC_ALL=C sort)
    elif [[ -f "$ROOT/$disc" ]]; then
      if ! grep -Fxq -- "$disc" "$tracked"; then
        echo "FAIL: $build_script references $disc, but artifact-inputs-hash.sh $name does not track it" >&2
        missing=1
      fi
    else
      if ! grep -Fxq -- "$disc" "$tracked"; then
        echo "FAIL: $build_script references $disc (missing on disk), untracked by artifact-inputs-hash.sh $name" >&2
        missing=1
      fi
    fi
  done <"$discovered"

  if [[ "$missing" -ne 0 ]]; then
    echo "FAIL: register new $name inputs in scripts/artifact-inputs-hash.sh list_file_inputs" >&2
    exit 1
  fi

  # Hash script must actually hash (not just list) and be deterministic.
  local h1 h2
  h1="$("$HASH_SCRIPT" "$name")"
  h2="$("$HASH_SCRIPT" "$name")"
  case "$h1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
      if [[ ${#h1} -ne 64 || "$h1" != "$h2" ]]; then
        echo "FAIL: artifact-inputs-hash.sh $name must print a stable 64-hex digest (got: $h1)" >&2
        exit 1
      fi
      ;;
    *)
      echo "FAIL: artifact-inputs-hash.sh $name must print a stable 64-hex digest (got: $h1)" >&2
      exit 1
      ;;
  esac

  # Build script must write the stamp after a successful build.
  if ! grep -Fq 'artifact-inputs-hash.sh' "$build_script" \
    || ! grep -Fq "${name}.inputs-hash" "$build_script"; then
    echo "FAIL: $(basename "$build_script") must write build/${name}.inputs-hash after linking" >&2
    exit 1
  fi

  # Makefile must content-check.
  for needle in \
    'artifact-inputs-hash.sh' \
    "${name}.inputs-hash" \
    "${name}.inputs-expected"; do
    if ! grep -Fq -- "$needle" "$MAKEFILE"; then
      echo "FAIL: Makefile $name freshness rule missing needle: $needle" >&2
      exit 1
    fi
  done

  if [[ "$mode" == "refuse" ]]; then
    for needle in "${name} is STALE" "${name} is UNSTAMPED"; do
      if ! grep -Fq -- "$needle" "$MAKEFILE"; then
        echo "FAIL: Makefile $name refuse path missing needle: $needle" >&2
        exit 1
      fi
    done
  else
    for needle in "${name} is STALE" "${name} is UNSTAMPED"; do
      if ! grep -Fq -- "$needle" "$MAKEFILE"; then
        echo "FAIL: Makefile $name rebuild path missing needle: $needle" >&2
        exit 1
      fi
    done
    if ! grep -Fq -- 'rebuilding' "$MAKEFILE"; then
      echo "FAIL: Makefile port rebuild messages should say 'rebuilding'" >&2
      exit 1
    fi
  fi

  # CI cache(s) must store the stamp, hash tree-owned inputs, and the artifact path.
  local yml
  for yml in $cache_yml_list; do
    for needle in \
      "build/${stamp_name}" \
      'scripts/artifact-inputs-hash.sh' \
      'userland/lib/crt0_newlib.S' \
      'userland/lib/newlib_syscalls.c' \
      'userland/user_newlib.ld' \
      'userland/compat/**'; do
      if ! grep -Fq -- "$needle" "$yml"; then
        echo "FAIL: $yml cache config missing $needle" >&2
        exit 1
      fi
    done
    if ! grep -Fq -- "$cache_path" "$yml"; then
      echo "FAIL: $yml cache path missing $cache_path" >&2
      exit 1
    fi
  done

  echo "  OK $name (discovered ${disc_count} build-script path(s), tracked $(wc -l <"$tracked" | tr -d ' ') file(s), mode=$mode)"
}

BOOTSTRAP_CACHES="$CI_FAST $CI_NIGHTLY"
PORTS_CACHES="$CI_PORTS"

check_artifact busybox \
  "$ROOT/scripts/build-busybox.sh" \
  "busybox.inputs-hash" \
  refuse \
  "$BOOTSTRAP_CACHES" \
  "build/busybox.elf"

check_artifact sqlite \
  "$ROOT/scripts/build-sqlite.sh" \
  "sqlite.inputs-hash" \
  rebuild \
  "$BOOTSTRAP_CACHES" \
  "build/sqlite-root"

check_artifact nginx \
  "$ROOT/scripts/build-nginx.sh" \
  "nginx.inputs-hash" \
  rebuild \
  "$BOOTSTRAP_CACHES" \
  "build/nginx-root"

check_artifact openssl \
  "$ROOT/scripts/build-openssl.sh" \
  "openssl.inputs-hash" \
  rebuild \
  "$BOOTSTRAP_CACHES" \
  "build/openssl-root"

check_artifact ncurses \
  "$ROOT/scripts/build-ncurses.sh" \
  "ncurses.inputs-hash" \
  rebuild \
  "$PORTS_CACHES" \
  "build/ncdemo.elf"

check_artifact glib \
  "$ROOT/scripts/build-glib.sh" \
  "glib.inputs-hash" \
  rebuild \
  "$PORTS_CACHES" \
  "build/glibdemo.elf"

check_artifact mc \
  "$ROOT/scripts/build-mc.sh" \
  "mc.inputs-hash" \
  rebuild \
  "$PORTS_CACHES" \
  "build/mc.elf"

check_artifact bash \
  "$ROOT/scripts/build-bash.sh" \
  "bash.inputs-hash" \
  rebuild \
  "$PORTS_CACHES" \
  "build/bash.elf"

check_artifact zsh \
  "$ROOT/scripts/build-zsh.sh" \
  "zsh.inputs-hash" \
  rebuild \
  "$PORTS_CACHES" \
  "build/zsh.elf"

# Weekly ports gate must own the five harnesses (not make test / nightly).
if ! grep -Fq 'ports-test' "$MAKEFILE"; then
  echo "FAIL: Makefile must define ports-test for the heavy ports gate" >&2
  exit 1
fi
if ! grep -Fq 'make ports-test' "$CI_PORTS" && ! grep -Fq 'ports-test' "$CI_PORTS"; then
  echo "FAIL: ci-ports.yml must run make ports-test" >&2
  exit 1
fi
# make test must not rebuild the INCLUDE_* heavy-ports image.
test_body="$(awk '/^test:/{flag=1; next} flag && /^[^[:space:]#]/{exit} flag{print}' "$MAKEFILE")"
if grep -E -q 'INCLUDE_NCURSES=1|INCLUDE_GLIB=1|INCLUDE_MC=1|INCLUDE_BASH=1|INCLUDE_ZSH=1' <<<"$test_body"; then
  echo "FAIL: make test must not enable INCLUDE_{NCURSES,GLIB,MC,BASH,ZSH} (moved to ports-test)" >&2
  exit 1
fi
for harness in ncurses_test.sh glib_test.sh mc_test.sh bash_test.sh zsh_test.sh; do
  if grep -Fq "./tests/$harness" <<<"$test_body"; then
    echo "FAIL: make test must not run $harness (moved to ports-test)" >&2
    exit 1
  fi
  ports_body="$(awk '/^ports-test:/{flag=1; next} flag && /^[^[:space:]#]/{exit} flag{print}' "$MAKEFILE")"
  if ! grep -Fq "./tests/$harness" <<<"$ports_body"; then
    echo "FAIL: ports-test must run $harness" >&2
    exit 1
  fi
done

# --- CI bootstrap must not skip busybox on mere file presence ----------------
if ! grep -Fq 'artifact-inputs-hash.sh' "$BOOTSTRAP"; then
  echo "FAIL: ci-bootstrap.sh must invoke artifact-inputs-hash.sh before skipping busybox" >&2
  exit 1
fi
if ! grep -Fq 'inputs-hash matches' "$BOOTSTRAP"; then
  echo "FAIL: ci-bootstrap.sh must require inputs-hash match, not mere presence" >&2
  exit 1
fi
if ! grep -Fq -- '--check' "$BOOTSTRAP"; then
  echo "FAIL: ci-bootstrap.sh must call artifact-inputs-hash.sh ... --check" >&2
  exit 1
fi

# busybox.elf recipe must content-check (refuse path)
recipe="$(awk '/^\$\(BUILD\)\/busybox\.elf:/{flag=1; next} flag && /^[^[:space:]#]/{exit} flag{print}' "$MAKEFILE")"
if ! grep -q 'inputs-hash\|inputs-expected\|STALE\|UNSTAMPED' <<<"$recipe"; then
  echo "FAIL: \$(BUILD)/busybox.elf recipe does not content-check inputs" >&2
  exit 1
fi

# Port binary recipes must content-check (rebuild path)
for name in sqlite nginx openssl ncurses glib mc bash zsh; do
  if ! awk -v n="$name" '
    $0 ~ "\\$\\(BUILD\\)/" n "\\.inputs-expected" { seen_exp=1 }
    $0 ~ n "\\.inputs-hash" && /cmp/ { seen_cmp=1 }
    $0 ~ n " is STALE" { seen_stale=1 }
    $0 ~ n " is UNSTAMPED" { seen_unstamped=1 }
    END { exit (seen_exp && seen_cmp && seen_stale && seen_unstamped) ? 0 : 1 }
  ' "$MAKEFILE"; then
    echo "FAIL: Makefile missing full content-check rebuild path for $name" >&2
    exit 1
  fi
done

echo "PASS: ported/runtime inputs are content-tracked for busybox sqlite nginx openssl ncurses glib mc bash zsh"
