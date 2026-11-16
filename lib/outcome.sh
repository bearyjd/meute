# How a fire ends, sourced by bin/run.sh.
#
# state/log is the audit trail for unattended runs: one line per fire, always.
# log_run writes that line and marks it written; an EXIT trap writes it for any
# path that did not (a die(), or a command killed by set -e), so a broken
# manifest or a full /tmp can no longer stop the fleet with nothing in the log.
#
# Every line carries code=<token> after the caller's fields (the free-text
# reason= among them, unchanged so existing readers keep working) and before
# dur= and PRP-004's four columns, which still end the line:
#   ok      the entry ran and succeeded
#   failed  the entry was attempted and failed (engine error, abort, refusal)
#   died    the runner itself failed before writing a line
#   and one of OUTCOME_SKIP_CODES for a fire that declined to run.
#
# Expects from the caller: LOG_FILE, STARTED_AT, THIS_WEEK, START_EPOCH, SLOT,
# and the LOG_RUNTIME/LOG_IMAGE/LOG_STAGE/LOG_PR columns (unset reads as "-").

readonly OUTCOME_SKIP_CODES="hold lock budget quota-floor quota-unknown nothing-eligible no-queue load disk"
OUTCOME_LOGGED=0
OUTCOME_CODE=""
OUTCOME_LAST_NOTE=""

note() { OUTCOME_LAST_NOTE="$*"; printf 'meute: %s\n' "$*" >&2; }
# The EXIT trap logs the message as detail=.
die()  { OUTCOME_LAST_NOTE="$*"; printf 'meute: %s\n' "$*" >&2; exit 1; }

# One line per invocation, always, including every skip path. This file is the
# audit trail for unattended runs — if it is silent, the runner did not fire.
log_run() {
  local status="$1"; shift
  local line duration=$(( SECONDS - START_EPOCH ))
  line="$(printf '%s\tweek=%s\tslot=%s\tstatus=%s' "$STARTED_AT" "$THIS_WEEK" "${SLOT:-none}" "$status")"
  local field
  for field in "$@"; do line+="$(printf '\t%s' "$field")"; done
  local code="$OUTCOME_CODE"
  [[ -n "$code" ]] || { [[ "$status" == "ok" ]] && code="ok" || code="failed"; }
  line+="$(printf '\tcode=%s\tdur=%ss' "$code" "$duration")"
  # PRP-004's columns, on every line class so a reader can rely on them:
  # runtime= (host|container), image= (12 hex of the image ID actually run),
  # stage= (preflight|build|review|resolve|publish), pr= (URL). Phase 2b
  # fills the first two; the rest stay `-` until the phase that fills them.
  line+="$(printf '\truntime=%s\timage=%s\tstage=%s\tpr=%s' \
             "${LOG_RUNTIME:--}" "${LOG_IMAGE:--}" "${LOG_STAGE:--}" "${LOG_PR:--}")"
  OUTCOME_LOGGED=1
  printf '%s\n' "$line" >> "$LOG_FILE"
  printf '%s\n' "$line" >&2
}

# skip <code> <reason> [field...]
# Exit 0 on every "not this time" path: cron must not see a scheduled chore
# declining to run as a failure. <code> is one of OUTCOME_SKIP_CODES.
skip() {
  [[ " $OUTCOME_SKIP_CODES " == *" $1 "* ]] || die "skip: unknown code: $1"
  OUTCOME_CODE="$1"
  log_run "skipped" "reason=$2" "${@:3}"
  exit 0
}

# outcome_on_exit [cleanup-function]
# The EXIT trap. Runs the cleanup first, then, if the fire failed without a
# line, writes one: status=error code=died detail=<the last message>. A clean
# exit with no line (--dry-run) is not a fire and stays silent. The exit
# status is left as it was.
outcome_on_exit() {
  local rc=$?
  set +e
  [[ -z "${1:-}" ]] || "$1"
  if (( ! OUTCOME_LOGGED && rc != 0 )); then
    local detail="${OUTCOME_LAST_NOTE:-exit status ${rc}}"
    detail="${detail//[$'\t\r\n']/ }"
    OUTCOME_CODE="died"
    log_run "error" "detail=${detail}"
  fi
  return "$rc"
}
