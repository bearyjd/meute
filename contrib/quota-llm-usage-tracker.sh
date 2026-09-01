#!/usr/bin/env bash
#
# MEUTE_QUOTA_CMD adapter for llm-usage-tracker.
#   https://github.com/bearyjd/llm-usage-tracker
#
# Prints the percentage of Claude subscription capacity still available, which is
# exactly what bin/quota.sh expects from MEUTE_QUOTA_CMD.
#
#   MEUTE_QUOTA_CMD='contrib/quota-llm-usage-tracker.sh' ./bin/run.sh daily
#
# Requires the tracker's REST API to be reachable (its daemon, or `uvicorn` on the
# backend). Set LUT_URL if it is not on the default host/port.
#
# Written against the tracker's verified schema, not guessed:
#   GET /api/status -> list[SnapshotOut]
#   SnapshotOut{provider, source, messages_used, messages_limit, messages_window_hours}
#   backend/recommendations.py:_is_percentage_based -> provider=="claude" and
#     messages_limit == 100, in which case messages_used IS the utilisation percent.
#   backend/collectors/claude.py already picks the more restrictive of the 5-hour
#     and 7-day windows, so the snapshot is the binding constraint and this script
#     does not need to min() across windows.
#
# NOTE: verified against the tracker's source, but not run against a live instance
# on the machine this was written on. Check it before trusting the gate:
#     contrib/quota-llm-usage-tracker.sh ; echo "exit=$?"
# It must print one integer 0-100 and exit 0. Any other behaviour makes the runner
# decline to run, which is the safe direction to fail.
set -Eeuo pipefail

# 48372 is the tracker's own default (backend/cli.py: `serve` binds there unless
# --port overrides it) -- verified against the source after this repo turned out
# not to have the tracker installed at all, which is what prompted the check.
readonly URL="${LUT_URL:-http://127.0.0.1:48372}"

command -v curl >/dev/null || { echo "quota-lut: curl is required" >&2; exit 1; }
command -v jq   >/dev/null || { echo "quota-lut: jq is required" >&2; exit 1; }

response="$(curl -fsS --max-time 10 "${URL}/api/status" 2>/dev/null)" || {
  echo "quota-lut: could not reach ${URL}/api/status - is the tracker daemon running?" >&2
  exit 1
}

# Latest percentage-based Claude subscription snapshot.
used="$(jq -r '
  [ .[]
    | select(.provider == "claude" and .source == "subscription")
    | select(.messages_limit == 100 and .messages_used != null)
  ]
  | sort_by(.collected_at) | last | .messages_used // empty
' <<< "$response")"

if [[ -z "$used" ]]; then
  echo "quota-lut: no percentage-based Claude subscription snapshot in /api/status" >&2
  echo "quota-lut: run the tracker's collection first (llm-usage status), then retry" >&2
  exit 1
fi

# messages_used is utilisation; the gate wants headroom.
remaining=$(( 100 - used ))
(( remaining < 0 )) && remaining=0
(( remaining > 100 )) && remaining=100
printf '%s\n' "$remaining"
