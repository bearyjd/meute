# A staged plan the validator rejects is set aside, not fatal (R13), sourced by
# bin/run.sh. Expects PLAN_QUEUE_FILE, STATE_DIR, MANIFEST, MANIFEST_PY and
# note/log_run (outcome.sh).
#
# plan_quarantine <reason>: rename the file to state/plan-queue.invalid-<ts>.json
# (rename it back to undo), write one status=error code=plan-invalid line, and
# fail a staged-only fire. A normal fire continues with the manifest queue
# and logs its own result, so put OUTCOME_CODE and OUTCOME_LOGGED back.
#
# plan-queue also fails when the manifest is what broke (edited mid-run, say).
# The plan is not at fault then, so it stays put and this dies on the manifest,
# as the runner always has.
plan_quarantine() {
  local reason="$1" dest continuation=""
  python3 "$MANIFEST_PY" validate "$MANIFEST" >/dev/null 2>&1 || die "manifest failed validation"
  dest="${STATE_DIR}/plan-queue.invalid-$(date +%Y%m%dT%H%M%S).json"
  [[ ! -e "$dest" ]] || dest="${dest}.$$"
  if ! mv -- "$PLAN_QUEUE_FILE" "$dest"; then
    dest="${PLAN_QUEUE_FILE} (could not be moved aside)"
  fi
  [[ "$SOURCE" == staged ]] || continuation="; continuing with the manifest queue"
  note "${reason}; quarantined as ${dest}${continuation}"
  local saved_code="$OUTCOME_CODE" saved_logged="$OUTCOME_LOGGED"
  OUTCOME_CODE="plan-invalid"
  log_run error "detail=${reason}" "quarantine=${dest##*/}"
  if [[ "$SOURCE" == staged ]]; then
    (( ! OUTCOME_STRICT )) || exit "$(outcome_exit_status plan-invalid)"
    exit 1
  fi
  OUTCOME_CODE="$saved_code"; OUTCOME_LOGGED="$saved_logged"
}
