#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Host-side unit test for tests/lib/run_qemu_harness.sh retry boundary.
# No QEMU: fake harness scripts exercise retry / no-retry classification.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAP="$ROOT/tests/lib/run_qemu_harness.sh"
FAKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qemu-harness-retry-test.XXXXXX")"
RETRY_LOG="$FAKE_DIR/retry.log"
export QEMU_HARNESS_RETRY_LOG="$RETRY_LOG"
trap 'rm -rf "$FAKE_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$WRAP" ]] || chmod +x "$WRAP"
[[ -x "$WRAP" ]] || fail "wrapper not executable: $WRAP"

# --- fake harnesses --------------------------------------------------------

# 1) No verdict first, PASS on second attempt → must retry and pass.
cat >"$FAKE_DIR/no_verdict_then_pass.sh" <<'EOF'
#!/usr/bin/env bash
set -u
STAMP_DIR="${FAKE_STAMP_DIR:?}"
STAMP="$STAMP_DIR/no_verdict_then_pass.ran"
if [[ ! -f "$STAMP" ]]; then
  touch "$STAMP"
  echo "still booting..." >&2
  exit 1
fi
echo "PASS: fake no-verdict recovered"
exit 0
EOF

# 2) Boot-timeout FAIL first, PASS on second → must retry and pass.
cat >"$FAKE_DIR/boot_timeout_then_pass.sh" <<'EOF'
#!/usr/bin/env bash
set -u
STAMP_DIR="${FAKE_STAMP_DIR:?}"
STAMP="$STAMP_DIR/boot_timeout_then_pass.ran"
if [[ ! -f "$STAMP" ]]; then
  touch "$STAMP"
  echo "FAIL: timed out waiting for tty line prompt" >&2
  exit 1
fi
echo "PASS: fake boot-timeout recovered"
exit 0
EOF

# 3) Substantive FAIL (assertion) — must NOT retry; fail immediately.
cat >"$FAKE_DIR/substantive_fail.sh" <<'EOF'
#!/usr/bin/env bash
set -u
STAMP_DIR="${FAKE_STAMP_DIR:?}"
STAMP="$STAMP_DIR/substantive_fail.ran"
# Count invocations; a retry would create a second touch pattern.
if [[ -f "$STAMP" ]]; then
  echo "RETRYED" >"$STAMP_DIR/substantive_fail.retried"
fi
touch "$STAMP"
echo "FAIL: rights intersection denied write unexpectedly" >&2
exit 1
EOF

# 4) Happy path — single PASS, no retry noise required for success.
cat >"$FAKE_DIR/always_pass.sh" <<'EOF'
#!/usr/bin/env bash
set -u
echo "PASS: always"
exit 0
EOF

# 5) qw5-style boot marker timeout, then pass.
cat >"$FAKE_DIR/boot_marker_timeout_then_pass.sh" <<'EOF'
#!/usr/bin/env bash
set -u
STAMP_DIR="${FAKE_STAMP_DIR:?}"
STAMP="$STAMP_DIR/boot_marker.ran"
if [[ ! -f "$STAMP" ]]; then
  touch "$STAMP"
  echo "FAIL: timed out waiting for marker: M7 tty: type a line then Enter" >&2
  exit 1
fi
echo "PASS: marker boot recovered"
exit 0
EOF

# 6) Later-phase timeout (Ctrl-C) — must NOT retry.
cat >"$FAKE_DIR/later_timeout_fail.sh" <<'EOF'
#!/usr/bin/env bash
set -u
STAMP_DIR="${FAKE_STAMP_DIR:?}"
STAMP="$STAMP_DIR/later_timeout.ran"
if [[ -f "$STAMP" ]]; then
  echo "RETRYED" >"$STAMP_DIR/later_timeout.retried"
fi
touch "$STAMP"
echo "FAIL: timed out waiting for Ctrl-C prompt" >&2
exit 1
EOF

chmod +x "$FAKE_DIR"/*.sh
export FAKE_STAMP_DIR="$FAKE_DIR/stamps"
mkdir -p "$FAKE_STAMP_DIR"
: >"$RETRY_LOG"

# --- cases -----------------------------------------------------------------

out="$FAKE_DIR/case.out"

# Case 1: no-verdict → retry → pass
rm -f "$FAKE_STAMP_DIR"/*
set +e
"$WRAP" --name no_verdict_then_pass.sh "$FAKE_DIR/no_verdict_then_pass.sh" >"$out" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "no-verdict case expected rc=0, got $rc; out=$(cat "$out")"
grep -q 'QEMU_HARNESS_RETRY: no_verdict_then_pass.sh reason=no-verdict' "$out" \
  || fail "no-verdict case missing retry line; out=$(cat "$out")"
grep -q 'PASS: fake no-verdict recovered' "$out" \
  || fail "no-verdict case missing PASS; out=$(cat "$out")"
grep -q 'QEMU_HARNESS_RETRY: no_verdict_then_pass.sh reason=no-verdict outcome=pass' "$RETRY_LOG" \
  || fail "no-verdict case not recorded in retry log"

# Case 2: boot-timeout → retry → pass
rm -f "$FAKE_STAMP_DIR"/*
: >"$RETRY_LOG"
set +e
"$WRAP" --name boot_timeout_then_pass.sh "$FAKE_DIR/boot_timeout_then_pass.sh" >"$out" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "boot-timeout case expected rc=0, got $rc; out=$(cat "$out")"
grep -q 'QEMU_HARNESS_RETRY: boot_timeout_then_pass.sh reason=boot-timeout' "$out" \
  || fail "boot-timeout case missing retry line; out=$(cat "$out")"
grep -q 'PASS: fake boot-timeout recovered' "$out" \
  || fail "boot-timeout case missing PASS; out=$(cat "$out")"

# Case 3: substantive FAIL → no retry
rm -f "$FAKE_STAMP_DIR"/*
: >"$RETRY_LOG"
set +e
"$WRAP" --name substantive_fail.sh "$FAKE_DIR/substantive_fail.sh" >"$out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "substantive FAIL expected non-zero rc"
grep -q 'QEMU_HARNESS_RETRY:' "$out" && fail "substantive FAIL must not retry; out=$(cat "$out")"
[[ ! -f "$FAKE_STAMP_DIR/substantive_fail.retried" ]] \
  || fail "substantive FAIL was invoked twice (retry)"
grep -q 'FAIL: rights intersection denied write unexpectedly' "$out" \
  || fail "substantive FAIL message missing; out=$(cat "$out")"

# Case 4: happy path — pass once, no retry line
rm -f "$FAKE_STAMP_DIR"/*
: >"$RETRY_LOG"
set +e
"$WRAP" --name always_pass.sh "$FAKE_DIR/always_pass.sh" >"$out" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "happy path expected rc=0"
grep -q 'PASS: always' "$out" || fail "happy path missing PASS"
grep -q 'QEMU_HARNESS_RETRY:' "$out" && fail "happy path must not print retry; out=$(cat "$out")"
[[ ! -s "$RETRY_LOG" ]] || fail "happy path must not append retry log"

# Case 5: marker-style boot timeout
rm -f "$FAKE_STAMP_DIR"/*
: >"$RETRY_LOG"
set +e
"$WRAP" --name boot_marker_timeout_then_pass.sh "$FAKE_DIR/boot_marker_timeout_then_pass.sh" >"$out" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "marker boot-timeout expected rc=0; out=$(cat "$out")"
grep -q 'reason=boot-timeout' "$out" || fail "marker boot-timeout missing reason; out=$(cat "$out")"

# Case 6: later-phase timeout must not retry
rm -f "$FAKE_STAMP_DIR"/*
: >"$RETRY_LOG"
set +e
"$WRAP" --name later_timeout_fail.sh "$FAKE_DIR/later_timeout_fail.sh" >"$out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "later-phase timeout expected non-zero"
grep -q 'QEMU_HARNESS_RETRY:' "$out" && fail "later-phase timeout must not retry; out=$(cat "$out")"
[[ ! -f "$FAKE_STAMP_DIR/later_timeout.retried" ]] \
  || fail "later-phase timeout was invoked twice"

# Case 7: summary printer
: >"$RETRY_LOG"
echo "QEMU_HARNESS_RETRY: example.sh reason=boot-timeout outcome=pass" >>"$RETRY_LOG"
sum="$("$WRAP" --print-summary)"
grep -q 'QEMU_HARNESS_RETRY_SUMMARY: 1 harness' <<<"$sum" \
  || fail "summary missing count; got: $sum"
grep -q 'example.sh' <<<"$sum" || fail "summary missing harness name; got: $sum"

# Case 8: empty summary
rm -f "$RETRY_LOG"
sum="$(QEMU_HARNESS_RETRY_LOG="$RETRY_LOG" "$WRAP" --print-summary)"
grep -q 'QEMU_HARNESS_RETRY_SUMMARY: none' <<<"$sum" \
  || fail "empty summary wrong; got: $sum"

# Case 9: retry also fails → original rc and output reported
cat >"$FAKE_DIR/boot_timeout_always.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAIL: timed out waiting for tty line prompt" >&2
exit 7
EOF
chmod +x "$FAKE_DIR/boot_timeout_always.sh"
: >"$RETRY_LOG"
set +e
"$WRAP" --name boot_timeout_always.sh "$FAKE_DIR/boot_timeout_always.sh" >"$out" 2>&1
rc=$?
set -e
[[ "$rc" -eq 7 ]] || fail "retry-fail expected original rc=7, got $rc; out=$(cat "$out")"
grep -q 'outcome=fail' "$out" || fail "retry-fail missing outcome=fail; out=$(cat "$out")"
grep -q 'reporting original failure' "$out" || fail "retry-fail missing original note; out=$(cat "$out")"

echo "PASS: run_qemu_harness narrow retry boundary (retry no-verdict/boot-timeout; never substantive FAIL)"
