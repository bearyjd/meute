#!/usr/bin/env bash
#
# Duplicate copies in a portfolio plan. Sourced by bin/meute after
# lib/plan.sh.
#
# A scan finds the same repository many times over: scratch clones under an
# output/ or build/ directory, vendored upstream checkouts, a
# --separate-git-dir checkout next to the original. Each copy would get its
# own audits and re-audit the same code on the operator's quota. So the plan
# keys every repository by its root commit and stages one copy per key.
#
# Identity is the root commit (`rev-list --max-parents=0 HEAD`, the
# lexicographically smallest when there are several), never the remote URL:
# a URL can embed a credential, so this file never reads one. A repository
# whose history cannot be walked (a missing object, a broken alternate) has
# no identity: it is skipped, never collapsed with anything. A shallow clone
# reports its boundary commit, so it keys apart from its full original --
# the safe way round: it is planned twice rather than wrongly hidden.
#
# Per root commit: a copy of an enrolled repository is never staged. Else one
# unconfigured copy is canonical, picked by, in order: not scratch-looking;
# not a .git-file checkout when a plain one exists; fewest path components
# below the scan root; shortest path; then byte order. The rest are listed as
# duplicates of it. A lone repository is always kept, scratch-looking or not.
#
# Expects plan_scan_repos to have run. plan_dedup sets PLAN_UNCONFIGURED to
# the canonical copies only, PLAN_DUPLICATES / PLAN_DUP_OF / PLAN_DUP_LABEL /
# PLAN_DUP_REASON for the rest, and PLAN_SKIPPED.

# Directory names that mark a scratch, build-output or vendored copy, compared
# with each path component below the scan root; also any component ending in
# -ref or -worktree, or starting with verify- or check-. Conservative on
# purpose: it only decides which copy of a repository is planned, and never
# excludes a repository that has no other copy.
PLAN_SCRATCH_NAMES=( output outputs build builds dist vendor third_party upstream
  runtime tmp temp .local-research .worktrees worktrees checkout node_modules )

PLAN_DUPLICATES=(); PLAN_SKIPPED=()
declare -A PLAN_DUP_OF=() PLAN_DUP_LABEL=() PLAN_DUP_REASON=()

# The repository's identity key on stdout, or status 1 when its history
# cannot be read. git's own status decides: partial output from a failed
# walk is not an identity.
plan_root_commit() {
  local out
  out="$(git -C "$1" rev-list --max-parents=0 HEAD 2>/dev/null)" || return 1
  out="$(LC_ALL=C sort <<< "$out")"
  out="${out%%$'\n'*}"
  [[ "$out" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  printf '%s' "$out"
}

# Does this path, relative to the scan root, look like a scratch copy?
plan_is_scratch() {
  local comp name
  local -a comps=()
  IFS=/ read -r -a comps <<< "$1"
  for comp in "${comps[@]}"; do
    case "$comp" in *-ref|*-worktree|verify-*|check-*) return 0 ;; esac
    for name in "${PLAN_SCRATCH_NAMES[@]}"; do
      [[ "$comp" == "$name" ]] && return 0
    done
  done
  return 1
}

# One sortable line per copy: key, then the canonical order's fields, then
# the path last so a tab in it survives `read`.
plan_rank_line() {
  local key="$1" real="$2" scan_dir="$3" rel scratch=0 gitfile=0
  local -a comps=()
  rel="${real#"$scan_dir"/}"
  plan_is_scratch "$rel" && scratch=1
  [[ -f "$real/.git" ]] && gitfile=1
  IFS=/ read -r -a comps <<< "$rel"
  printf '%s\t%d\t%d\t%04d\t%06d\t%s\n' "$key" "$scratch" "$gitfile" \
    "${#comps[@]}" "${#real}" "$real"
}

# Record $1 as a duplicate of $2 (a path), shown as $3, for reason $4.
plan_mark_duplicate() {
  PLAN_DUP_OF["$1"]="$2"; PLAN_DUP_LABEL["$1"]="$3"; PLAN_DUP_REASON["$1"]="$4"
}

plan_dedup() {
  local scan_dir="$1" real key name
  local -A anchor=() canonical=() canonical_path=()
  local -a lines=() kept=()
  PLAN_DUPLICATES=(); PLAN_SKIPPED=()
  PLAN_DUP_OF=(); PLAN_DUP_LABEL=(); PLAN_DUP_REASON=()
  # An enrolled repository anchors its group. Several enrolled copies: the
  # first by path. One with unreadable history anchors nothing and stays
  # configured.
  for real in "${PLAN_CONFIGURED[@]}"; do
    key="$(plan_root_commit "$real")" || continue
    [[ -n "${anchor[$key]+present}" ]] || anchor["$key"]="$real"
  done
  for real in "${PLAN_UNCONFIGURED[@]}"; do
    if key="$(plan_root_commit "$real")"; then
      lines+=( "$(plan_rank_line "$key" "$real" "$scan_dir")" )
    else
      PLAN_SKIPPED+=( "$real" )
    fi
  done
  while IFS=$'\t' read -r key _ _ _ _ real; do
    [[ -n "$key" ]] || continue
    if [[ -n "${anchor[$key]+present}" ]]; then
      name="${PLAN_KNOWN_NAME[$(dir_id "${anchor[$key]}")]:-<unnamed>}"
      plan_mark_duplicate "$real" "${anchor[$key]}" "$name" "already enrolled as ${name}"
    elif [[ -n "${canonical[$key]+present}" ]]; then
      plan_mark_duplicate "$real" "${canonical[$key]}" "${canonical[$key]}" "duplicate of ${canonical[$key]}"
    else
      canonical["$key"]="$real"; canonical_path["$real"]=1
    fi
  done < <( (( ${#lines[@]} )) && printf '%s\n' "${lines[@]}" | LC_ALL=C sort )
  # Keep the scan's path order for both lists, so ranks stay as before.
  for real in "${PLAN_UNCONFIGURED[@]}"; do
    if [[ -n "${PLAN_DUP_OF[$real]+present}" ]]; then
      PLAN_DUPLICATES+=( "$real" )
    elif [[ -n "${canonical_path[$real]+present}" ]]; then
      kept+=( "$real" )
    fi
  done
  PLAN_UNCONFIGURED=( "${kept[@]}" )
}

# Refuse an --only path the dedup set aside, naming what to pass instead.
# Compared by identity, like plan_restrict_to.
plan_refuse_collapsed() {
  local path="$1" id real of
  id="$(dir_id "$path")"
  for real in "${PLAN_DUPLICATES[@]}"; do
    [[ "$(dir_id "$real")" == "$id" ]] || continue
    of="${PLAN_DUP_OF[$real]}"
    [[ "${PLAN_DUP_REASON[$real]}" == "duplicate of "* ]] \
      && die "plan: --only ${path} is a duplicate of ${of}; pass ${of} instead"
    die "plan: --only ${path} is a duplicate of ${of} (${PLAN_DUP_REASON[$real]}); it is not staged"
  done
  for real in "${PLAN_SKIPPED[@]}"; do
    [[ "$(dir_id "$real")" == "$id" ]] \
      && die "plan: --only ${path}: skipped, no readable history"
  done
  return 0
}

# The human sections, printed only when there is something to say, so a tree
# without copies prints exactly what it did before dedup.
plan_print_dedup() {
  local real
  if (( ${#PLAN_DUPLICATES[@]} )); then
    printf '\nDuplicates collapsed (%d)\n' "${#PLAN_DUPLICATES[@]}"
    for real in "${PLAN_DUPLICATES[@]}"; do
      printf '  %s -> %s\n' "$real" "${PLAN_DUP_LABEL[$real]}"
    done
  fi
  if (( ${#PLAN_SKIPPED[@]} )); then
    printf '\nSkipped (no readable history)\n'
    printf '  %s\n' "${PLAN_SKIPPED[@]}"
  fi
  return 0
}

# The two JSON lists, as the `duplicates` and `skipped` arrays on stdout,
# one per line.
plan_dedup_json() {
  local real
  local -a dups=() skips=()
  for real in "${PLAN_DUPLICATES[@]}"; do
    dups+=( "$(jq -cn --arg path "$real" --arg of "${PLAN_DUP_OF[$real]}" \
      --arg reason "${PLAN_DUP_REASON[$real]}" '{path:$path, of:$of, reason:$reason}')" )
  done
  for real in "${PLAN_SKIPPED[@]}"; do
    skips+=( "$(jq -cn --arg path "$real" '{path:$path, reason:"no readable history"}')" )
  done
  if (( ${#dups[@]} )); then printf '%s\n' "${dups[@]}" | jq -cs .; else echo '[]'; fi
  if (( ${#skips[@]} )); then printf '%s\n' "${skips[@]}" | jq -cs .; else echo '[]'; fi
}
