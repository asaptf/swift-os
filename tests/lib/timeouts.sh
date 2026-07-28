# SPDX-License-Identifier: Apache-2.0
#
# Shared QEMU harness timeout ceilings.
#
# DEMO_BOOT_TIMEOUT — poll ceiling (seconds) for the *first* await after QEMU
# is launched that covers the pre-login demo boot, **by role**, not by marker
# text. That await may wait for "M7 tty: type a line then Enter", "M12c: shell
# ready" (minimal disks with no ttydemo/console-login), a login prompt, or any
# other end-of-demo readiness marker. The path runs many milestone demos and
# several EL0 programs.
#
# Slow nightly runners have timed out past 240 s still mid-demo (e.g. log_export
# at 248 s; vfs_disk at 90 s mid-sequence). Default 480 s is 2× the previous
# ceiling and tracks the observed ~2× suite wall-clock variance (34 min vs
# 18 min make test) with real headroom. This is a ceiling, not a sleep — a
# healthy boot returns as soon as the marker appears, so `make test` wall clock
# does not grow when everything passes.
#
# Do NOT use DEMO_BOOT_TIMEOUT for later awaits (M7 Ctrl-C response, login /
# password interaction, assertion markers, negative checks). Those stay short
# so real hangs fail fast. Also leave harnesses whose first await is genuinely
# an early kernel assertion (or a non-demo boot) on their own short ceilings.
#
# Override (either works; DEMO_BOOT_TIMEOUT wins if both are set):
#   DEMO_BOOT_TIMEOUT=<seconds>
#   TIMEOUT=<seconds>          # legacy name used by several harnesses
#
# Important: source this file *before* any script-local
#   TIMEOUT="${TIMEOUT:-N}"
# default that is meant only as an assertion ceiling. Otherwise a low local
# default would shrink the boot budget. Scripts that previously used TIMEOUT
# solely for the first boot await should use "$DEMO_BOOT_TIMEOUT" instead.
#
# Usage:
#   ROOT="$(cd "$(dirname "$0")/.." && pwd)"
#   # shellcheck source=tests/lib/timeouts.sh
#   source "$ROOT/tests/lib/timeouts.sh"
#   await "<first readiness marker>" "$DEMO_BOOT_TIMEOUT" || ...

if [[ -z "${DEMO_BOOT_TIMEOUT:-}" ]]; then
  if [[ -n "${TIMEOUT:-}" ]]; then
    DEMO_BOOT_TIMEOUT="$TIMEOUT"
  else
    DEMO_BOOT_TIMEOUT=480
  fi
fi
