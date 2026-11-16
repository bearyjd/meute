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
# Identity is the set of root commits (`rev-list --max-parents=0 HEAD`,
# sorted and joined), never the remote URL: a URL can embed a credential, so
# this file never reads one. The whole set, not one root: a repository that
# merged an unrelated history (a subtree, --allow-unrelated-histories) shares
# a root with that other project, and must not be collapsed into it; an older
# clone from before such a merge keys apart, which is the safe way round. A
# repository
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
# A copy whose HEAD commit the canonical (or enrolled) repository does not
# have is diverged: it holds work the kept copy lacks, so it is kept and
# planned too, and reported. Uncommitted edits in a copy are ignored.
#
# Safe on untrusted checkouts: rev-list, rev-parse and cat-file read only the
# object store and refs -- no index, no hooks, no filters -- and an
# alternates entry is a read-only object lookup. The whole-history walk that
# --max-parents=0 needs is accepted: 7.2 s over a real 107-repo portfolio.
#
# Expects plan_scan_repos to have run. plan_dedup sets PLAN_UNCONFIGURED to
# the canonical and diverged copies, PLAN_DUPLICATES / PLAN_DUP_OF /
# PLAN_DUP_LABEL / PLAN_DUP_REASON for the rest, PLAN_DIVERGED / PLAN_DIV_OF,
# and PLAN_SKIPPED.

# Directory names that mark a scratch, build-output or vendored copy, compared
# with each path component below the scan root; also any component ending in
# -ref or -worktree, or starting with verify- or check-. Conservative on
# purpose: it only decides which copy of a repository is planned, and never
# excludes a repository that has no other copy.
PLAN_SCRATCH_NAMES=( output outputs build builds dist vendor third_party upstream
  runtime tmp temp .local-research .worktrees worktrees checkout node_modules )

PLAN_DUPLICATES=(); PLAN_SKIPPED=(); PLAN_DIVERGED=()
declare -A PLAN_DUP_OF=() PLAN_DUP_LABEL=() PLAN_DUP_REASON=() PLAN_DIV_OF=() PLAN_DIV_BLIND=()

# What a skipped repository's owner can do about it, after its path.
PLAN_SKIP_HINT="history unreadable, e.g. an alternates entry pointing at a deleted repository"

# The repository's identity key on stdout, or status 1 when its history
# cannot be read. git's own status decides: partial output from a failed
# walk is not an identity.
plan_root_commit() {
  local out
  local root key=""
  out="$(git -C "$1" rev-list --max-parents=0 HEAD 2>/dev/null)" || return 1
  while IFS= read -r root; do
    [[ "$root" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
    key+="${key:+,}${root}"
  done < <(LC_ALL=C sort -u <<< "$out")
  [[ -n "$key" ]] || return 1
  printf '%s' "$key"
}

# Does the kept repository $2 have copy $1's HEAD commit? Returns 0 if so, 2
# if not ($1 holds commits $2 lacks), 1 if $1's HEAD cannot be read. Either
# failure counts as diverged: keep, do not hide.
plan_head_in() {
  local oid
  oid="$(git -C "$1" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" || return 1
  git -C "$2" cat-file -e "${oid}^{commit}" 2>/dev/null || return 2
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

# Record $1 as a duplicate of $2 (a path), shown as $3, for reason $4 --
# unless $2 lacks $1's HEAD commit: then $1 is diverged, and kept.
plan_mark_duplicate() {
  local rc=0
  plan_head_in "$1" "$2" || rc=$?
  if (( rc )); then
    PLAN_DIV_OF["$1"]="$2"
    (( rc == 1 )) && PLAN_DIV_BLIND["$1"]=1
    return 0
  fi
  PLAN_DUP_OF["$1"]="$2"; PLAN_DUP_LABEL["$1"]="$3"; PLAN_DUP_REASON["$1"]="$4"
}

plan_dedup() {
  local scan_dir="$1" real key name
  local -A anchor=() canonical=() canonical_path=()
  local -a lines=() kept=()
  PLAN_DUPLICATES=(); PLAN_SKIPPED=(); PLAN_DIVERGED=()
  PLAN_DUP_OF=(); PLAN_DUP_LABEL=(); PLAN_DUP_REASON=(); PLAN_DIV_OF=(); PLAN_DIV_BLIND=()
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
      plan_mark_duplicate "$real" "${anchor[$key]}" "${name} (already enrolled)" "already enrolled as ${name}"
    elif [[ -n "${canonical[$key]+present}" ]]; then
      plan_mark_duplicate "$real" "${canonical[$key]}" "${canonical[$key]}" "duplicate of ${canonical[$key]}"
    else
      canonical["$key"]="$real"; canonical_path["$real"]=1
    fi
  done < <( (( ${#lines[@]} )) && printf '%s\n' "${lines[@]}" | LC_ALL=C sort )
  # Keep the scan's path order for every list, so ranks stay as before.
  for real in "${PLAN_UNCONFIGURED[@]}"; do
    if [[ -n "${PLAN_DUP_OF[$real]+present}" ]]; then
      PLAN_DUPLICATES+=( "$real" )
    elif [[ -n "${PLAN_DIV_OF[$real]+present}" ]]; then
      PLAN_DIVERGED+=( "$real" ); kept+=( "$real" )
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
      && die "plan: --only ${path} is a duplicate of ${of}; pass ${of} instead, or enroll ${path} in repos.local.yaml to audit it separately"
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
  if (( ${#PLAN_DIVERGED[@]} )); then
    printf '\nDiverged copies (kept)\n'
    for real in "${PLAN_DIVERGED[@]}"; do
      if [[ -n "${PLAN_DIV_BLIND[$real]+present}" ]]; then
        printf '  %s: HEAD unreadable (kept; compared with %s)\n' "$real" "${PLAN_DIV_OF[$real]}"
      else
        printf '  %s has commits %s lacks\n' "$real" "${PLAN_DIV_OF[$real]}"
      fi
    done
  fi
  if (( ${#PLAN_SKIPPED[@]} )); then
    printf '\nSkipped (no readable history)\n'
    for real in "${PLAN_SKIPPED[@]}"; do
      printf '  %s: %s; run `git -C %s fsck` or fix .git/objects/info/alternates\n' \
        "$real" "$PLAN_SKIP_HINT" "$real"
    done
  fi
  return 0
}

# The three JSON lists, as the `duplicates`, `skipped` and `diverged`
# arrays on stdout, one per line.
plan_dedup_json() {
  local real
  local -a dups=() skips=() divs=()
  for real in "${PLAN_DIVERGED[@]}"; do
    divs+=( "$(jq -cn --arg path "$real" --arg of "${PLAN_DIV_OF[$real]}" '{path:$path, of:$of}')" )
  done
  for real in "${PLAN_DUPLICATES[@]}"; do
    dups+=( "$(jq -cn --arg path "$real" --arg of "${PLAN_DUP_OF[$real]}" \
      --arg reason "${PLAN_DUP_REASON[$real]}" '{path:$path, of:$of, reason:$reason}')" )
  done
  for real in "${PLAN_SKIPPED[@]}"; do
    skips+=( "$(jq -cn --arg path "$real" '{path:$path, reason:"no readable history"}')" )
  done
  if (( ${#dups[@]} )); then printf '%s\n' "${dups[@]}" | jq -cs .; else echo '[]'; fi
  if (( ${#skips[@]} )); then printf '%s\n' "${skips[@]}" | jq -cs .; else echo '[]'; fi
  if (( ${#divs[@]} )); then printf '%s\n' "${divs[@]}" | jq -cs .; else echo '[]'; fi
}
