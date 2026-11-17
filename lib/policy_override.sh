# Expiring policy overrides, sourced by bin/meute and bin/run.sh (plan P1.1, D2).
#
# state/policy-override: kv rows, key<TAB>value<TAB>until-epoch<TAB>reason. The
# values are read by lib/policy_override.py (via fleet_load_policy) after the
# manifest and checked by the manifest's own rules; this file does the writing.
# Expiry is mandatory and capped at 7 days, like the hold, so an override
# cannot outlive the night it was meant for.
#
# Expects from the caller: STATE_DIR, MANIFEST, MANIFEST_PY, and die()/note().
# fleet.sh supplies now_epoch and hold_duration_seconds.

POLICY_OVERRIDE_MAX_SECONDS=604800
POLICY_OVERRIDE_ACTIVE=0

policy_override_file() { printf '%s\n' "${POLICY_OVERRIDE_FILE:-${STATE_DIR}/policy-override}"; }

# policy_override_set k=v... --for 8h [-r why]
policy_override_set() {
  local spec="" reason="" secs until key
  local -a pairs=()
  while (( $# )); do
    case "$1" in
      --for) spec="${2:-}"; [[ -n "$spec" ]] || die "--for needs a duration (45m, 6h, 3d)"; shift 2 ;;
      -r|--reason) reason="${2:-}"; [[ -n "$reason" ]] || die "-r needs a reason"; shift 2 ;;
      -*) die "unknown option: $1 (try: meute policy set quota_floor_percent=1 --for 8h -r why)" ;;
      *) pairs+=( "$1" ); shift ;;
    esac
  done
  (( ${#pairs[@]} )) || die "policy set: give at least one key=value (try: meute policy set quota_floor_percent=1 --for 8h)"
  [[ -n "$spec" ]] || die "policy set: --for is required; an override must expire (45m, 6h, 3d, up to 7d)"
  secs="$(hold_duration_seconds "$spec")" || die "bad duration: ${spec} — use 45m, 6h or 3d"
  (( secs <= POLICY_OVERRIDE_MAX_SECONDS )) || die "policy set: an override lasts at most 7 days (${spec} is longer)"
  python3 "$MANIFEST_PY" policy-check "$MANIFEST" "$(policy_override_file)" "${pairs[@]}" \
    || die "policy set: refused; nothing was written"
  until=$(( $(now_epoch) + secs ))
  reason="${reason//$'\t'/ }"; reason="${reason//$'\n'/ }"
  for key in "${pairs[@]}"; do
    # One ceiling at a time: setting one drops the other's row (policy-check
    # validated the file as it will be after this).
    case "${key%%=*}" in
      weekly_runs) kv_del "$(policy_override_file)" weekly_cost_usd ;;
      weekly_cost_usd) kv_del "$(policy_override_file)" weekly_runs ;;
    esac
    kv_set_row "$(policy_override_file)" "${key%%=*}" "${key#*=}" "$until" "$reason"
  done
  note "policy override until $(hold_until_human "$until")${reason:+ — ${reason}}: ${pairs[*]}"
  note "lift it early with:  meute policy clear"
}

# Prints one line per override in force; returns 1 when there is none.
policy_override_show() {
  local file live found=1 key value until reason
  file="$(policy_override_file)"
  if [[ -f "$file" ]]; then
    # The keys a run obeys, from the same reader (expiry, 7-day cap, non-finite).
    live="$(MEUTE_NOW="$(now_epoch)" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import policy_override as p; print(" ".join(p.read_rows(sys.argv[2], p.now_epoch())))' \
      "$(dirname "$MANIFEST_PY")" "$file")" || return 1
    while IFS=$'\t' read -r key value until reason; do
      [[ " $live " == *" $key "* ]] || continue
      printf '%s=%s  until %s%s\n' "$key" "$value" "$(hold_until_human "$until")" "${reason:+  — ${reason}}"
      found=0
    done < "$file"
  fi
  return "$found"
}

policy_override_clear() {
  rm -f "$(policy_override_file)"
}
