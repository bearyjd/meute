# A staged plan the validator rejects is set aside, not fatal (R13), sourced by
# bin/run.sh. Expects PLAN_QUEUE_FILE, STATE_DIR and note/log_run (outcome.sh).
#
# plan_quarantine <reason>: rename the file to state/plan-queue.invalid-<ts>.json
# (rename it back to undo), write one status=error code=plan-invalid line, and
# return so the same fire runs the manifest queue. The fire's own line still
# follows, so OUTCOME_CODE and OUTCOME_LOGGED are put back as they were.
plan_quarantine() {
  local reason="$1" dest
  dest="${STATE_DIR}/plan-queue.invalid-$(date +%Y%m%dT%H%M%S).json"
  [[ ! -e "$dest" ]] || dest="${dest}.$$"
  if ! mv -- "$PLAN_QUEUE_FILE" "$dest"; then
    # Unmovable (permissions, a directory): the manifest queue must still run.
    dest="${PLAN_QUEUE_FILE} (could not be moved aside)"
  fi
  note "${reason}; quarantined as ${dest}; continuing with the manifest queue"
  local saved_code="$OUTCOME_CODE" saved_logged="$OUTCOME_LOGGED"
  OUTCOME_CODE="plan-invalid"
  log_run error "detail=${reason}" "quarantine=${dest##*/}"
  OUTCOME_CODE="$saved_code"; OUTCOME_LOGGED="$saved_logged"
}
