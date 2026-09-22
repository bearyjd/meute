#!/usr/bin/env bash
#
# meute — autonomous fleet runner.
#
#   bin/run.sh <daily|weekly> [options]
#
# Executes exactly ONE queue item per invocation and exits. Scheduling is cron's
# job; idempotency and never-starve-the-human are this script's job.
#
# Options:
#   --engine <claude|codex>  override the manifest engine for this run
#   --runtime <host|container>
#                            override the manifest runtime for this run. `container`
#                            needs the repo's pinned image (PRP-004 rule 1) and, until
#                            Phase 2 lands the container path, is refused with the
#                            entry logged as an error rather than run on the host
#   --repo <name>            force a repo (bypasses the cursor and the share gates)
#   --task <name>            force a task (bypasses the cursor and the share gates)
#   --dry-run                select and render, invoke nothing. Not a no-op on state/:
#                            every skip before selection (hold, lock, budget, quota,
#                            nothing eligible) still appends a status=skipped line to
#                            state/log, an entry with no commits is logged as an error
#                            and stepped over, and plan bookkeeping still happens (a
#                            vanished staged repo is marked missing, a finished plan
#                            is archived)
#   --validate               validate the manifest and exit
#   --help
#
# meute is subscription-only. It never runs on metered API billing: any API key
# in the environment is stripped from the child process, and a zero-cost
# preflight refuses to start if the engine did not resolve to a subscription.
#
# Environment:
#   MEUTE_MANIFEST         manifest path (default: <root>/repos.yaml)
#   MEUTE_CODEX_MODEL      model passed to `codex exec -m`; unset means codex's default
#   MEUTE_SETTING_SOURCES  value for claude --setting-sources (default: none)
#   MEUTE_CLAUDE_QUOTA_CMD, MEUTE_CODEX_QUOTA_CMD
#                          per-engine subscription probes; see bin/quota.sh
#   MEUTE_QUOTA_CMD        legacy alias for MEUTE_CLAUDE_QUOTA_CMD
#
set -Eeuo pipefail

readonly MEUTE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MEUTE_ROOT
source "${MEUTE_ROOT}/lib/state.sh"
source "${MEUTE_ROOT}/lib/fleet.sh"
source "${MEUTE_ROOT}/lib/engines.sh"
source "${MEUTE_ROOT}/lib/preflight.sh"
readonly MANIFEST_PY="${MEUTE_ROOT}/lib/manifest.py"
# The harness is public; a real fleet config names private projects and says what
# they do. repos.local.yaml is gitignored and wins when present, so you never have
# to choose between committing your project list and using the tool.
if [[ -n "${MEUTE_MANIFEST:-}" ]]; then
  readonly MANIFEST="$MEUTE_MANIFEST"
elif [[ -f "${MEUTE_ROOT}/repos.local.yaml" ]]; then
  readonly MANIFEST="${MEUTE_ROOT}/repos.local.yaml"
else
  readonly MANIFEST="${MEUTE_ROOT}/repos.yaml"
fi
readonly STATE_DIR="${MEUTE_ROOT}/state"
readonly CURSOR_FILE="${STATE_DIR}/cursor"
readonly LOG_FILE="${STATE_DIR}/log"
readonly LOCK_FILE="${STATE_DIR}/.lock"
readonly HOLD_FILE="${STATE_DIR}/hold"
readonly PLAN_QUEUE_FILE="${STATE_DIR}/plan-queue.json"
readonly PLAN_DONE_FILE="${STATE_DIR}/plan-complete"
# A 429 is not "try again in n seconds" so much as "this pool is spent" -- the
# provider's own reset text is free-form and not worth parsing. A day-long
# hold means at most one more wasted (and, per observation, free: a 429
# attempt costs $0) attempt before it backs off again, self-correcting
# without ever needing to know the real reset time.
readonly RATE_LIMIT_HOLD="24h"
readonly WORKTREE_DIR="${MEUTE_ROOT}/.worktrees"
readonly DATE="$(date +%F)"
readonly STARTED_AT="$(date --iso-8601=seconds)"
readonly THIS_WEEK="$(date +%G-%V)"
# $SECONDS is 0 at script start, so elapsed time is just $SECONDS.
readonly START_EPOCH=0

SLOT=""
QUOTA_SOURCE="?"
remaining_at_start="?"
BUDGET_LEFT="-"
SCRUBBED=""
AUTH_MODE=""
ENGINE_OVERRIDE=""
RUNTIME_OVERRIDE=""
FORCE_REPO=""
FORCE_TASK=""
DRY_RUN=0
PLAN_MODE=0

# Populated during a run; the EXIT trap reads them.
REPO_PATH=""
WORKTREE=""
BRANCH=""
BASE_SHA=""

note() { printf 'meute: %s\n' "$*" >&2; }
die()  { printf 'meute: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# state/cursor holds the round-robin cursors (one key per slot, a separate one
# per slot for a staged plan) and the per-(repo,task) lens rotation counters.
# Storage lives in lib/state.sh. Everything under state/ and reports/ is
# gitignored and stays on this machine: it names private repositories and
# carries unfixed findings, so the runner never commits it.
# --------------------------------------------------------------------------
state_get() { kv_get "$CURSOR_FILE" "$1"; }
state_set() { kv_set "$CURSOR_FILE" "$1" "$2"; }

# One line per invocation, always, including every skip path. This file is the
# audit trail for unattended runs — if it is silent, the runner did not fire.
log_run() {
  local status="$1"; shift
  local line duration=$(( SECONDS - START_EPOCH ))
  line="$(printf '%s\tweek=%s\tslot=%s\tstatus=%s' "$STARTED_AT" "$THIS_WEEK" "${SLOT:-none}" "$status")"
  local field
  for field in "$@"; do line+="$(printf '\t%s' "$field")"; done
  line+="$(printf '\tdur=%ss' "$duration")"
  # PRP-004's columns, on every line class so a reader can rely on them:
  # runtime= (host|container), image= (12-hex digest prefix), stage=
  # (preflight|build|review|resolve|publish), pr= (URL). Written as `-`
  # until the phase that fills each one; a line differs from a pre-PRP-004
  # one by this suffix and nothing else.
  line+="$(printf '\truntime=%s\timage=%s\tstage=%s\tpr=%s' "-" "-" "-" "-")"
  printf '%s\n' "$line" >> "$LOG_FILE"
  printf '%s\n' "$line" >&2
}

# Exit 0 on every "not this time" path: cron must not see a scheduled chore
# declining to run as a failure.
skip() { log_run "skipped" "reason=$1" "${@:2}"; exit 0; }

# The header comment above, however long it grows: everything after the
# shebang up to the first line that is not a comment.
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^#( |$)/, ""); print }' "${BASH_SOURCE[0]}"; }

# --------------------------------------------------------------------------
# Worktree teardown. Removes the checkout; keeps the branch when it holds
# commits, because for tier-3 drafts that branch IS the deliverable and the
# in-flight cap is computed by counting them.
# --------------------------------------------------------------------------
cleanup() {
  local rc=$?
  if [[ -n "$WORKTREE" && -d "$WORKTREE" ]]; then
    git -C "$REPO_PATH" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"
    git -C "$REPO_PATH" worktree prune >/dev/null 2>&1 || true
  fi
  if [[ -n "$BRANCH" && -n "$REPO_PATH" && -n "$BASE_SHA" ]] \
     && git -C "$REPO_PATH" rev-parse --verify -q "$BRANCH" >/dev/null 2>&1; then
    if [[ "$(git -C "$REPO_PATH" rev-parse "$BRANCH")" == "$BASE_SHA" ]]; then
      git -C "$REPO_PATH" branch -q -D "$BRANCH" >/dev/null 2>&1 || true
    fi
  fi
  return $rc
}

parse_args() {
  while (( $# )); do
    case "$1" in
      daily|weekly) SLOT="$1" ;;
      --engine)   ENGINE_OVERRIDE="${2:?--engine needs a value}"; shift ;;
      --runtime)  RUNTIME_OVERRIDE="${2:?--runtime needs a value}"; shift ;;
      --repo)     FORCE_REPO="${2:?--repo needs a value}"; shift ;;
      --task)     FORCE_TASK="${2:?--task needs a value}"; shift ;;
      --dry-run)  DRY_RUN=1 ;;
      --validate) python3 "$MANIFEST_PY" validate "$MANIFEST"; exit $? ;;
      --help|-h)  usage; exit 0 ;;
      *)          die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
  [[ -n "$SLOT" ]] || die "missing slot: expected 'daily' or 'weekly' (try --help)"
  [[ -z "$ENGINE_OVERRIDE" || "$ENGINE_OVERRIDE" =~ ^(claude|codex)$ ]] \
    || die "unknown engine: $ENGINE_OVERRIDE"
  [[ -z "$RUNTIME_OVERRIDE" || "$RUNTIME_OVERRIDE" =~ ^(host|container)$ ]] \
    || die "unknown runtime: $RUNTIME_OVERRIDE (expected host or container)"
}


# A staged plan rotates on its own cursor. Sharing one would leave the
# manifest cursor pointing at a plan key once the plan retires -- a key no
# manifest entry has -- and restart the manifest rotation at 0.
cursor_key() {
  if (( PLAN_MODE )); then printf 'plan-cursor.%s\n' "$SLOT"; else printf 'cursor.%s\n' "$SLOT"; fi
}

eligible() {
  local entry="$1" key kind path tier engine stage_entry
  { read -r key; read -r kind; read -r path; read -r tier; read -r engine; read -r stage_entry; } \
    < <(jq -r '.key, .kind, .path, .tier, .engine, .stage_entry' <<< "$entry")

  if [[ ! -d "$path/.git" && ! -f "$path/.git" ]]; then
    note "skipping ${key}: not a git repository at $path"
    # A staged path that is no longer a repository (an agent worktree torn
    # down after staging) can never be attempted; unmarked, it would hold the
    # plan open forever. Recorded on dry runs too, like the retirement it
    # feeds -- a missing repo is a fact, not an effect of running.
    (( PLAN_MODE )) && kv_set "$PLAN_DONE_FILE" "$key" missing
    return 1
  fi
  # A forced selection is an explicit human decision; only the path check
  # stands. That includes re-running a staged item already attempted.
  (( FORCED )) && return 0

  if (( PLAN_MODE )) && [[ -n "$(kv_get "$PLAN_DONE_FILE" "$key")" ]]; then
    note "skipping ${key}: staged plan item already attempted"
    return 1
  fi
  if [[ "$kind" == "community" ]] && ! community_allowed; then
    note "skipping ${key}: community share exhausted this week"
    return 1
  fi
  # The cap gates NEW builds. A stage entry (PRP-004 §4.3) works a branch that
  # is itself one of the counted ones; at cap -- the designed steady state --
  # a resolve must still be able to run, or nothing ever frees a slot.
  if [[ "$tier" == "tier3" && "$stage_entry" != "true" ]]; then
    local in_flight; in_flight="$(tier3_in_flight)"
    if (( in_flight >= TIER3_CAP )); then
      note "skipping ${key}: ${in_flight} tier-3 drafts already in flight (cap ${TIER3_CAP})"
      return 1
    fi
  fi
  # A publish stage runs no engine, so there is no pool to ask about.
  [[ -n "$engine" ]] || return 0
  # Gate 2 of 2: the subscription pool the human shares -- per engine, so a
  # Codex entry is gated by a Codex source and never by the Claude status-line
  # snapshot. Checked per candidate rather than after selection: a fleet that
  # mixes engines must step over the one whose pool is spent or unmeasured,
  # not pin the rotation on it.
  engine="${ENGINE_OVERRIDE:-$engine}"
  quota_for_engine "$engine"
  if [[ "$QUOTA_PROBE" == "fail" ]]; then
    note "skipping ${key}: ${engine} quota unavailable"
    return 1
  fi
  if (( ${QUOTA_PROBE%% *} < QUOTA_FLOOR )); then
    note "skipping ${key}: ${engine} quota ${QUOTA_PROBE%% *}% below floor ${QUOTA_FLOOR}%"
    return 1
  fi
  return 0
}

# One quota.sh subprocess per engine per fire, however long the queue: the
# reading is cached so every candidate can be asked about. Sets QUOTA_PROBE
# to "<percent> <source>", or "fail" when no source for that engine answered.
declare -A QUOTA_BY_ENGINE=()
quota_for_engine() {
  local engine="$1"
  if [[ -z "${QUOTA_BY_ENGINE[$engine]+set}" ]]; then
    QUOTA_BY_ENGINE[$engine]="$("${MEUTE_ROOT}/bin/quota.sh" --engine "$engine" --with-source)" \
      || QUOTA_BY_ENGINE[$engine]="fail"
  fi
  QUOTA_PROBE="${QUOTA_BY_ENGINE[$engine]}"
}

# Nothing was eligible. When a pool was the reason for any candidate, the
# reason names each such engine with its verdict, and quota=/engine= carry
# the readings in the same order -- so a wedged fleet reads as "codex quota
# probe failed", not as an inexplicable empty round.
skip_nothing_eligible() {
  local engine probe verdicts=() engines=() quotas=()
  for engine in $(printf '%s\n' "${!QUOTA_BY_ENGINE[@]}" | LC_ALL=C sort); do
    probe="${QUOTA_BY_ENGINE[$engine]}"
    if [[ "$probe" == "fail" ]]; then
      verdicts+=( "${engine} quota probe failed" ); quotas+=( "fail" )
    elif (( ${probe%% *} < QUOTA_FLOOR )); then
      verdicts+=( "${engine} quota ${probe%% *}% below floor ${QUOTA_FLOOR}%" )
      quotas+=( "${probe%% *}:${probe#* }" )
    else
      continue
    fi
    engines+=( "$engine" )
  done
  (( ${#verdicts[@]} )) || skip "no eligible entry for slot ${SLOT}"
  local why; why="$(printf '%s; ' "${verdicts[@]}")"
  skip "no eligible entry for slot ${SLOT} (${why%; })" \
    "quota=$(IFS=,; printf '%s' "${quotas[*]}")" "engine=$(IFS=,; printf '%s' "${engines[*]}")"
}

# The runner owns LOCK_FILE for its whole lifetime, so this check and the
# subsequent rename cannot race another runner.  `meute plan --enqueue` writes
# a complete replacement atomically; if an operator replaces a plan between
# timer fires, the next invocation validates that new file from scratch.
retire_completed_plan() {
  [[ -f "$PLAN_QUEUE_FILE" ]] || return 0
  local all_file entry key archive complete=1
  all_file="$(mktemp)"
  python3 "$MANIFEST_PY" plan-queue "$MANIFEST" "$PLAN_QUEUE_FILE" all > "$all_file" \
    || { rm -f "$all_file"; die "staged plan queue failed validation"; }
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    key="$(jq -r '.key' <<< "$entry")"
    if [[ -z "$(kv_get "$PLAN_DONE_FILE" "$key")" ]]; then
      complete=0
      break
    fi
  done < "$all_file"
  rm -f "$all_file"
  (( complete )) || return 0

  archive="${STATE_DIR}/plan-queue.completed-$(date +%Y%m%dT%H%M%S).json"
  [[ ! -e "$archive" ]] || archive="${archive}.$$"
  mv "$PLAN_QUEUE_FILE" "$archive"
  rm -f "$PLAN_DONE_FILE"
  note "all staged plan items were attempted; archived queue at ${archive}"
}

# A forced --repo/--task names one entry; nothing else is a candidate.
load_queue() {
  local queue_file="$1"
  if (( FORCED )); then
    jq -c --arg r "$FORCE_REPO" --arg t "$FORCE_TASK" \
       'select(($r == "" or .repo == $r) and ($t == "" or .task == $t))' \
       "$queue_file" > "${queue_file}.f"
    mv "${queue_file}.f" "$queue_file"
  fi
  mapfile -t QUEUE < "$queue_file"
}

# Round-robin: resume at the entry after the last one executed for this slot,
# wrap around, and take the first eligible candidate into SELECTED. A global
# rather than stdout so the eligibility checks run in this shell, not a
# subshell whose caches would be thrown away.
select_entry() {
  local cursor start=0 i idx
  cursor="$(state_get "$(cursor_key)")"
  local total=${#QUEUE[@]}
  SELECTED=""
  if [[ -n "$cursor" ]]; then
    for (( i = 0; i < total; i++ )); do
      if [[ "$(jq -r '.key' <<< "${QUEUE[i]}")" == "$cursor" ]]; then start=$(( i + 1 )); break; fi
    done
  fi
  for (( i = 0; i < total; i++ )); do
    idx=$(( (start + i) % total ))
    if eligible "${QUEUE[idx]}"; then SELECTED="${QUEUE[idx]}"; return 0; fi
  done
  return 1
}

main() {
  parse_args "$@"
  mkdir -p "$STATE_DIR" "$WORKTREE_DIR" "${MEUTE_ROOT}/reports"
  command -v jq >/dev/null || die "jq is required"
  scrub_env
  command -v git >/dev/null || die "git is required"

  # Cheapest verdict first, and it depends on nothing: a fleet you have stood
  # down should decline without needing a lock, a valid manifest or a quota
  # probe. See lib/fleet.sh for why a manual hold exists at all.
  if hold_active; then
    skip "paused until $(hold_until_human "$HOLD_UNTIL")${HOLD_REASON:+ — ${HOLD_REASON}}"
  fi

  # One runner at a time. A slow run must not stack up under a tight timer.
  exec 9>"$LOCK_FILE"
  flock -n 9 || skip "another run holds the lock"

  python3 "$MANIFEST_PY" validate "$MANIFEST" >/dev/null || die "manifest failed validation"

  fleet_load_policy || die "could not read policy from ${MANIFEST}"

  # Gate 1 of 2: meute's own weekly ceiling, when the manifest declares one.
  # Not `|| true`: if this function goes missing the ceiling lapses silently,
  # which is the exact failure this check exists to prevent. It returns 1
  # legitimately when no ceiling is declared, so only a *missing* function
  # (127) is fatal.
  local rc=0; fleet_wire_self_budget || rc=$?
  (( rc == 127 )) && die "lib/fleet.sh is missing fleet_wire_self_budget"
  if (( rc == 0 )); then
    BUDGET_LEFT="$(fleet_self_budget_remaining)" || skip "self-budget probe failed"
    (( BUDGET_LEFT < 1 )) \
      && skip "meute's own weekly ceiling is spent" "budget=${BUDGET_LEFT}"
  fi

  local queue_file
  queue_file="$(mktemp)"
  trap 'rm -f "$queue_file"' RETURN
  # A portfolio plan exists only after an explicit `meute plan --enqueue`.
  # It is independently re-expanded and refuses writing tiers in manifest.py;
  # then the ordinary timers prioritize it until every staged item is attempted.
  if [[ -f "$PLAN_QUEUE_FILE" ]]; then
    retire_completed_plan
  fi
  if [[ -f "$PLAN_QUEUE_FILE" ]]; then
    python3 "$MANIFEST_PY" plan-queue "$MANIFEST" "$PLAN_QUEUE_FILE" "$SLOT" > "$queue_file" \
      || die "staged plan queue failed validation"
    if [[ -s "$queue_file" ]]; then
      PLAN_MODE=1
    fi
  fi
  (( PLAN_MODE )) || python3 "$MANIFEST_PY" queue "$MANIFEST" "$SLOT" > "$queue_file" || die "queue build failed"
  fleet_load_scope || die "queue build failed"

  FORCED=0
  [[ -z "$FORCE_REPO" && -z "$FORCE_TASK" ]] || FORCED=1
  load_queue "$queue_file"

  local entry
  select_entry || true
  entry="$SELECTED"
  # A plan's daily items drain in days; its weekly items take weeks. A slot
  # that finds nothing eligible in the plan -- every item attempted, missing,
  # or filtered out by --repo/--task -- falls through to the manifest rather
  # than skip every fire until the other slot retires the plan. Retire first:
  # a plan whose last item just went missing is complete now, not next fire.
  if [[ -z "$entry" ]] && (( PLAN_MODE )); then
    note "no eligible staged plan item for slot ${SLOT}; falling back to the manifest queue"
    retire_completed_plan
    PLAN_MODE=0
    python3 "$MANIFEST_PY" queue "$MANIFEST" "$SLOT" > "$queue_file" || die "queue build failed"
    load_queue "$queue_file"
    select_entry || true
    entry="$SELECTED"
  fi
  (( ${#QUEUE[@]} )) || skip "no queue entries for slot ${SLOT}"
  [[ -n "$entry" ]] || skip_nothing_eligible

  # The selected entry's pool, from the reading eligible() cached -- or, for
  # a forced --repo/--task, which bypasses eligible()'s gates, probed here:
  # a human's choice of entry is not a licence to spend a pool that is gone.
  # The engine is written alongside the source in state/log, making each
  # quota reading attributable.
  local engine remaining
  engine="${ENGINE_OVERRIDE:-$(jq -r '.engine' <<< "$entry")}"
  if [[ -n "$engine" ]]; then
    quota_for_engine "$engine"
    [[ "$QUOTA_PROBE" != "fail" ]] || skip "${engine} quota probe failed"
    remaining="${QUOTA_PROBE%% *}"
    QUOTA_SOURCE="${QUOTA_PROBE#* }"
    (( remaining < QUOTA_FLOOR )) \
      && skip "${engine} quota ${remaining}% below floor ${QUOTA_FLOOR}%" "quota=${remaining}:${QUOTA_SOURCE}" "engine=${engine}"
    remaining_at_start="$remaining"
  fi
  run_entry "$entry"
}

run_entry() {
  local entry="$1"
  local key repo task tier engine spec template file_budget default_branch
  key="$(jq -r '.key' <<< "$entry")"
  repo="$(jq -r '.repo' <<< "$entry")"
  task="$(jq -r '.task' <<< "$entry")"
  tier="$(jq -r '.tier' <<< "$entry")"
  spec="$(jq -r '.spec' <<< "$entry")"
  template="$(jq -r '.template' <<< "$entry")"
  file_budget="$(jq -r '.file_budget' <<< "$entry")"
  default_branch="$(jq -r '.default_branch' <<< "$entry")"
  REPO_PATH="$(jq -r '.path' <<< "$entry")"
  MODEL="$(jq -r '.model' <<< "$entry")"
  TOOLS="$(jq -r '.tools' <<< "$entry")"
  PERMISSION_MODE="$(jq -r '.permission_mode' <<< "$entry")"
  ALLOWED_TOOLS="$(jq -r '.allowed_tools' <<< "$entry")"
  TIMEOUT_SECONDS="$(jq -r '.timeout_seconds' <<< "$entry")"
  WRITES_CODE=0; [[ "$(jq -r '.writes_code' <<< "$entry")" == "true" ]] && WRITES_CODE=1
  engine="${ENGINE_OVERRIDE:-$(jq -r '.engine' <<< "$entry")}"
  local kind; kind="$(jq -r '.kind' <<< "$entry")"

  # PRP-004 Phase 1 built the stage machine's schema and nothing that runs a
  # stage -- Phase 4 does. Until then a state/stages row must never reach an
  # engine: aborted here, cursor advanced, so a stray row cannot wedge the slot.
  [[ "$(jq -r '.stage_entry' <<< "$entry")" != "true" ]] \
    || abort_entry "$entry" "stage entries are not runnable before Phase 4"
  # Rule 5, fail closed. A container run needs a pinned image to run in;
  # without one the answer is the validator's, not a fallback to the host.
  # And with one, Phase 2 has yet to build the path -- a repo that opted into
  # isolation must not be quietly run without it.
  local runtime
  runtime="${RUNTIME_OVERRIDE:-$(jq -r '.runtime' <<< "$entry")}"
  if [[ "$runtime" == "container" ]]; then
    [[ -n "$(jq -r '.image.tag // ""' <<< "$entry")" ]] \
      || abort_entry "$entry" "$(manifest_section "$kind").${repo}.image: tag and digest are required when runtime is container"
    abort_entry "$entry" "container runtime is not available before Phase 2"
  fi

  # Rotating lens: one narrow angle per run, advanced only on success.
  local lenses lens="none" lens_index=0
  lenses="$(jq -r '.lenses | join(",")' <<< "$entry")"
  if [[ -n "$lenses" ]]; then
    lens_index="$(state_get "lens.${repo}.${task}")"; lens_index="${lens_index:-0}"
    local -a lens_list; IFS=',' read -ra lens_list <<< "$lenses"
    lens="${lens_list[$(( lens_index % ${#lens_list[@]} ))]}"
  fi

  preflight "$engine"

  # Unique branch and report path even if the slot fires twice in one day.
  BRANCH="${BRANCH_PREFIX}/${task}-${DATE}"
  local suffix=2
  while git -C "$REPO_PATH" rev-parse --verify -q "$BRANCH" >/dev/null 2>&1; do
    BRANCH="${BRANCH_PREFIX}/${task}-${DATE}.${suffix}"; suffix=$(( suffix + 1 ))
  done
  local report_rel="reports/${repo}/${task}-${DATE}.md"
  suffix=2
  while [[ -e "${MEUTE_ROOT}/${report_rel}" ]]; do
    report_rel="reports/${repo}/${task}-${DATE}.${suffix}.md"; suffix=$(( suffix + 1 ))
  done

  local base_ref="HEAD"
  if [[ -n "$default_branch" ]] && git -C "$REPO_PATH" rev-parse --verify -q "$default_branch" >/dev/null 2>&1; then
    base_ref="$default_branch"
  fi
  # A repository with no commits yet (`git init` and nothing else) has no
  # tree to audit and nothing to cut a worktree from. Stepped over like a
  # failed worktree add -- logged, marked, cursor advanced -- because dying
  # here under set -e would pin the slot on it every fire, visible only in
  # the journal. Recorded on dry runs too: an unborn HEAD is a fact about the
  # repository, not an effect of running.
  BASE_SHA="$(git -C "$REPO_PATH" rev-parse --verify -q "${base_ref}^{commit}")" \
    || abort_entry "$entry" "no-head"

  # The agent runs with the worktree as its cwd, and under dontAsk a read
  # outside cwd is refused. So the path the prompt calls "checked out at" has
  # to be the worktree, not the repo it was cut from -- the first
  # market-comparison run had every Read/Glob of the original path denied.
  # Fixed here rather than at the call site because it is deterministic.
  WORKTREE="${WORKTREE_DIR}/${repo}-${task}-${DATE}.$$"
  local prompt_file; prompt_file="$(mktemp)"
  python3 "$MANIFEST_PY" render "$template" \
    "REPO_NAME=${repo}" "REPO_SPEC=${spec}" "REPO_PATH=${WORKTREE}" \
    "TASK=${task}" "TIER=${tier}" "DATE=${DATE}" "BRANCH=${BRANCH}" \
    "FILE_BUDGET=${file_budget}" "LENS=${lens}" "REPORT_PATH=${report_rel}" \
    "ALLOWED_COMMANDS=${ALLOWED_TOOLS:-<none: no shell command is pre-approved>}" \
    "DEFAULT_BRANCH=${base_ref}" "UPSTREAM=$(jq -r '.upstream' <<< "$entry")" \
    "ETIQUETTE=$(jq -r '.etiquette' <<< "$entry")" \
    "ETIQUETTE_CONTENT=$(etiquette_content "$entry")" \
    "TICKET_ID=$(jq -r '.ticket_id' <<< "$entry")" \
    "TICKET_TITLE=$(jq -r '.ticket_title' <<< "$entry")" \
    "TICKET_NOTES=$(jq -r '.ticket_notes' <<< "$entry")" \
    > "$prompt_file" || die "prompt render failed for ${template}"

  if (( DRY_RUN )); then
    note "would run: key=${key} tier=${tier} engine=${engine} model=${MODEL} lens=${lens}"
    note "  branch=${BRANCH} base=${base_ref}@${BASE_SHA:0:8} tools=${TOOLS} mode=${PERMISSION_MODE}"
    note "  allowed=${ALLOWED_TOOLS:-<none>}"
    note "  report=${report_rel} auth=${AUTH_MODE} prompt=${prompt_file} ($(wc -c < "$prompt_file") bytes)"
    exit 0
  fi

  trap cleanup EXIT
  git -C "$REPO_PATH" worktree add -q -b "$BRANCH" "$WORKTREE" "$base_ref" \
    || abort_entry "$entry" "worktree-add-failed"
  copy_worktree_files "$entry"

  local out err; out="$(mktemp)"; err="$(mktemp)"
  CODEX_LAST="$(mktemp)"
  REPORT=""; ENGINE_STATUS="error"; ENGINE_DETAIL=""; COST="-"; TURNS="-"; RATE_LIMITED=0
  local rc=0
  case "$engine" in
    claude) invoke_claude "$prompt_file" "$out" "$err" || rc=$?; extract_claude "$out" || true ;;
    codex)  invoke_codex  "$prompt_file" "$out" "$err" || rc=$?; extract_codex        || true ;;
    *) die "unknown engine: $engine" ;;
  esac
  if (( rc != 0 )) && [[ "$ENGINE_STATUS" == "ok" ]]; then
    ENGINE_STATUS="error"; ENGINE_DETAIL="engine exited ${rc}"
  fi
  [[ -n "$REPORT" ]] || { ENGINE_STATUS="error"; ENGINE_DETAIL="${ENGINE_DETAIL:-empty report}"; }

  # The self-budget gate only sees meute's own spend, never the subscription
  # it draws from -- a 429 here means the real pool is already gone and every
  # slot until the hold lifts would fail the same way for nothing.
  if (( RATE_LIMITED )); then
    local hold_secs paused_until
    hold_secs="$(hold_duration_seconds "$RATE_LIMIT_HOLD")"
    paused_until="$(hold_extend "$hold_secs" "auto: provider rate limit — ${ENGINE_DETAIL}")"
    note "provider rate limit hit; auto-paused until $(hold_until_human "$paused_until")"
  fi

  write_report "$report_rel" "$entry" "$engine" "$lens" "$base_ref" "$err"

  local committed="-"
  if (( WRITES_CODE )); then committed="$(commit_worktree "$repo" "$task" "$lens")"; fi

  # A tier-3 ticket that produced a branch is delivered; retire it so the next
  # weekly slot does not redo work already awaiting review.
  local ticket_id; ticket_id="$(jq -r '.ticket_id' <<< "$entry")"
  if [[ -n "$ticket_id" && "$committed" != "-" && "$committed" != "none" && "$ENGINE_STATUS" == "ok" ]]; then
    python3 "$MANIFEST_PY" mark-delivered "$MANIFEST" "$repo" "$ticket_id" "$BRANCH" >/dev/null \
      && note "ticket ${ticket_id} delivered on ${BRANCH}; retired from the queue"
  fi

  # The cursor advances on failure too: a poisoned entry must not stall the
  # whole fleet under cron. The log line is where failures surface.
  advance_past "$key"
  [[ "$lens" == "none" || "$ENGINE_STATUS" != "ok" ]] \
    || state_set "lens.${repo}.${task}" "$(( lens_index + 1 ))"

  log_run "$ENGINE_STATUS" "kind=${kind}" "repo=${repo}" "task=${task}" "tier=${tier}" \
          "lens=${lens}" "engine=${engine}" "auth=${AUTH_MODE}" "branch=${BRANCH}" "quota=${remaining_at_start}:${QUOTA_SOURCE}" "budget=${BUDGET_LEFT}" \
          ${SCRUBBED:+"scrubbed=${SCRUBBED// /,}"} "commit=${committed}" "report=${report_rel}" "cost=${COST}" "turns=${TURNS}" \
          ${ENGINE_DETAIL:+"detail=${ENGINE_DETAIL}"}
  [[ "$ENGINE_STATUS" == "ok" ]]
}

# Move the rotation past an entry, attempted or not. In plan mode the item is
# also marked so the plan can retire once every item has had its turn.
advance_past() {
  local key="$1"
  state_set "$(cursor_key)" "$key"
  if (( PLAN_MODE )); then
    kv_set "$PLAN_DONE_FILE" "$key" "$STARTED_AT"
    retire_completed_plan
  fi
}

# The manifest section an entry came from, as the validator names it, so a
# runtime refusal reads the same as the validation error it stands in for.
manifest_section() {
  case "$1" in
    personal)  printf 'repos\n' ;;
    community) printf 'community\n' ;;
    *)         printf '%s\n' "$1" ;;
  esac
}

# An entry the runner cannot even start on. Logged as an error with the cause
# in detail=, then stepped over: the log line is the only place an unattended
# failure surfaces, and an entry that dies before the cursor moves would be
# re-selected every fire, wedging the slot on it.
abort_entry() {
  local entry="$1" detail="$2"
  log_run "error" "kind=$(jq -r '.kind' <<< "$entry")" "repo=$(jq -r '.repo' <<< "$entry")" \
          "task=$(jq -r '.task' <<< "$entry")" "detail=${detail}"
  advance_past "$(jq -r '.key' <<< "$entry")"
  exit 1
}

# A worktree holds only what git tracks. Build plumbing that is gitignored by
# design -- Android's local.properties with its sdk.dir, a .env -- is absent,
# and a tier that has to run the build then fails on "SDK location not
# found" before it has done anything. Found live: the first tier-3 draft on
# an Android repo had to create local.properties by hand to get gradle to
# configure, and disclosed it under Blocked. Each repo names what to carry
# across; missing sources are skipped, never an error.
copy_worktree_files() {
  local entry="$1" rel source source_real repo_real part probe
  local -a parts
  repo_real="$(readlink -f -- "$REPO_PATH")" \
    || die "worktree files: cannot resolve repository path: ${REPO_PATH}"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    source="${REPO_PATH}/${rel}"
    [[ -f "$source" ]] || continue

    # `-f` follows symlinks. Refuse both a symlink file and a symlinked
    # directory component, so a manifest entry cannot smuggle host data into
    # an agent worktree. Every component is probed, the last one included.
    IFS=/ read -ra parts <<< "$rel"
    probe="$REPO_PATH"
    for part in "${parts[@]}"; do
      [[ -z "$part" || "$part" == "." ]] && continue
      probe+="/${part}"
      if [[ -L "$probe" ]]; then
        note "WARNING: skipped unsafe worktree file ${rel} (source traverses a symlink)"
        continue 2
      fi
    done
    source_real="$(readlink -f -- "$source")" || {
      note "WARNING: skipped unsafe worktree file ${rel} (source cannot be resolved)"
      continue
    }
    if [[ "$source_real" != "$repo_real/"* ]]; then
      note "WARNING: skipped unsafe worktree file ${rel} (source resolves outside the repository)"
      continue
    fi
    mkdir -p "${WORKTREE}/$(dirname "$rel")"
    cp -p -- "$source" "${WORKTREE}/${rel}"
    note "carried ${rel} into the worktree"
  done < <(jq -r '.worktree_files[]? // empty' <<< "$entry")
}

# The agent runs inside a worktree of the TARGET repo, so a path under MEUTE_ROOT
# is unreachable to it by construction. The policy that governs a contribution
# has to travel in the prompt, not as a filename.
etiquette_content() {
  local rel; rel="$(jq -r '.etiquette' <<< "$1")"
  if [[ -z "$rel" || ! -f "${MEUTE_ROOT}/${rel}" ]]; then
    printf '(no etiquette file — this project must not receive a contribution)\n'
    return 0
  fi
  cat "${MEUTE_ROOT}/${rel}"
}

# The report is written by the runner, not the subprocess: reports/ lives in
# meute while the worktree lives in the target repo, and a read-only audit
# cannot write outside its checkout by construction.
write_report() {
  local rel="$1" entry="$2" engine="$3" lens="$4" base_ref="$5" err="$6"
  local dest="${MEUTE_ROOT}/${rel}"
  mkdir -p "$(dirname "$dest")"
  {
    printf -- '---\n'
    printf 'repo: %s\n'    "$(jq -r '.repo' <<< "$entry")"
    printf 'task: %s\n'    "$(jq -r '.task' <<< "$entry")"
    printf 'tier: %s\n'    "$(jq -r '.tier' <<< "$entry")"
    printf 'lens: %s\n'    "$lens"
    printf 'slot: %s\n'    "$SLOT"
    printf 'engine: %s\n'  "$engine"
    printf 'model: %s\n'   "$MODEL"
    printf 'auth: %s\n'    "$AUTH_MODE"
    printf 'branch: %s\n'  "$BRANCH"
    printf 'base: %s\n'    "${base_ref}@${BASE_SHA}"
    printf 'started: %s\n' "$STARTED_AT"
    printf 'status: %s\n'  "$ENGINE_STATUS"
    printf 'cost_usd: %s\n' "$COST"
    printf 'turns: %s\n'   "$TURNS"
    printf -- '---\n\n'
    if [[ -n "$REPORT" ]]; then
      printf '%s\n' "$REPORT"
    else
      printf '# Run produced no report\n\n**Status:** %s — %s\n\n' "$ENGINE_STATUS" "${ENGINE_DETAIL:-no detail}"
      printf 'Last 40 lines of engine stderr:\n\n```\n%s\n```\n' "$(tail -n 40 "$err")"
    fi
  } > "$dest"
}

# Commits whatever the write tier left in the worktree, onto the scratch branch
# only. Never touches the target repo's default branch, never pushes.
commit_worktree() {
  local repo="$1" task="$2" lens="$3"
  local porcelain
  porcelain="$(git -C "$WORKTREE" -c "core.excludesFile=${MEUTE_ROOT}/lib/artifacts.gitignore" status --porcelain)"
  [[ -n "$porcelain" ]] || { printf 'none\n'; return 0; }
  local ident=()
  if [[ -z "$(git -C "$WORKTREE" config user.email || true)" ]]; then
    ident=( -c "user.name=${MEUTE_GIT_NAME:-meute}" -c "user.email=${MEUTE_GIT_EMAIL:-meute@localhost}" )
  fi
  # Layer meute's artifact excludes under the repo's own .gitignore so a green
  # test run does not commit its own __pycache__ / node_modules to the branch.
  git -C "$WORKTREE" -c "core.excludesFile=${MEUTE_ROOT}/lib/artifacts.gitignore" add -A
  git -C "$WORKTREE" "${ident[@]}" commit -q -m "$(printf 'chore: %s (%s)\n\nUnattended meute run on %s.\nTask: %s%s\nReview before merging; nothing here has been pushed.' \
      "$task" "$repo" "$DATE" "$task" "$([[ "$lens" != "none" ]] && printf ' (lens: %s)' "$lens")")"
  git -C "$WORKTREE" rev-parse --short HEAD
}

main "$@"
