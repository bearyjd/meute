# meute drain, sourced by bin/meute (P1.3, R11): one loop for the staged plan
# and for the configured repos.
#
#   meute drain <daily|weekly> [--source plan|manifest] [--max N] [--until HH:MM] [--repo R]...
#
# Each fire is `run.sh <slot> --strict-exit --wait-lock 900 --source <mode>`,
# never forced, so the cursor, the community share, the tier-3 cap and the
# pool all still apply. --repo narrows the queue through MEUTE_ONLY_REPOS
# (lib/select.sh), which filters without forcing and rotates on a cursor of
# its own (lib/cursor.sh), so the timers' fleet-wide cursor is left alone. The loop reads run.sh's exit
# status only (D1, --strict-exit), never the log text:
#   0, 1     the fire ran an entry; go on (three failures in a row end it, 1)
#   other    a stop-class status (hold 10, lock 11, budget 12, quota 13,
#            nothing eligible 14, host 15, usage 2, died 70): end with it
# It also ends with 0 after one full rotation (the cursor is back on the key
# it named at the start, or on the queue's last key when it named none), when
# a staged plan has no unattempted item left, at --max fires, or at --until.
# A rotation whose last entry is stepped over (not eligible) ends one fire
# late, when the cursor lands on an entry this drain already ran.
#
# Expects from the caller: MEUTE_ROOT, MANIFEST, MANIFEST_PY, CURSOR_FILE,
# PLAN_QUEUE_FILE, PLAN_DONE_FILE, kv_get (state.sh), now_epoch (fleet.sh).

source "${MEUTE_ROOT}/lib/cursor.sh"

readonly DRAIN_WAIT_LOCK=900
readonly DRAIN_MAX_ERRORS=3
DRAIN_DEADLINE=""

drain_usage() { printf 'meute: drain: %s\n' "$*" >&2; exit 2; }
drain_stop()  { printf 'meute: drain: %s after %s fire(s)\n' "$2" "$DRAIN_FIRES" >&2; exit "$1"; }

# drain_deadline HH:MM: the epoch of the next such local time -- today, or
# tomorrow once it has passed, so `--until 06:00` started at 23:00 runs overnight.
drain_deadline() {
  local now at
  now="$(now_epoch)"
  at="$(date -d "$(date -d "@$now" +%F) $1" +%s)"
  (( at > now )) || at="$(date -d "$(date -d "@$(( now + 86400 ))" +%F) $1" +%s)"
  printf '%s\n' "$at"
}
drain_before_deadline() { [[ -z "$DRAIN_DEADLINE" ]] || (( $(now_epoch) < DRAIN_DEADLINE )); }

# drain_keys <plan|manifest> <slot> <only>: "key<TAB>path" for each entry of
# the queue run.sh would build, narrowed as MEUTE_ONLY_REPOS narrows it.
drain_keys() {
  local mode="$1" slot="$2" only="$3"
  if [[ "$mode" == plan ]]; then
    python3 "$MANIFEST_PY" plan-queue "$MANIFEST" "$PLAN_QUEUE_FILE" "$slot"
  else
    python3 "$MANIFEST_PY" queue "$MANIFEST" "$slot"
  fi | jq -r --arg o "$only" '($o | split("\n") | map(select(. != ""))) as $l
         | select(($l | length) == 0 or (.repo as $r | any($l[]; . == $r))) | "\(.key)\t\(.path)"'
}

# drain_plan_pending <slot> <only>: is any staged item still unattempted? The
# runner's own test (lib/status.sh next_in_queue): no plan-complete mark and
# still a repository. A retired plan has none.
drain_plan_pending() {
  local key path keys
  [[ -f "$PLAN_QUEUE_FILE" ]] || return 1
  keys="$(drain_keys plan "$1" "$2")" || { printf 'meute: drain: the staged plan failed validation (see meute status)\n' >&2; exit 1; }
  while IFS=$'\t' read -r key path; do
    [[ -n "$key" && -z "$(kv_get "$PLAN_DONE_FILE" "$key")" ]] || continue
    [[ -d "$path/.git" || -f "$path/.git" ]] && return 0
  done <<< "$keys"
  return 1
}

cmd_drain() {
  local slot="" source=plan max="" until="" only="" mode ckey keys start sentinel cursor seen rc errors=0
  DRAIN_FIRES=0
  while (( $# )); do
    case "$1" in
      daily|weekly) [[ -z "$slot" ]] || drain_usage "one slot only"; slot="$1" ;;
      --source|--max|--until|--repo)
        (( $# > 1 )) || drain_usage "$1 needs a value"
        case "$1" in
          --source) source="$2" ;; --max) max="$2" ;; --until) until="$2" ;; --repo) only+="$2"$'\n' ;;
        esac
        shift ;;
      *) drain_usage "unknown argument: $1 (usage: meute drain <daily|weekly> [--source plan|manifest] [--max N] [--until HH:MM] [--repo R]...)" ;;
    esac
    shift
  done
  [[ -n "$slot" ]] || drain_usage "missing slot: expected 'daily' or 'weekly'"
  [[ "$source" =~ ^(plan|manifest)$ ]] || drain_usage "unknown source: $source (expected plan or manifest)"
  [[ -z "$max" || "$max" =~ ^[1-9][0-9]*$ ]] || drain_usage "--max needs a whole number of fires above 0: $max"
  [[ -z "$until" || "$until" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || drain_usage "--until needs HH:MM (24-hour): $until"
  [[ -z "$until" ]] || DRAIN_DEADLINE="$(drain_deadline "$until")"

  # A staged plan is drained only while one is staged; --source manifest, or
  # no plan, drains the manifest and keeps a plan staged mid-drain out of it.
  mode=manifest; [[ "$source" == plan && -f "$PLAN_QUEUE_FILE" ]] && mode=plan
  ckey="$(cursor_name "$slot" "$mode" "$only")"
  keys="$(drain_keys "$mode" "$slot" "$only")" || drain_usage "cannot read the ${slot} ${mode} queue"
  [[ -z "$only" || -n "$keys" ]] || drain_usage "--repo matches no entry in the ${slot} ${mode} queue"
  start="$(kv_get "$CURSOR_FILE" "$ckey")"
  # An unknown cursor makes run.sh start at the head, so the rotation ends on the tail.
  sentinel="$start"
  grep -qxF "$start" < <(cut -f1 <<< "$keys") || sentinel="$(tail -n1 <<< "$keys" | cut -f1)"
  seen=$'\n'"${start}"$'\n'

  scope_init
  while :; do
    if [[ "$mode" == plan ]] && ! drain_plan_pending "$slot" "$only"; then drain_stop 0 "the staged plan is drained"; fi
    drain_before_deadline || drain_stop 0 "reached --until ${until}"
    [[ -z "$max" ]] || (( DRAIN_FIRES < max )) || drain_stop 0 "reached --max ${max}"
    rc=0
    MEUTE_ONLY_REPOS="$only" "${SCOPE_CMD[@]}" "${MEUTE_ROOT}/bin/run.sh" "$slot" --strict-exit \
      --wait-lock "$DRAIN_WAIT_LOCK" --source "$mode" --once || rc=$?
    (( rc <= 1 )) || drain_stop "$rc" "stopped on run.sh exit ${rc}"
    DRAIN_FIRES=$(( DRAIN_FIRES + 1 ))
    if (( rc )); then errors=$(( errors + 1 )); else errors=0; fi
    (( errors < DRAIN_MAX_ERRORS )) || drain_stop 1 "${DRAIN_MAX_ERRORS} failed fires in a row"
    cursor="$(kv_get "$CURSOR_FILE" "$ckey")"
    [[ "$mode" == plan || "$cursor" != "$sentinel" ]] || drain_stop 0 "one full rotation done"
    [[ -n "$cursor" && "$seen" != *$'\n'"${cursor}"$'\n'* ]] \
      || drain_stop 0 "the cursor is not on a new entry (the rotation wrapped, or the plan fell back to the manifest)"
    seen+="${cursor}"$'\n'
  done
}
