#!/usr/bin/env bash
#
# The plan queue lock: state/.plan-lock. Sourced by bin/meute and
# bin/run.sh.
#
# `meute plan --enqueue --append` reads state/plan-queue.json, merges, and
# renames the result over it; the runner's retire_completed_plan checks that
# every item was attempted, archives the queue and clears plan-complete. Run
# unserialized, a retire between the append's read and its rename lets the
# rename put every finished entry back with no marks, and the runner runs them
# all again (R15). Both hold this lock across their whole check-and-write.
#
# It is not the run lock: that one is held for a whole run, and an enqueue
# must not wait for a run to end. This one is held for a jq merge or one
# validation, so the wait is short; MEUTE_PLAN_QUEUE_LOCK_WAIT (seconds,
# default PLAN_QUEUE_LOCK_WAIT_DEFAULT) bounds it.
#
# Expects from the caller: STATE_DIR, note.

readonly PLAN_QUEUE_LOCK_WAIT_DEFAULT=30
PLAN_QUEUE_LOCK_FD=""

# plan_queue_lock: take the lock in the calling shell (never in $(...)).
# Returns 1, holding nothing, if it cannot be opened or stays busy.
plan_queue_lock() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  exec {PLAN_QUEUE_LOCK_FD}>"${STATE_DIR}/.plan-lock" || { PLAN_QUEUE_LOCK_FD=""; return 1; }
  flock -w "${MEUTE_PLAN_QUEUE_LOCK_WAIT:-$PLAN_QUEUE_LOCK_WAIT_DEFAULT}" "$PLAN_QUEUE_LOCK_FD" \
    && return 0
  plan_queue_unlock
  return 1
}

plan_queue_unlock() {
  [[ -n "$PLAN_QUEUE_LOCK_FD" ]] || return 0
  exec {PLAN_QUEUE_LOCK_FD}>&-
  PLAN_QUEUE_LOCK_FD=""
}

# plan_queue_locked <command...>: run it holding the lock. For the runner: a
# busy lock means an enqueue is rewriting the queue, so the command is skipped
# with a note and the next fire tries again; that is never a failed fire.
plan_queue_locked() {
  if ! plan_queue_lock; then
    note "plan queue is busy (an enqueue holds ${STATE_DIR}/.plan-lock); leaving it for the next fire"
    return 0
  fi
  # Not `"$@" || rc=$?`: that would switch off set -e inside the command.
  "$@"
  local rc=$?
  plan_queue_unlock
  return "$rc"
}
