#!/usr/bin/env bash
# Process containment for runs that no systemd unit owns (R14, P2.7).
#
# Timer fires already live in their service's control group. A `meute drain`
# or web-loop run.sh does not, so an engine straggler would outlive it. When
# systemd-run works, run.sh is started in a transient user scope instead and
# whatever it leaves behind dies with the scope. Anywhere else this is a no-op.
#
# MEUTE_SYSTEMD_RUN names the binary (tests stub it); MEUTE_SCOPE=off disables.
# tui/runctl.py mirrors this probe for the web loop.

SCOPE_CMD=()

# scope_init: fill SCOPE_CMD with the command prefix, or leave it empty.
scope_init() {
  local bin="${MEUTE_SYSTEMD_RUN:-systemd-run}"
  SCOPE_CMD=()
  [[ "${MEUTE_SCOPE:-on}" != off ]] || return 0
  command -v "$bin" >/dev/null 2>&1 || return 0
  "$bin" --user --scope --collect --quiet true >/dev/null 2>&1 || return 0
  SCOPE_CMD=("$bin" --user --scope --collect --quiet)
}
