# SPDX-License-Identifier: Apache-2.0
#
# Shared paced serial input for in-QEMU harnesses.
#
# QEMU feeds the guest PL011 UART from a host FIFO. The PL011 RX FIFO is only
# 16 bytes. If the harness types a command line before the guest is reading
# (e.g. right after await matches "Welcome to swift-os, root" while ash is
# still starting), the FIFO overflows and the *leading* characters are lost —
# the shell sees `lo-redir > /tmp/r` instead of `echo hello-redir > /tmp/r`.
# Per-character pacing alone does not prevent that: 16 unread chars at 0.01 s
# fill the FIFO in 0.16 s.
#
# This helper:
#   1. Settles briefly before typing so the guest is consuming input first.
#   2. Types one character at a time (unless SEND_LINE_MODE=whole).
#   3. Sends newline (send_line) and a short post-line delay.
#
# Environment (optional; read at call time):
#   SEND_LINE_FD       — bash FD to QEMU stdin (default: 3)
#   SEND_CHAR_DELAY    — sleep between characters (default: 0.01)
#   SEND_SEND_DELAY    — sleep after newline / after send_text (default: 0.08)
#   SEND_LINE_SETTLE   — leading settle before typing (default: 0.05; 0 = off)
#   SEND_LINE_MODE     — "paced" (default) or "whole" (single write; npm_install)
#   SEND_LINE_BURST    — opt-in: if set, settle only when value is 0, then set to 1
#                        so consecutive lines skip settle. Unset = settle every line.
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
