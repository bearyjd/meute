# Quota snapshot freshness (P2.3, R16).
#
# The subscription gate reads a snapshot the status line wrote some time ago.
# Its percentage is only as true as its age, so the age travels with it: the
# run line records quota_age=, and policy.quota_max_age_hours (unset = off)
# turns a snapshot older than that into "no reading", which the runner already
# declines as code=quota-unknown.
#
# Expects from the caller: MEUTE_ROOT, QUOTA_MAX_AGE_HOURS (fleet_load_policy),
# and QUOTA_PROBE set by quota_for_engine.

declare -A QUOTA_AGE_BY_ENGINE=()
QUOTA_AGE="-"
declare -A QUOTA_STALE=()

# Seconds since the engine's snapshot, "-" when its source is not a snapshot,
# "unknown" when the snapshot carries no captured_at. Cached per engine.
quota_age_of() {
  local engine="$1"
  if [[ -z "${QUOTA_AGE_BY_ENGINE[$engine]+set}" ]]; then
    QUOTA_AGE_BY_ENGINE[$engine]="$(timeout --kill-after=5 35 "${MEUTE_ROOT}/bin/quota.sh" --engine "$engine" --age 9>&- 2>/dev/null)" \
      || QUOTA_AGE_BY_ENGINE[$engine]="unknown"
  fi
  printf '%s' "${QUOTA_AGE_BY_ENGINE[$engine]}"
}

# Sets QUOTA_AGE, and turns QUOTA_PROBE into "fail" when a max age is
# configured and the reading is older than it (or its age cannot be read).
quota_age_apply() {
  QUOTA_AGE="-"
  # No age is asked of a probe that already failed: a hung quota.sh would be
  # waited on twice.
  [[ "$QUOTA_PROBE" != "fail" ]] || return 0
  QUOTA_AGE="$(quota_age_of "$1")"
  [[ "${QUOTA_MAX_AGE_HOURS:-}" =~ ^[0-9]+(\.[0-9]+)?$ && "$QUOTA_AGE" != "-" ]] || return 0
  if [[ ! "$QUOTA_AGE" =~ ^[0-9]+$ ]] \
     || awk -v a="$QUOTA_AGE" -v h="$QUOTA_MAX_AGE_HOURS" 'BEGIN { exit !(a > h * 3600) }'; then
    note "${1} quota snapshot is stale (age ${QUOTA_AGE}s, policy.quota_max_age_hours ${QUOTA_MAX_AGE_HOURS})"
    QUOTA_PROBE="fail"; QUOTA_BY_ENGINE[$1]="fail"; QUOTA_STALE[$1]=1
  fi
}

# The skip code for a round in which nothing was eligible: a stale snapshot is
# an unknown pool (quota-unknown), anything else stays nothing-eligible.
quota_age_empty_code() {
  (( ${#QUOTA_STALE[@]} )) && printf 'quota-unknown' || printf 'nothing-eligible'
}

# "2h", "14m", "30s" for the status line.
quota_age_human() {
  local s="$1"
  [[ "$s" =~ ^[0-9]+$ ]] || { printf '%s' "$s"; return; }
  if (( s >= 3600 )); then printf '%dh' $(( s / 3600 ))
  elif (( s >= 60 )); then printf '%dm' $(( s / 60 ))
  else printf '%ds' "$s"; fi
}

# The pool fact for `status`: the percentage and how old that reading is, and
# whether policy.quota_max_age_hours would make the runner refuse it. Silent
# when the source is not a snapshot (stub, command), which has no age.
quota_pool_line() {
  local pct="$1" age="$2"
  [[ "$age" != "-" ]] || return 0
  local line="  pool ${pct}% remaining, snapshot $(quota_age_human "$age") old"
  if [[ "${QUOTA_MAX_AGE_HOURS:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
     && { [[ ! "$age" =~ ^[0-9]+$ ]] || awk -v a="$age" -v h="$QUOTA_MAX_AGE_HOURS" 'BEGIN { exit !(a > h * 3600) }'; }; then
    line+=" — older than policy.quota_max_age_hours ${QUOTA_MAX_AGE_HOURS}; the runner declines"
  fi
  printf '%s\n' "$line"
}
