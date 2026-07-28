# SPDX-License-Identifier: Apache-2.0
#
# Shared QEMU harness timeout ceilings.
#
# DEMO_BOOT_TIMEOUT — poll ceiling (seconds) for the *first* await that covers
# the pre-login demo boot: QEMU start → "M7 tty: type a line then Enter".
# That path runs many milestone demos and several EL0 programs; slow nightly
# runners sit near ~120 s. Default 240 s leaves a real margin. This is a
# ceiling, not a sleep — a healthy boot returns as soon as the marker appears,
# so `make test` wall clock does not grow when everything passes.
#
# Do NOT use DEMO_BOOT_TIMEOUT for later awaits (M7 Ctrl-C response, login /
# password interaction, assertion markers). Those stay short so real hangs
# fail fast.
#
# Override (either works; DEMO_BOOT_TIMEOUT wins if both are set):
#   DEMO_BOOT_TIMEOUT=<seconds>
#   TIMEOUT=<seconds>          # legacy name used by several harnesses
#
# Important: source this file *before* any script-local
#   TIMEOUT="${TIMEOUT:-N}"
# default that is meant only as an assertion ceiling. Otherwise a low local
# default would shrink the boot budget. Scripts that previously used TIMEOUT
# solely for the first M7 await should use "$DEMO_BOOT_TIMEOUT" instead.
#
# Usage:
#   ROOT="$(cd "$(dirname "$0")/.." && pwd)"
#   # shellcheck source=tests/lib/timeouts.sh
#   source "$ROOT/tests/lib/timeouts.sh"
#   await "M7 tty: type a line then Enter" "$DEMO_BOOT_TIMEOUT" || ...

if [[ -z "${DEMO_BOOT_TIMEOUT:-}" ]]; then
  if [[ -n "${TIMEOUT:-}" ]]; then
    DEMO_BOOT_TIMEOUT="$TIMEOUT"
  else
    DEMO_BOOT_TIMEOUT=240
  fi
fi
