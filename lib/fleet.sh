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

# --------------------------------------------------------------------------
# The pause.
#
# The quota gate cannot protect you from yourself. `quota-self-budget.sh` caps
# meute against meute's own spend and says so in its own header: it cannot see
# your interactive usage. So `meute status` can read 100% while your
# subscription pool is nearly gone, and the 03:17 slot then spends the window
# you wanted for real work — the one thing PRP-001 §1 forbids. This is the
# manual override: you tell the fleet to stand down, and it declines every slot
# until the hold expires.
#
# Bounded on purpose. An unbounded pause is a fleet that looks configured and
# never runs, which is a failure this repo has already shipped once; a hold
# always carries an expiry and lifts itself when it passes.
#
# The expiry is absolute epoch seconds, not a formatted local time, because the
# timers execute on the host while the hold may well be set from a container.
# state/ is gitignored, so a hold is local to this machine, not fleet config.
#
# Expects HOLD_FILE from the caller.
# --------------------------------------------------------------------------
now_epoch() { printf '%s\n' "${MEUTE_NOW:-$(date +%s)}"; }

hold_until_human() { date -d "@$1" '+%a %Y-%m-%d %H:%M' 2>/dev/null || printf '%s\n' "$1"; }

# 45m 6h 3d 2w -> seconds. Rejects 0 and anything past a year: a hold you cannot
# remember setting is indistinguishable from a broken fleet.
hold_duration_seconds() {
  local spec="$1" n unit secs
  [[ "$spec" =~ ^([0-9]+)([mhdw])$ ]] || return 1
  n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  case "$unit" in
    m) secs=$(( n * 60 )) ;;
    h) secs=$(( n * 3600 )) ;;
    d) secs=$(( n * 86400 )) ;;
    w) secs=$(( n * 604800 )) ;;
  esac
  (( secs > 0 && secs <= 31536000 )) || return 1
  printf '%s\n' "$secs"
}

# An emptied file reads as "a hold was set here" to anyone looking at the
# directory, so lifting one leaves nothing behind.
hold_clear() {
  kv_del "$HOLD_FILE" hold
  [[ -s "$HOLD_FILE" ]] || rm -f "$HOLD_FILE"
}

# Writes the hold unconditionally. Prints the resulting absolute epoch so the
# caller can report it without recomputing now_epoch() a second time.
hold_set() {
  local secs="$1" reason="$2" until
  until=$(( $(now_epoch) + secs ))
  reason="${reason//$'\t'/ }"; reason="${reason//$'\n'/ }"
  kv_set_row "$HOLD_FILE" hold "$until" "$reason"
  printf '%s\n' "$until"
}

# Sets a hold only if none is active or the active one expires sooner than
# this would -- an automatic hold (e.g. a provider rate limit) must never cut
# a longer hold the user set on purpose short. Prints the hold's final epoch,
# whether that came from this call or the one already in force.
hold_extend() {
  local secs="$1" reason="$2" candidate
  candidate=$(( $(now_epoch) + secs ))
  if hold_active && (( HOLD_UNTIL >= candidate )); then
    printf '%s\n' "$HOLD_UNTIL"
  else
    hold_set "$secs" "$reason"
  fi
}

# Sets HOLD_UNTIL / HOLD_REASON and returns 0 when a hold is in force. An
# expired hold answers no, so it lifts itself without anyone running `resume`.
hold_active() {
  HOLD_UNTIL=""; HOLD_REASON=""
  local row until reason
  row="$(kv_row "$HOLD_FILE" hold)"
  [[ -n "$row" ]] || return 1
  IFS=$'\t' read -r _ until reason <<< "$row"
  [[ "$until" =~ ^[0-9]+$ ]] || return 1
  (( until > $(now_epoch) )) || return 1
  HOLD_UNTIL="$until"; HOLD_REASON="$reason"
}

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
