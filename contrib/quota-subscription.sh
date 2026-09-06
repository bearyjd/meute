#!/usr/bin/env bash
#
# Quota source: the real subscription balance, from the status-line snapshot.
#
# Reads state/rate-limits.json, written by contrib/statusline-capture.sh every
# time the human works interactively. Reports the percentage still available
# in whichever pool is scarcer — the 5-hour window or the 7-day one — which is
# what bin/quota.sh's contract asks for. This is the gate PRP-001 §3 step 4
# describes: a scheduled chore must never consume the window the human wants
# for interactive work, and the only way to know that window's state is to
# read the subscription's own accounting. meute's spend ceiling
# (quota-self-budget.sh) cannot stand in for it: that caps what meute takes,
# and knows nothing about what the human already took.
#
# A window whose `resets_at` has passed is counted as 0% used: it rolled over
# since the snapshot, and whatever has been consumed in the new window is
# unknown. That is deliberately optimistic — the alternative, refusing to run
# until the human next opens a session, would idle the fleet exactly when the
# human is away and the capacity is going spare. The 429 auto-pause in
# bin/run.sh is the backstop for a window that turns out to be fuller than
# this assumed.
#
# Output: one integer 0-100. Exit 1 when there is no usable snapshot; the
# runner then declines rather than guess.

set -Eeuo pipefail

readonly MEUTE_ROOT="${MEUTE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly SNAPSHOT="${MEUTE_ROOT}/state/rate-limits.json"
# Injectable so the rollover arithmetic is testable without waiting a week.
now="${MEUTE_NOW:-$(date +%s)}"

[[ -f "$SNAPSHOT" ]] || { printf 'quota-subscription: no snapshot at %s\n' "$SNAPSHOT" >&2; exit 1; }
command -v jq >/dev/null || { printf 'quota-subscription: jq is required\n' >&2; exit 1; }

remaining="$(jq -r --argjson now "$now" '
  def used(w):
    if w == null then empty
    elif (w.resets_at // 0) <= $now then 0
    else (w.used_percentage // empty) end;
  [used(.five_hour), used(.seven_day)]
  | if length == 0 then "none"
    else 100 - (max | ceil) | [., 0] | max | [., 100] | min end
' "$SNAPSHOT" 2>/dev/null)" || { printf 'quota-subscription: snapshot is not valid JSON\n' >&2; exit 1; }

[[ "$remaining" =~ ^[0-9]+$ ]] || { printf 'quota-subscription: snapshot carries no rate-limit window\n' >&2; exit 1; }
printf '%s\n' "$remaining"
