#!/usr/bin/env bash
# Process containment for runs that no systemd unit owns (R14, P2.7).
#
# Timer fires already live in their service's control group. A `meute drain`
# or web-loop run.sh does not, so an engine straggler would outlive it. When
# systemd-run works, run.sh is started in a named transient user scope, and
# the scope is stopped once run.sh returns: a scope is NOT stopped when its
# main process exits, so the stop is what kills whatever run.sh left behind.
# Anywhere else this is a no-op.
#
# MEUTE_SYSTEMD_RUN / MEUTE_SYSTEMCTL name the binaries (tests stub them);
# MEUTE_SCOPE=off disables. tui/runctl.py mirrors this for the web loop.

SCOPE_CMD=()
SCOPE_SEQ=0

# scope_init: fill SCOPE_CMD with the command prefix, or leave it empty.
scope_init() {
  local bin="${MEUTE_SYSTEMD_RUN:-systemd-run}"
  SCOPE_CMD=()
  [[ "${MEUTE_SCOPE:-on}" != off ]] || return 0
  command -v "$bin" >/dev/null 2>&1 || return 0
  "$bin" --user --scope --collect --quiet true >/dev/null 2>&1 || return 0
  SCOPE_CMD=("$bin" --user --scope --collect --quiet)
}

# scope_run CMD...: run CMD in its own scope (if scope_init found one), then
# stop that scope so no straggler survives. Returns CMD's exit status.
scope_run() {
  (( ${#SCOPE_CMD[@]} )) || { "$@"; return; }
  local unit="meute-run-$$-$(( ++SCOPE_SEQ ))-${RANDOM}" rc=0
  "${SCOPE_CMD[@]}" --unit="$unit" "$@" || rc=$?
  "${MEUTE_SYSTEMCTL:-systemctl}" --user stop "${unit}.scope" >/dev/null 2>&1 || true
  return "$rc"
}
