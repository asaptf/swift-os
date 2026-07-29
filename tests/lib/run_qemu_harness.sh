#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Central wrapper for in-QEMU boot harnesses: one automatic retry only when the
# guest never reached a verdict (boot-phase DEMO_BOOT_TIMEOUT await, or no
# PASS:/FAIL: line at all). Substantive FAIL: verdicts are never retried.
#
# Usage:
#   run_qemu_harness.sh [--name NAME] [--] harness [args...]
#   run_qemu_harness.sh --print-summary
#
# Makefile routes QEMU harnesses through $(RUNTEST); host/static gates do not.
# Retry log (for end-of-run summary):
#   QEMU_HARNESS_RETRY_LOG  — append path (default: none; no summary file)
#
# Greppable markers:
#   QEMU_HARNESS_RETRY: <name> reason=<boot-timeout|no-verdict>
#   QEMU_HARNESS_RETRY_SUMMARY: ...

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/timeouts.sh
# (timeouts not required here; boot detection is by FAIL-line signature)

usage() {
  cat <<'EOF' >&2
usage: run_qemu_harness.sh [--name NAME] [--] harness [args...]
       run_qemu_harness.sh --print-summary
EOF
  exit 2
}

# Host-side / static gates that must never be retried, even if mis-routed.
# Match on the harness path basename.
is_static_gate() {
  local base
  base="$(basename "$1")"
  case "$base" in
    smp_mailbox_layout_test.sh|smp_release_guard_test.sh|smp_state_audit_test.sh|\
    busybox_inputs_guard_test.sh|device_authority_guard_test.sh|userland_elf_test.sh|\
    tls_verify_test.sh|qemu_virt_hardware_map_test.sh|smp_s1_preflight_test.sh|\
    docs_reference_test.swift|run_qemu_harness_retry_test.sh)
      return 0
      ;;
  esac
  return 1
}

# True if this FAIL: line is a DEMO_BOOT_TIMEOUT / first-readiness await failure.
# Later-phase timeouts (login, Ctrl-C, assertion markers) must return false.
is_boot_phase_timeout_line() {
  local line="$1"
  # Strip optional leading whitespace; harnesses print "FAIL: ..." on its own line.
  case "$line" in
    FAIL:*)
      ;;
    *)
      return 1
      ;;
  esac
  case "$line" in
    *"timed out waiting for tty line prompt"*) return 0 ;;
    *"tty demo did not become ready"*) return 0 ;;
    *"tty demo not ready"*) return 0 ;;
    *"no tty line prompt"*) return 0 ;;
    *"no tty prompt"*) return 0 ;;
    *"timed out waiting for marker: M7 tty"*) return 0 ;;
    *"timeout: M7 tty"*) return 0 ;;
    *"M7 tty prompt missing"*) return 0 ;;
    *"did not exec from slot A"*) return 0 ;;
    *"did not exec from slot B"*) return 0 ;;
    *"busybox shell did not start"*) return 0 ;;
    *) return 1 ;;
  esac
}

# If retryable, print reason (boot-timeout | no-verdict) and return 0; else 1.
classify_retry_reason() {
  local out="$1"
  # Strip CRs from serial dumps mixed into harness output.
  out="${out//$'\r'/}"

  if printf '%s\n' "$out" | grep -qE '^PASS:'; then
    return 1
  fi

  local fail_lines
  fail_lines="$(printf '%s\n' "$out" | grep -E '^FAIL:' || true)"

  if [[ -z "$fail_lines" ]]; then
    printf '%s\n' "no-verdict"
    return 0
  fi

  local line any=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    any=1
    if ! is_boot_phase_timeout_line "$line"; then
      return 1
    fi
  done <<<"$fail_lines"

  if [[ "$any" -eq 0 ]]; then
    printf '%s\n' "no-verdict"
    return 0
  fi
  printf '%s\n' "boot-timeout"
  return 0
}

print_summary() {
  local log="${QEMU_HARNESS_RETRY_LOG:-}"
  if [[ -z "$log" || ! -f "$log" ]]; then
    echo "QEMU_HARNESS_RETRY_SUMMARY: none (no retries this run)"
    return 0
  fi
  local n
  n="$(grep -cE '^QEMU_HARNESS_RETRY:' "$log" 2>/dev/null || true)"
  n="${n:-0}"
  if [[ "$n" -eq 0 ]]; then
    echo "QEMU_HARNESS_RETRY_SUMMARY: none (no retries this run)"
    return 0
  fi
  echo "QEMU_HARNESS_RETRY_SUMMARY: $n harness(es) retried:"
  # shellcheck disable=SC2002
  cat "$log" | sed 's/^/  /'
  return 0
}

record_retry() {
  local name="$1" reason="$2" outcome="$3"
  local line="QEMU_HARNESS_RETRY: $name reason=$reason outcome=$outcome"
  echo "$line"
  if [[ -n "${QEMU_HARNESS_RETRY_LOG:-}" ]]; then
    mkdir -p "$(dirname "$QEMU_HARNESS_RETRY_LOG")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$QEMU_HARNESS_RETRY_LOG"
  fi
}

run_once() {
  # Run command with live output; capture combined stream for classification.
  # Uses a temp file + tee so wall clock does not grow on the happy path beyond
  # ordinary pipe overhead (no sleep, no extra QEMU).
  # Note: never enable `set -e` here — a non-zero harness status must return to
  # the caller for classification, not abort the wrapper.
  local out_file="$1"
  shift
  local rc
  set -o pipefail
  "$@" 2>&1 | tee "$out_file"
  rc=${PIPESTATUS[0]}
  set +o pipefail
  return "$rc"
}

# --- argv ------------------------------------------------------------------

NAME=""
if [[ $# -lt 1 ]]; then
  usage
fi

if [[ "$1" == "--print-summary" ]]; then
  print_summary
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || usage
      NAME="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -ge 1 ]] || usage

if [[ -z "$NAME" ]]; then
  # Prefer the first path-like arg that looks like a harness script.
  for a in "$@"; do
    case "$a" in
      *.sh|*.swift)
        NAME="$(basename "$a")"
        break
        ;;
    esac
  done
  [[ -n "$NAME" ]] || NAME="$(basename "$1")"
fi

# Static gates: run once, never retry.
if is_static_gate "$1" || { [[ $# -ge 2 ]] && is_static_gate "$2"; }; then
  exec "$@"
fi

WORKDIR="${TMPDIR:-/tmp}"
OUT1="$(mktemp "$WORKDIR/qemu-harness-out1.XXXXXX")"
OUT2="$(mktemp "$WORKDIR/qemu-harness-out2.XXXXXX")"
cleanup() { rm -f "$OUT1" "$OUT2"; }
trap cleanup EXIT

rc1=0
run_once "$OUT1" "$@" || rc1=$?

if [[ "$rc1" -eq 0 ]]; then
  exit 0
fi

output1="$(cat "$OUT1" 2>/dev/null || true)"
reason=""
if ! reason="$(classify_retry_reason "$output1")"; then
  # Substantive failure — surface original exit status immediately.
  exit "$rc1"
fi

# One retry, loud.
echo "QEMU_HARNESS_RETRY: $NAME reason=$reason (attempt 2/2)" >&2

rc2=0
run_once "$OUT2" "$@" || rc2=$?

if [[ "$rc2" -eq 0 ]]; then
  record_retry "$NAME" "$reason" "pass"
  exit 0
fi

# Retry also failed — report the original failure (output already printed on
# attempt 1; restate clearly and exit with the original status).
record_retry "$NAME" "$reason" "fail"
echo "QEMU_HARNESS_RETRY: $NAME reason=$reason outcome=fail (reporting original failure, rc=$rc1)" >&2
echo "---- original harness output (attempt 1) ----" >&2
printf '%s\n' "$output1" >&2
echo "---- end original harness output ----" >&2
exit "$rc1"
