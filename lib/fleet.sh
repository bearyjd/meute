#!/usr/bin/env bash
#
# Fleet-wide accounting shared by bin/run.sh and bin/meute.
#
# These read live state -- the ISO-week log and the surviving scratch branches --
# rather than a counter, so deleting a branch or pruning the log immediately
# changes the answer. That is intentional: merging a tier-3 draft should free a
# slot without anyone telling the runner about it.
#
# Expects from the caller: MEUTE_ROOT, MANIFEST_PY, MANIFEST, LOG_FILE, THIS_WEEK.
# fleet_load_policy sets QUOTA_FLOOR / COMMUNITY_SHARE / TIER3_CAP / BRANCH_PREFIX.
# fleet_load_scope  sets TIER3_TASKS / REPO_PATHS.

fleet_load_policy() {
  local policy
  policy="$(python3 "$MANIFEST_PY" policy "$MANIFEST")" || return 1
  QUOTA_FLOOR="$(jq -r '.quota_floor_percent' <<< "$policy")"
  COMMUNITY_SHARE="$(jq -r '.community_share' <<< "$policy")"
  TIER3_CAP="$(jq -r '.tier3_max_in_flight' <<< "$policy")"
  BRANCH_PREFIX="$(jq -r '.branch_prefix' <<< "$policy")"
  POLICY_WEEKLY_RUNS="$(jq -r '.weekly_runs' <<< "$policy")"
  POLICY_WEEKLY_COST="$(jq -r '.weekly_cost_usd' <<< "$policy")"
}

# Tier-3 accounting spans both slots, so gather the whole fleet, not one slot.
fleet_load_scope() {
  local all_file
  all_file="$(mktemp)"
  python3 "$MANIFEST_PY" queue "$MANIFEST" daily  >  "$all_file" || { rm -f "$all_file"; return 1; }
  python3 "$MANIFEST_PY" queue "$MANIFEST" weekly >> "$all_file" || { rm -f "$all_file"; return 1; }
  TIER3_TASKS="$(jq -rs 'map(select(.tier == "tier3") | .task) | unique | .[]' "$all_file")"
  REPO_PATHS="$(jq -rs 'map(.path) | unique | .[]' "$all_file")"
  rm -f "$all_file"
}

week_runs() {
  local kind="${1:-}"
  [[ -f "$LOG_FILE" ]] || { printf '0\n'; return 0; }
  awk -v wk="week=${THIS_WEEK}" -v kf="$kind" '
    index($0, wk) == 0        { next }
    index($0, "status=skipped") { next }
    kf != "" && index($0, "kind=" kf) == 0 { next }
    { n++ } END { print n + 0 }' "$LOG_FILE"
}

# 80/20 by design: a community run is allowed only while it keeps the community
# share of this ISO week's runs at or under policy.community_share.
community_allowed() {
  local total community
  total="$(week_runs)"
  community="$(week_runs community)"
  awk -v c="$community" -v t="$total" -v s="$COMMUNITY_SHARE" \
      'BEGIN { exit !((c + 1) <= s * (t + 1)) }'
}

# In-flight tier-3 work is measured by counting surviving scratch branches for
# tier-3 tasks across the whole fleet. Merging or deleting a branch frees a slot.
tier3_in_flight() {
  local count=0 path task
  while read -r path; do
    [[ -d "$path/.git" || -f "$path/.git" ]] || continue
    while read -r task; do
      [[ -n "$task" ]] || continue
      count=$(( count + $(git -C "$path" branch --list "${BRANCH_PREFIX}/${task}-*" | wc -l) ))
    done <<< "$TIER3_TASKS"
  done <<< "$REPO_PATHS"
  printf '%s\n' "$count"
}

# Wire the manifest-declared ceiling, if there is one and the operator has not
# pointed us at a real subscription probe. Returns 0 if a self-budget is now in
# force, 1 if none applies.
#
# quota_floor_percent reserves headroom for the human against a real pool
# reading. A self-budget is already meute's own allocation, so the floor would
# double-count and make the declared number lie — budget 10 with a 30% floor
# would stop at 7. Against a self-budget the declared ceiling IS the stop point;
# floor 1 rather than 0, so an exhausted budget (remaining 0) still trips the
# `remaining < floor` comparison.
fleet_wire_self_budget() {
  [[ -z "${MEUTE_QUOTA_CMD:-}" ]] || return 1
  if [[ "${POLICY_WEEKLY_RUNS:-null}" != "null" && -n "${POLICY_WEEKLY_RUNS:-}" ]]; then
    export MEUTE_WEEKLY_RUNS="$POLICY_WEEKLY_RUNS"
  elif [[ "${POLICY_WEEKLY_COST:-null}" != "null" && -n "${POLICY_WEEKLY_COST:-}" ]]; then
    export MEUTE_WEEKLY_COST_USD="$POLICY_WEEKLY_COST"
  else
    return 1
  fi
  export MEUTE_QUOTA_CMD="${MEUTE_ROOT}/contrib/quota-self-budget.sh"
  QUOTA_FLOOR=1
  return 0
}
