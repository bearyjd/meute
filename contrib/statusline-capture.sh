#!/usr/bin/env bash
#
# Status-line wrapper that snapshots the subscription's rate-limit windows.
#
# Claude Code feeds its status line a JSON document on stdin, and for Pro/Max
# seats that document carries `rate_limits.five_hour` and `rate_limits.seven_day`
# — each with `used_percentage` and `resets_at`. That is the subscription
# balance bin/quota.sh's contract wants and that no CLI subcommand exposes.
# The status line re-runs every time the human works interactively, which is
# exactly when the balance changes, so capturing it here keeps the snapshot as
# fresh as the thing it measures.
#
# This script sits in front of whatever status line was already configured and
# is otherwise invisible: it writes the snapshot, then hands the same stdin to
# the original command and lets its output through untouched. Nothing here may
# ever break the status line — every failure path falls through to the wrapped
# command.
#
# Installed by `meute install-statusline`, which rewrites the statusLine entry
# in Claude Code's settings.json to:
#
#   <meute>/contrib/statusline-capture.sh -- '<original command>'
#
# The original command is kept verbatim as the argument, so restoring it is a
# copy-paste, and `meute install-statusline` is idempotent because it can see
# it is already wrapped.
#
# Snapshot: $MEUTE_ROOT/state/rate-limits.json, read by contrib/quota-subscription.sh.

readonly MEUTE_ROOT="${MEUTE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly SNAPSHOT="${MEUTE_ROOT}/state/rate-limits.json"

[[ "${1:-}" == "--" ]] && shift
wrapped="${1:-}"

input="$(cat)"

# Only a document that actually carries at least one window is worth writing.
# A snapshot with nothing in it would read as "no source", which is worse than
# leaving the previous, real snapshot in place.
if command -v jq >/dev/null 2>&1; then
  snapshot="$(jq -c --arg now "$(date +%s)" '
    .rate_limits // {} | {
      captured_at: ($now | tonumber),
      five_hour: (.five_hour // null),
      seven_day: (.seven_day // null),
    } | select(.five_hour != null or .seven_day != null)
  ' <<< "$input" 2>/dev/null)"
  # The status line renders many times a minute. Rewrite only when a window
  # actually moved, or once a minute regardless so captured_at stays an honest
  # "last confirmed" stamp -- not on every render.
  if [[ -n "$snapshot" ]] && ! jq -e --argjson new "$snapshot" '
        (.captured_at // 0) > ($new.captured_at - 60)
        and (.five_hour == $new.five_hour) and (.seven_day == $new.seven_day)
      ' "$SNAPSHOT" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$SNAPSHOT")" 2>/dev/null
    tmp="$(mktemp "${SNAPSHOT}.XXXXXX" 2>/dev/null)" \
      && printf '%s\n' "$snapshot" > "$tmp" \
      && mv -f "$tmp" "$SNAPSHOT"
  fi
fi

[[ -n "$wrapped" ]] || exit 0
exec sh -c "$wrapped" <<< "$input"
