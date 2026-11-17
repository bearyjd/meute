#!/usr/bin/env bash
#
# Targeted enqueue: `meute plan --enqueue --only <path>...`. Sourced by
# bin/meute after lib/plan_cache.sh.
#
# Naming the repositories is the operator saying which ones, so the tree is
# not walked: each named path is checked cheaply (exists, holds a .git, under
# the scan root, not meute's own checkout), then classified and deduplicated
# on its own. Every refusal is collected, so one run reports all the bad
# paths, and the caller decides between refusing the request and staging the
# rest (--skip-invalid).
#
# Dedup compares the named paths with each other, with every enrolled
# repository, and with the copies a previous scan recorded in state/plan-cache
# under the same root commit (lib/plan_cache.sh) -- so a scratch copy is still
# refused in favour of its canonical one without walking the tree. With a
# cold cache (no plan has run since the cache was deleted) that last group is
# empty and an unenrolled canonical copy elsewhere in the tree goes unseen.
# Depth is not limited: the operator named the path.
#
# Expects lib/plan.sh, lib/plan_dedup.sh and lib/plan_cache.sh, plus
# MEUTE_ROOT, dir_id and note. Sets PLAN_REJECTED (the refused arguments, in
# order) / PLAN_REJECT_WHY (argument -> message), and the same PLAN_* arrays
# plan_scan_repos and plan_dedup set, holding the named paths only.

PLAN_REJECTED=()
declare -A PLAN_REJECT_WHY=() PLAN_ONLY_REAL=()
PLAN_ONLY_ARGS=(); PLAN_ONLY_PEERS=()

plan_only_reject() {
  [[ -n "${PLAN_REJECT_WHY[$1]+present}" ]] && return 0
  PLAN_REJECTED+=( "$1" ); PLAN_REJECT_WHY["$1"]="$2"
}

# The cheap checks: no git, no walk. Sets PLAN_ONLY_ARGS (the arguments that
# passed) and PLAN_ONLY_REAL (argument -> resolved path). The own-checkout
# test walks the physical path: a symlink elsewhere must not hide it.
plan_only_precheck() {
  local scan_dir="$1" arg real why; shift
  PLAN_ONLY_ARGS=(); PLAN_ONLY_REAL=()
  for arg in "$@"; do
    why=""
    if ! real="$(cd "$arg" 2>/dev/null && pwd)"; then why="no such directory"
    elif [[ ! -e "$real/.git" ]]; then why="not a Git repository"
    elif ! under_scan_root "$real" "$scan_dir"; then why="outside the scan root ${scan_dir}"
    elif under_scan_root "$(cd "$real" && pwd -P)" "$MEUTE_ROOT"; then why="inside meute's own checkout"
    fi
    if [[ -n "$why" ]]; then
      plan_only_reject "$arg" "plan: --only ${arg}: not an unconfigured repository (${why})"
    else
      PLAN_ONLY_ARGS+=( "$arg" ); PLAN_ONLY_REAL["$arg"]="$real"
    fi
  done
}

# Same-key copies a previous scan recorded, as candidates for canonical, in
# PLAN_ONLY_PEERS. Run in this shell, not a subshell, so the identities it
# computes stay in the cache for plan_dedup.
plan_only_peers() {
  local scan_dir="$1" path; shift
  local -A keys=() named=()
  PLAN_ONLY_PEERS=()
  for path in "$@"; do
    named["$path"]=1
    plan_identity "$path" && keys["$PLAN_ID"]=1
  done
  for path in "${!PLAN_CACHE_KEY[@]}"; do
    [[ -n "${keys[${PLAN_CACHE_KEY[$path]}]+present}" && -z "${named[$path]+present}" ]] || continue
    [[ -e "$path/.git" && -z "${PLAN_KNOWN_NAME[$(dir_id "$path")]+present}" ]] || continue
    plan_classify "$path/.git" "$scan_dir" >/dev/null 2>&1 || continue
    PLAN_ONLY_PEERS+=( "$path" )
  done
  return 0
}

# Classify and dedup the paths plan_only_precheck passed.
plan_only_scan() {
  local scan_dir="$1" arg real id msg
  local -A seen=() named=()
  local -a valid=() kept=() diverged=()
  plan_known_repos
  for arg in "${PLAN_ONLY_ARGS[@]}"; do
    real="${PLAN_ONLY_REAL[$arg]}"
    id="$(dir_id "$real")"
    [[ -z "${seen[$id]+present}" ]] || continue
    seen["$id"]=1
    if [[ -n "${PLAN_KNOWN_NAME[$id]+present}" ]]; then
      plan_only_reject "$arg" "plan: --only ${arg}: not an unconfigured repository (already enrolled as ${PLAN_KNOWN_NAME[$id]:-<unnamed>})"
    elif ! plan_classify "$real/.git" "$scan_dir" >/dev/null; then
      plan_only_reject "$arg" "plan: --only ${arg}: not an unconfigured repository (a linked worktree, a submodule, or not one git can use)"
    else
      valid+=( "$real" ); named["$real"]="$arg"
    fi
  done
  PLAN_ONLY_PEERS=()
  (( ${#valid[@]} == 0 )) || plan_only_peers "$scan_dir" "${valid[@]}"

  # Every enrolled repository anchors, wherever it lives: stricter than a
  # scan, which sees only the enrolled ones under its root.
  PLAN_CONFIGURED=()
  for real in "${PLAN_KNOWN_PATHS[@]}"; do
    [[ -d "$real" ]] && PLAN_CONFIGURED+=( "$real" )
  done
  PLAN_UNCONFIGURED=()
  (( ${#valid[@]} + ${#PLAN_ONLY_PEERS[@]} == 0 )) \
    || mapfile -t PLAN_UNCONFIGURED < <(printf '%s\n' "${valid[@]}" "${PLAN_ONLY_PEERS[@]}" | LC_ALL=C sort -u)
  plan_dedup "$scan_dir"

  for real in "${valid[@]}"; do
    msg="$(plan_collapsed_reason "${named[$real]}")" && plan_only_reject "${named[$real]}" "$msg"
  done
  for real in "${PLAN_UNCONFIGURED[@]}"; do
    [[ -n "${named[$real]+present}" ]] && kept+=( "$real" )
  done
  for real in "${PLAN_DIVERGED[@]}"; do
    [[ -n "${named[$real]+present}" ]] && diverged+=( "$real" )
  done
  # The refused named paths are reported as refusals, the peers not at all.
  PLAN_REPOS=( "${kept[@]}" ); PLAN_UNCONFIGURED=( "${kept[@]}" ); PLAN_CONFIGURED=()
  PLAN_DIVERGED=( "${diverged[@]}" ); PLAN_DUPLICATES=(); PLAN_SKIPPED=()
  return 0
}

# One line per refused argument on stdout, path before message, so the web
# page can match each to what it sent: `rejected<TAB>argument<TAB>message`.
plan_only_report() {
  local arg
  for arg in "${PLAN_REJECTED[@]}"; do
    printf 'rejected\t%s\t%s\n' "$arg" "${PLAN_REJECT_WHY[$arg]}"
  done
}
