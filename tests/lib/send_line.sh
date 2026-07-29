# SPDX-License-Identifier: Apache-2.0
#
# Shared paced serial input for in-QEMU harnesses.
#
# QEMU feeds the guest PL011 UART from a host FIFO. The PL011 RX FIFO is only
# 16 bytes. If the harness types a command line before the guest is reading
# (e.g. right after await matches "Welcome to swift-os, root" or even
# "M12c: shell ready" while ash is still being exec'd from disk), the FIFO
# overflows and the *leading* characters are lost — the shell sees
# `lo-redir > /tmp/r` instead of `echo hello-redir > /tmp/r`.
#
# console-login prints "Welcome …" and "M12c: shell ready" *before* exec of the
# login shell (see userland/console-login.swift). Those markers prove login
# succeeded, not that anything is draining the UART. Wait for the shell itself
# with await_shell_ready before the first post-login send_line.
#
# This helper:
#   1. await_shell_ready — reactive wait until the guest shell is demonstrably up
#      (ash banner anywhere in the log, else an echo handshake with retries).
#      Best-effort: on timeout warns and continues; never fails the harness.
#   2. Settles briefly before typing so a just-ready shell can enter its read.
#   3. Types one character at a time (unless SEND_LINE_MODE=whole).
#   4. Sends newline (send_line) and a short post-line delay.
#
# Environment (optional; read at call time):
#   SEND_LINE_FD       — bash FD to QEMU stdin (default: 3)
#   SEND_CHAR_DELAY    — sleep between characters (default: 0.01)
#   SEND_SEND_DELAY    — sleep after newline / after send_text (default: 0.08)
#   SEND_LINE_SETTLE   — leading settle before typing (default: 0.05; 0 = off)
#   SEND_LINE_MODE     — "paced" (default) or "whole" (single write; npm_install)
#   SEND_LINE_BURST    — opt-in: if set, settle only when value is 0, then set to 1
#                        so consecutive lines skip settle. Unset = settle every line.
#   SHELL_READY_TIMEOUT — default max seconds for await_shell_ready (default: 60)
#
# Harness-specific override names (REDIRECT_CHAR_DELAY, …) stay valid when the
# harness maps them before sourcing:
#   SEND_CHAR_DELAY="${REDIRECT_CHAR_DELAY:-0.01}"
#   SEND_SEND_DELAY="${REDIRECT_SEND_DELAY:-0.08}"
#   # shellcheck source=tests/lib/send_line.sh
#   source "$ROOT/tests/lib/send_line.sh"
#
# Usage:
#   source "$ROOT/tests/lib/send_line.sh"
#   await "Welcome to swift-os, root" 30 || fail "login"
#   await_shell_ready "$LOG" 60   # best-effort; never fails the harness
#   send_line 'echo hello'
#   send_text $'ihello\033'   # no trailing newline (e.g. vi)

# Opt-in burst helpers: settle once at the start of a multi-line streak.
send_line_begin_burst() { SEND_LINE_BURST=0; }
send_line_end_burst()   { unset SEND_LINE_BURST; }

_send_line_maybe_settle() {
  local settle="${SEND_LINE_SETTLE:-0.05}"

  case "$settle" in
    0|0.0|0.00|0.000) return 0 ;;
  esac

  # Opt-in burst: settle only when SEND_LINE_BURST is 0; then mark in-burst.
  # When SEND_LINE_BURST is unset, settle every call (safe default for CI).
  if [[ -n "${SEND_LINE_BURST+x}" ]]; then
    if [[ "${SEND_LINE_BURST}" == "1" ]]; then
      return 0
    fi
    sleep "$settle"
    SEND_LINE_BURST=1
    return 0
  fi

  sleep "$settle"
}

# _shell_ready_log LOG — full serial log, CRs stripped (banner may predate call).
_shell_ready_log() {
  local log="$1"
  if [[ ! -f "$log" ]]; then
    return 0
  fi
  tr -d '\r' <"$log" 2>/dev/null || true
}

# _shell_ready_tail LOG START_BYTES — serial bytes written after START_BYTES.
# Used only for the handshake token (must be fresh; banner may predate call).
_shell_ready_tail() {
  local log="$1" start="$2"
  if [[ ! -f "$log" ]]; then
    return 0
  fi
  # tail -c +N is 1-based; start is a prior wc -c count (0 = whole file).
  tail -c "+$((start + 1))" "$log" 2>/dev/null | tr -d '\r' || true
}

# await_shell_ready LOGFILE [MAXSEC]
#
# Wait until the interactive login shell is up and can drain UART input.
# Call this after login markers (Welcome / M12c: shell ready) and before the
# first command typed into that shell.
#
# Primary evidence: busybox ash prints "built-in shell (ash)" only after it has
# been exec'd and entered interactive mode — not before. Scan the *whole* log:
# harnesses that already awaited "M12c: shell ready" or Welcome often race ash
# past the banner before this helper starts, so a post-entry-only scan can miss
# the only banner of the boot and never match.
#
# Fallback: if that banner never appears (non-ash login shell, or a build that
# suppresses it), send `echo <unique-token>` and wait for the token in *new* log
# content (after entry), re-sending every 2s until timeout. Seeing the token
# proves a reader is draining and echoing — stronger than a fixed sleep.
#
# Best-effort: returns 0 when ready *or* on timeout. On timeout prints a
# greppable WARN naming the harness and proceeds — a readiness probe must never
# be the reason a healthy test fails (pre-probe paced typing is the fallback).
# Returns 2 only for a programming error (missing LOGFILE). Does not change
# harness assertion ceilings or settle defaults.
await_shell_ready() {
  local log="$1"
  local max="${2:-${SHELL_READY_TIMEOUT:-60}}"
  local fd="${SEND_LINE_FD:-3}"
  local banner="built-in shell (ash)"
  local token="__swos_shell_ready_${RANDOM}_${RANDOM}__"
  local start=0
  local n=0
  local max_ticks=$((max * 10))
  local whole chunk
  local probe_period=20   # re-send handshake every 2.0 s (0.1 s ticks)
  local probe_after=10    # first probe only after 1.0 s without banner
  local harness
  harness="$(basename "${0:-unknown}")"

  if [[ -z "$log" ]]; then
    echo "await_shell_ready: LOGFILE required" >&2
    return 2
  fi
  if [[ -f "$log" ]]; then
    start="$(wc -c <"$log" | tr -d '[:space:]')"
  fi

  while (( n < max_ticks )); do
    # Banner: whole log (may have been emitted before this call started).
    whole="$(_shell_ready_log "$log")"
    if [[ "$whole" == *"$banner"* ]]; then
      return 0
    fi
    # Handshake token: only content written after entry (must be our probe).
    chunk="$(_shell_ready_tail "$log" "$start")"
    if [[ "$chunk" == *"$token"* ]]; then
      return 0
    fi

    # Handshake fallback: only after a short passive wait, then periodically.
    # Primary path (ash banner) never types, so wall clock tracks the guest.
    if (( n >= probe_after && (n - probe_after) % probe_period == 0 )); then
      # Whole short write: we only need *some* full probe to land once the shell
      # is reading; pacing is for command entry, not this readiness probe.
      printf 'echo %s\n' "$token" >&"$fd" || true
    fi

    sleep 0.1
    n=$((n + 1))
  done

  # Greppable: WARN: await_shell_ready: timed out
  echo "WARN: await_shell_ready: timed out after ${max}s in harness ${harness} — proceeding without confirmed shell readiness" >&2
  return 0
}

# send_text TEXT — paced characters, no newline.
send_text() {
  local text="$1"
  local delay="${SEND_CHAR_DELAY:-0.01}"
  local post="${SEND_SEND_DELAY:-0.08}"
  local fd="${SEND_LINE_FD:-3}"
  local i

  _send_line_maybe_settle

  if [[ "${SEND_LINE_MODE:-paced}" == "whole" ]]; then
    printf '%s' "$text" >&"$fd"
  else
    for (( i = 0; i < ${#text}; i++ )); do
      printf '%s' "${text:i:1}" >&"$fd"
      sleep "$delay"
    done
  fi
  sleep "$post"
}

# send_line LINE — paced characters, newline, post delay.
send_line() {
  local line="$1"
  local delay="${SEND_CHAR_DELAY:-0.01}"
  local post="${SEND_SEND_DELAY:-0.08}"
  local fd="${SEND_LINE_FD:-3}"
  local i

  _send_line_maybe_settle

  if [[ "${SEND_LINE_MODE:-paced}" == "whole" ]]; then
    # Whole-line write: char-by-char can split on `&&` (see npm_install_test).
    printf '%s\n' "$line" >&"$fd"
  else
    for (( i = 0; i < ${#line}; i++ )); do
      printf '%s' "${line:i:1}" >&"$fd"
      sleep "$delay"
    done
    printf '\n' >&"$fd"
  fi
  sleep "$post"
}
