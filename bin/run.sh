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
#   --repo <name>            force a repo (bypasses the cursor and the share gates)
#   --task <name>            force a task (bypasses the cursor and the share gates)
#   --dry-run                select and render, invoke nothing, touch no state
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
#   MEUTE_QUOTA_CMD        see bin/quota.sh
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
readonly WORKTREE_DIR="${MEUTE_ROOT}/.worktrees"
readonly DATE="$(date +%F)"
readonly STARTED_AT="$(date --iso-8601=seconds)"
readonly THIS_WEEK="$(date +%G-%V)"
# $SECONDS is 0 at script start, so elapsed time is just $SECONDS.
readonly START_EPOCH=0

SLOT=""
QUOTA_SOURCE="?"
remaining_at_start="?"
SCRUBBED=""
AUTH_MODE=""
ENGINE_OVERRIDE=""
FORCE_REPO=""
FORCE_TASK=""
DRY_RUN=0

# Populated during a run; the EXIT trap reads them.
REPO_PATH=""
WORKTREE=""
BRANCH=""
BASE_SHA=""

note() { printf 'meute: %s\n' "$*" >&2; }
die()  { printf 'meute: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# state/cursor holds both the round-robin cursor (one key per slot) and the
# per-(repo,task) lens rotation counters. Storage lives in lib/state.sh.
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
  printf '%s\n' "$line" >> "$LOG_FILE"
  printf '%s\n' "$line" >&2
}

# Exit 0 on every "not this time" path: cron must not see a scheduled chore
# declining to run as a failure.
skip() { log_run "skipped" "reason=$1" "${@:2}"; exit 0; }

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^#\( \|$\)//'; }

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
}


eligible() {
  local entry="$1" kind path tier
  kind="$(jq -r '.kind' <<< "$entry")"
  path="$(jq -r '.path' <<< "$entry")"
  tier="$(jq -r '.tier' <<< "$entry")"

  if [[ ! -d "$path/.git" && ! -f "$path/.git" ]]; then
    note "skipping $(jq -r '.key' <<< "$entry"): not a git repository at $path"
    return 1
  fi
  # A forced selection is an explicit human decision; only the path check stands.
  (( FORCED )) && return 0

  if [[ "$kind" == "community" ]] && ! community_allowed; then
    note "skipping $(jq -r '.key' <<< "$entry"): community share exhausted this week"
    return 1
  fi
  if [[ "$tier" == "tier3" ]]; then
    local in_flight; in_flight="$(tier3_in_flight)"
    if (( in_flight >= TIER3_CAP )); then
      note "skipping $(jq -r '.key' <<< "$entry"): ${in_flight} tier-3 drafts already in flight (cap ${TIER3_CAP})"
      return 1
    fi
  fi
  return 0
}

# Round-robin: resume at the entry after the last one executed for this slot,
# wrap around, and take the first eligible candidate.
select_entry() {
  local cursor start=0 i idx
  cursor="$(state_get "cursor.${SLOT}")"
  local total=${#QUEUE[@]}
  if [[ -n "$cursor" ]]; then
    for (( i = 0; i < total; i++ )); do
      if [[ "$(jq -r '.key' <<< "${QUEUE[i]}")" == "$cursor" ]]; then start=$(( i + 1 )); break; fi
    done
  fi
  for (( i = 0; i < total; i++ )); do
    idx=$(( (start + i) % total ))
    if eligible "${QUEUE[idx]}"; then printf '%s\n' "${QUEUE[idx]}"; return 0; fi
  done
  return 1
}

main() {
  parse_args "$@"
  mkdir -p "$STATE_DIR" "$WORKTREE_DIR" "${MEUTE_ROOT}/reports"
  command -v jq >/dev/null || die "jq is required"
  scrub_env
  command -v git >/dev/null || die "git is required"

  # One runner at a time. A slow run must not stack up under a tight timer.
  exec 9>"$LOCK_FILE"
  flock -n 9 || skip "another run holds the lock"

  python3 "$MANIFEST_PY" validate "$MANIFEST" >/dev/null || die "manifest failed validation"

  fleet_load_policy || die "could not read policy from ${MANIFEST}"

  # Not `|| true`: if this function goes missing the ceiling lapses silently,
  # which is the exact failure this change exists to prevent. It returns 1
  # legitimately when no ceiling is declared, so only a *missing* function
  # (127) is fatal.
  fleet_wire_self_budget; (( $? == 127 )) && die "lib/fleet.sh is missing fleet_wire_self_budget"

  local remaining probe
  probe="$("${MEUTE_ROOT}/bin/quota.sh" --with-source)" || skip "quota probe failed"
  remaining="${probe%% *}"
  QUOTA_SOURCE="${probe#* }"
  (( remaining < QUOTA_FLOOR )) \
    && skip "quota ${remaining}% below floor ${QUOTA_FLOOR}%" "quota=${remaining}"

  local queue_file
  queue_file="$(mktemp)"
  trap 'rm -f "$queue_file"' RETURN
  python3 "$MANIFEST_PY" queue "$MANIFEST" "$SLOT" > "$queue_file" || die "queue build failed"
  fleet_load_scope || die "queue build failed"
  remaining_at_start="$remaining"

  FORCED=0
  if [[ -n "$FORCE_REPO" || -n "$FORCE_TASK" ]]; then
    FORCED=1
    jq -c --arg r "$FORCE_REPO" --arg t "$FORCE_TASK" \
       'select(($r == "" or .repo == $r) and ($t == "" or .task == $t))' \
       "$queue_file" > "${queue_file}.f"
    mv "${queue_file}.f" "$queue_file"
  fi

  mapfile -t QUEUE < "$queue_file"
  (( ${#QUEUE[@]} )) || skip "no queue entries for slot ${SLOT}"

  local entry
  entry="$(select_entry)" || skip "no eligible entry for slot ${SLOT}"
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
  BASE_SHA="$(git -C "$REPO_PATH" rev-parse "$base_ref")"

  local prompt_file; prompt_file="$(mktemp)"
  python3 "$MANIFEST_PY" render "$template" \
    "REPO_NAME=${repo}" "REPO_SPEC=${spec}" "REPO_PATH=${REPO_PATH}" \
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
  WORKTREE="${WORKTREE_DIR}/${repo}-${task}-${DATE}.$$"
  git -C "$REPO_PATH" worktree add -q -b "$BRANCH" "$WORKTREE" "$base_ref" \
    || { log_run "error" "kind=${kind}" "repo=${repo}" "task=${task}" "detail=worktree-add-failed"; exit 1; }

  local out err; out="$(mktemp)"; err="$(mktemp)"
  CODEX_LAST="$(mktemp)"
  REPORT=""; ENGINE_STATUS="error"; ENGINE_DETAIL=""; COST="-"; TURNS="-"
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
  state_set "cursor.${SLOT}" "$key"
  [[ "$lens" == "none" || "$ENGINE_STATUS" != "ok" ]] \
    || state_set "lens.${repo}.${task}" "$(( lens_index + 1 ))"

  log_run "$ENGINE_STATUS" "kind=${kind}" "repo=${repo}" "task=${task}" "tier=${tier}" \
          "lens=${lens}" "engine=${engine}" "auth=${AUTH_MODE}" "branch=${BRANCH}" "quota=${remaining_at_start}:${QUOTA_SOURCE}" \
          ${SCRUBBED:+"scrubbed=${SCRUBBED// /,}"} "commit=${committed}" "report=${report_rel}" "cost=${COST}" "turns=${TURNS}" \
          ${ENGINE_DETAIL:+"detail=${ENGINE_DETAIL}"}

  # Last, so the log line written above is included in the same commit.
  commit_state "$repo" "$task"
  [[ "$ENGINE_STATUS" == "ok" ]]
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

# state/cursor, state/log and reports/ are meute's own committed history. A
# cron-driven runner that only wrote them would leave the operator staring at a
# permanently dirty checkout with nobody responsible for it. Pathspec-scoped so
# unrelated edits in the meute tree are never swept in. Never pushes.
commit_state() {
  [[ -z "${MEUTE_NO_AUTOCOMMIT:-}" ]] || return 0
  git -C "$MEUTE_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 0
  [[ -n "$(git -C "$MEUTE_ROOT" status --porcelain -- state reports)" ]] || return 0
  local ident=()
  if [[ -z "$(git -C "$MEUTE_ROOT" config user.email || true)" ]]; then
    ident=( -c "user.name=${MEUTE_GIT_NAME:-meute}" -c "user.email=${MEUTE_GIT_EMAIL:-meute@localhost}" )
  fi
  git -C "$MEUTE_ROOT" add -- state reports
  git -C "$MEUTE_ROOT" "${ident[@]}" commit -q \
    -m "run: ${1}/${2} ${DATE} (${ENGINE_STATUS})" -- state reports || true
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
