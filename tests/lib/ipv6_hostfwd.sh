# SPDX-License-Identifier: Apache-2.0
#
# ipv6_hostfwd.sh — shared QEMU IPv6 hostfwd capability probe for tests.
#
# Source from a test after ROOT / QEMU / KERNEL are set:
#   # shellcheck source=tests/lib/ipv6_hostfwd.sh
#   source "$ROOT/tests/lib/ipv6_hostfwd.sh"
#
# Answers one question: can this QEMU on this host bind an IPv6 hostfwd rule
# of the form hostfwd=*:[::1]:PORT-:... ? The decision is a real capability
# probe (not an OS-name check). Result is cached for the life of the process
# so a single test run never launches the probe QEMU more than once.
#
# Usage:
#   if ! reason="$(qemu_ipv6_hostfwd_available)"; then
#     # $reason is a one-line explanation; capability absent
#   fi
#   # return 0 and empty stdout → capability present

# Process-local cache (empty = not yet probed).
_SWOS_IPV6_HOSTFWD_PROBED=""
_SWOS_IPV6_HOSTFWD_OK=""
_SWOS_IPV6_HOSTFWD_REASON=""

# qemu_ipv6_hostfwd_available
#   Return 0 if this QEMU accepts and binds an IPv6 hostfwd rule.
#   Return 1 if QEMU explicitly refused the rule (prints reason on stdout).
#   Other probe failures (missing kernel, unexpected QEMU exit) are treated as
#   "available" so the full test body can still run and fail with real diagnostics —
#   the probe only gates on an explicit hostfwd/bind refusal.
qemu_ipv6_hostfwd_available() {
  if [[ -n "$_SWOS_IPV6_HOSTFWD_PROBED" ]]; then
    if [[ "$_SWOS_IPV6_HOSTFWD_OK" == "1" ]]; then
      return 0
    fi
    printf '%s\n' "$_SWOS_IPV6_HOSTFWD_REASON"
    return 1
  fi

  local qemu="${QEMU:-qemu-system-aarch64}"
  local kernel="${KERNEL:-}"
  local probe_log probe_pidfile qp n port
  local reason=""

  _SWOS_IPV6_HOSTFWD_PROBED=1

  if [[ -z "$kernel" || ! -f "$kernel" ]]; then
    # Cannot probe without a kernel; let the caller run and report its own missing-artifact error.
    _SWOS_IPV6_HOSTFWD_OK=1
    return 0
  fi
  if ! command -v "$qemu" >/dev/null 2>&1 && [[ ! -x "$qemu" ]]; then
    _SWOS_IPV6_HOSTFWD_OK=1
    return 0
  fi

  port=$((51000 + ($$ % 1000)))
  probe_log="$(mktemp -t swiftos-ipv6-hostfwd-probe.XXXXXX)"
  probe_pidfile="$(mktemp -t swiftos-ipv6-hostfwd-probe-pid.XXXXXX)"

  # Minimal netdev: one IPv6 hostfwd literal. Hostfwd bind is decided at netdev
  # setup, not after guest boot — a short live window is enough.
  "$qemu" -M virt -cpu cortex-a72 -m 64M -nographic -no-reboot \
    -pidfile "$probe_pidfile" \
    -netdev "user,id=n0,ipv6=on,hostfwd=tcp:[::1]:${port}-:5555" \
    -device virtio-net-device,netdev=n0 \
    -kernel "$kernel" </dev/null >"$probe_log" 2>&1 &
  qp=$!

  n=0
  while (( n < 40 )); do  # ~4s
    if ! kill -0 "$qp" 2>/dev/null; then
      wait "$qp" 2>/dev/null || true
      # Match only hostfwd setup refusals for the IPv6 literals (not guest panics).
      if grep -qiE \
        "Invalid host forwarding rule.*\[::1\]|Could not set up host forwarding rule 'tcp:\[::1\]|Could not set up host forwarding rule 'udp:\[::1\]|Bad host address" \
        "$probe_log" 2>/dev/null
      then
        reason="$(grep -iE 'host forward|hostfwd|Bad host address' "$probe_log" | head -1 | sed 's/^[[:space:]]*//')"
        [[ -n "$reason" ]] || reason="QEMU refused IPv6 hostfwd rule setup"
        rm -f "$probe_log" "$probe_pidfile"
        _SWOS_IPV6_HOSTFWD_OK=0
        _SWOS_IPV6_HOSTFWD_REASON="$reason"
        printf '%s\n' "$reason"
        return 1
      fi
      # Died for some other reason — not a hostfwd capability skip.
      rm -f "$probe_log" "$probe_pidfile"
      _SWOS_IPV6_HOSTFWD_OK=1
      return 0
    fi
    # Still running after a short settle: netdev (incl. hostfwd bind) succeeded.
    if (( n >= 5 )); then
      kill "$qp" 2>/dev/null || true
      wait "$qp" 2>/dev/null || true
      if [[ -f "$probe_pidfile" ]]; then
        local ppid
        ppid="$(cat "$probe_pidfile" 2>/dev/null || true)"
        [[ -n "$ppid" ]] && { kill "$ppid" 2>/dev/null || true; kill -9 "$ppid" 2>/dev/null || true; }
      fi
      rm -f "$probe_log" "$probe_pidfile"
      _SWOS_IPV6_HOSTFWD_OK=1
      return 0
    fi
    sleep 0.1
    n=$((n + 1))
  done

  kill "$qp" 2>/dev/null || true
  wait "$qp" 2>/dev/null || true
  if [[ -f "$probe_pidfile" ]]; then
    local ppid
    ppid="$(cat "$probe_pidfile" 2>/dev/null || true)"
    [[ -n "$ppid" ]] && { kill "$ppid" 2>/dev/null || true; kill -9 "$ppid" 2>/dev/null || true; }
  fi
  rm -f "$probe_log" "$probe_pidfile"
  _SWOS_IPV6_HOSTFWD_OK=1
  return 0
}
