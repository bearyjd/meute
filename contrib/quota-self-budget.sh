#!/usr/bin/env bash
#
# MEUTE_QUOTA_CMD adapter: cap meute against a budget YOU set, from meute's own
# run log. Needs nothing external.
#
#   MEUTE_WEEKLY_RUNS=20 MEUTE_QUOTA_CMD='contrib/quota-self-budget.sh' ./bin/run.sh daily
#
# WHAT THIS IS NOT: a reading of your Claude subscription pool. It cannot see
# your interactive usage, so it cannot know how much of the week you have already
# spent yourself. Reading the real rolling 5-hour / weekly pool requires a
# claude.ai session cookie obtained through a browser login — see
# contrib/quota-llm-usage-tracker.sh.
#
# WHAT IT IS: a hard ceiling on meute's own footprint, which is most of what the
# gate is for. It answers "has the fleet had enough this week?", not "how much is
# left?". A self-cap you actually have is worth more than a true reading you do
# not.
#
# Budget, in precedence order (set exactly one):
#   MEUTE_WEEKLY_RUNS      max successful runs per ISO week
#   MEUTE_WEEKLY_COST_USD  max summed list-price-equivalent cost per ISO week
#
# The cost figures in state/log are the list-price equivalent of work already
# paid for by the subscription. They are a proxy for effort, not money owed.
set -Eeuo pipefail

readonly MEUTE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly LOG="${MEUTE_ROOT}/state/log"
readonly WEEK="$(date +%G-%V)"

if [[ -n "${MEUTE_WEEKLY_RUNS:-}" && -n "${MEUTE_WEEKLY_COST_USD:-}" ]]; then
  echo "quota-self: set MEUTE_WEEKLY_RUNS or MEUTE_WEEKLY_COST_USD, not both" >&2
  exit 1
fi

if [[ -z "${MEUTE_WEEKLY_RUNS:-}${MEUTE_WEEKLY_COST_USD:-}" ]]; then
  echo "quota-self: set MEUTE_WEEKLY_RUNS or MEUTE_WEEKLY_COST_USD to use this adapter" >&2
  exit 1
fi

# Only completed runs count. Skips consumed nothing.
used="$(awk -F'\t' -v wk="week=${WEEK}" -v mode="${MEUTE_WEEKLY_RUNS:+runs}" '
  index($0, wk) == 0            { next }
  index($0, "status=skipped")   { next }
  {
    if (mode == "runs") { n += 1; next }
    for (i = 1; i <= NF; i++)
      if ($i ~ /^cost=/) { split($i, a, "="); if (a[2] + 0 > 0) n += a[2] }
  }
  END { printf "%.4f", n + 0 }' "$LOG" 2>/dev/null || echo 0)"

budget="${MEUTE_WEEKLY_RUNS:-${MEUTE_WEEKLY_COST_USD}}"

awk -v used="$used" -v budget="$budget" 'BEGIN {
  if (budget + 0 <= 0) { print "quota-self: budget must be > 0" > "/dev/stderr"; exit 1 }
  pct = (1 - used / budget) * 100
  if (pct < 0)   pct = 0
  if (pct > 100) pct = 100
  printf "%d\n", int(pct + 0.5)
}'
