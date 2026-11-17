#!/usr/bin/env bash
#
# The plan identity cache: state/plan-cache. Sourced by bin/meute after
# lib/plan_dedup.sh.
#
# plan_root_commit walks a repository's whole history; over a real portfolio
# that is most of a plan's run time, repeated on every scan for repositories
# that did not change. A commit's root set is fixed by its SHA, so the key is
# cached per path and HEAD: an unchanged repository costs one rev-parse.
# A shallow clone deepened without a new HEAD keeps its old boundary key and
# so keys apart from its original -- the same safe way round as uncached.
#
# One line per repository: `HEAD<TAB>key<TAB>path`, the path last so a tab in
# it survives `read`; a path with a newline is never cached. A failed walk is
# never cached, so a repository skipped for unreadable history is checked
# again next time. Malformed lines are ignored; the file is derived data and
# deleting it is always safe. Rewritten whole through a temp file, so a
# concurrent plan (the web scan and the CLI) sees one version or the other.
#
# Expects from the caller: STATE_DIR, plan_root_commit, note.

declare -A PLAN_CACHE_HEAD=() PLAN_CACHE_KEY=()
PLAN_CACHE_DIRTY=0
PLAN_ID=""

plan_cache_load() {
  local file="${STATE_DIR}/plan-cache" head key path
  PLAN_CACHE_HEAD=(); PLAN_CACHE_KEY=(); PLAN_CACHE_DIRTY=0
  [[ -f "$file" ]] || return 0
  while IFS=$'\t' read -r head key path; do
    [[ "$head" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ && "$key" =~ ^[0-9a-f]{40}([0-9a-f,]*)$ \
       && "$path" == /* ]] || continue
    PLAN_CACHE_HEAD["$path"]="$head"; PLAN_CACHE_KEY["$path"]="$key"
  done < "$file"
}

# Sets PLAN_ID to the repository's identity key (plan_root_commit's), or
# returns 1 when its history cannot be read. No subshell, so the cache
# survives the call.
plan_identity() {
  local path="$1" head
  PLAN_ID=""
  head="$(git -C "$path" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" || return 1
  if [[ "${PLAN_CACHE_HEAD[$path]:-}" == "$head" ]]; then
    PLAN_ID="${PLAN_CACHE_KEY[$path]}"
    return 0
  fi
  PLAN_ID="$(plan_root_commit "$path")" || return 1
  [[ "$path" != *$'\n'* ]] || return 0
  PLAN_CACHE_HEAD["$path"]="$head"; PLAN_CACHE_KEY["$path"]="$PLAN_ID"; PLAN_CACHE_DIRTY=1
}

# Write the cache back when this run learned something, dropping paths that
# are gone. A failure costs the next run its speed, never its answer.
plan_cache_save() {
  (( PLAN_CACHE_DIRTY )) || return 0
  local file="${STATE_DIR}/plan-cache" tmp path
  mkdir -p "$STATE_DIR" 2>/dev/null \
    && tmp="$(mktemp "${STATE_DIR}/.plan-cache.XXXXXX" 2>/dev/null)" \
    || { note "plan: could not write ${file}; the next plan walks history again"; return 0; }
  for path in "${!PLAN_CACHE_KEY[@]}"; do
    [[ -d "$path" ]] || continue
    printf '%s\t%s\t%s\n' "${PLAN_CACHE_HEAD[$path]}" "${PLAN_CACHE_KEY[$path]}" "$path"
  done | LC_ALL=C sort > "$tmp" && mv -f "$tmp" "$file" \
    || { rm -f "$tmp"; note "plan: could not write ${file}; the next plan walks history again"; }
  return 0
}
