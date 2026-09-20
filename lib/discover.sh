#!/usr/bin/env bash
#
# Enrollment: `meute discover`. Sourced by bin/meute.
#
# Finds git repositories under a directory that the manifest does not know
# yet and interactively adds the ones you pick. Only ever writes
# repos.local.yaml; lib/manifest.py add-repo refuses repos.yaml itself.
#
# Expects from the caller: MEUTE_ROOT, MANIFEST_PY, MANIFEST, dir_id, note, die.

# The branch a repo's audits and drafts should be cut from: what origin calls
# its default, else main, else master, else whatever is checked out. NOT
# simply the current branch -- a repo mid-feature would otherwise be audited
# on, and have fixes drafted against, unfinished work. Found live: five of
# the first twenty-one repos added were sitting on a feature branch.
repo_default_branch() {
  local repo="$1" ref
  # `|| true` on the substitution itself: under set -e a failing $(...) in an
  # assignment aborts the whole function before any fallback runs.
  ref="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$ref" ]]; then printf '%s\n' "${ref#origin/}"; return 0; fi
  local b
  for b in main master; do
    git -C "$repo" show-ref --verify -q "refs/heads/$b" && { printf '%s\n' "$b"; return 0; }
  done
  git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || printf ''
}

# Scan a directory for git repos not already in the manifest, and interactively
# add the ones you pick. Only ever writes repos.local.yaml -- lib/manifest.py's
# add-repo refuses repos.yaml itself, so there's no PR-required-file edited here.
cmd_discover() {
  local requested="${1:-$HOME/Documents/vibe-code}"
  local scan_dir
  scan_dir="$(cd "$requested" 2>/dev/null && pwd)" || die "discover: no such directory: ${requested}"

  [[ "$(basename "$MANIFEST")" != "repos.yaml" ]] \
    || die "discover: no repos.local.yaml found -- create one first: cp repos.yaml repos.local.yaml (it's gitignored, so nothing you add to it needs a PR)"

  # Paths already configured, personal or community -- and this checkout
  # itself, since meute-ai-trader typically lives inside the same directory
  # it's asked to scan.
  local -A known=()
  known["$(dir_id "$MEUTE_ROOT")"]=1
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    known["$(dir_id "$(jq -r '.path' <<< "$line")")"]=1
  done < <(python3 "$MANIFEST_PY" list-repos "$MANIFEST")

  local -a candidates=()
  local d real
  for d in "$scan_dir"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    [[ -e "$d/.git" ]] || continue
    real="$(cd "$d" && pwd)"
    [[ -n "${known[$(dir_id "$real")]:-}" ]] && continue
    candidates+=( "$real" )
  done

  if (( ${#candidates[@]} == 0 )); then
    note "discover: no new git repositories found under ${scan_dir}"
    return 0
  fi

  note "discover: found ${#candidates[@]} repo(s) under ${scan_dir} not yet configured:"
  local i branch
  for (( i = 0; i < ${#candidates[@]}; i++ )); do
    branch="$(git -C "${candidates[$i]}" symbolic-ref --short HEAD 2>/dev/null || printf '?')"
    printf '  %2d) %-28s %s  (branch: %s)\n' "$(( i + 1 ))" "$(basename "${candidates[$i]}")" \
      "${candidates[$i]}" "$branch" >&2
  done

  printf 'Add which? (numbers space-separated, "all", or blank to cancel): ' >&2
  local selection=""; read -r selection || true
  [[ -n "$selection" ]] || { note "discover: cancelled, nothing added"; return 0; }

  local -a chosen_idx=() tok
  if [[ "$selection" == "all" ]]; then
    for (( i = 1; i <= ${#candidates[@]}; i++ )); do chosen_idx+=( "$i" ); done
  else
    for tok in $selection; do
      [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#candidates[@]} )) \
        || die "discover: '${tok}' is not a valid selection (expected 1-${#candidates[@]})"
      chosen_idx+=( "$tok" )
    done
  fi

  # Available tasks and a safe default: the read-only tier-2 reports. Tasks
  # that write code default OFF -- a freshly discovered repo's tooling is
  # unknown, and lint-sweep/dep-audit/gen-tests against the wrong toolchain
  # burns a slot to produce nothing.
  local -a task_names=() task_writes=() preselected=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    task_names+=( "$(jq -r '.name' <<< "$line")" )
    task_writes+=( "$(jq -r '.writes_code' <<< "$line")" )
  done < <(python3 "$MANIFEST_PY" list-tasks "$MANIFEST")
  for (( i = 0; i < ${#task_names[@]}; i++ )); do
    [[ "${task_writes[$i]}" == "false" ]] && preselected+=( "$(( i + 1 ))" )
  done

  local idx repo_path repo_name default_branch spec
  for idx in "${chosen_idx[@]}"; do
    repo_path="${candidates[$(( idx - 1 ))]}"
    repo_name="$(basename "$repo_path")"

    note ""
    note "-- ${repo_name} (${repo_path}) --"
    for (( i = 0; i < ${#task_names[@]}; i++ )); do
      local mark=" "
      [[ " ${preselected[*]} " == *" $(( i + 1 )) "* ]] && mark="x"
      printf '  [%s] %2d) %-20s writes_code=%s\n' "$mark" "$(( i + 1 ))" "${task_names[$i]}" "${task_writes[$i]}" >&2
    done
    printf 'Tasks for %s (numbers, Enter for the default above, "none"): ' "$repo_name" >&2
    local task_sel=""; read -r task_sel || true

    local -a task_choice_idx=()
    if [[ -z "$task_sel" ]]; then
      task_choice_idx=( "${preselected[@]}" )
    elif [[ "$task_sel" != "none" ]]; then
      for tok in $task_sel; do
        [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#task_names[@]} )) \
          || die "discover: '${tok}' is not a valid task selection (expected 1-${#task_names[@]})"
        task_choice_idx+=( "$tok" )
      done
    fi
    local -a chosen_tasks=()
    for i in "${task_choice_idx[@]}"; do
      [[ -n "$i" ]] && chosen_tasks+=( "${task_names[$(( i - 1 ))]}" )
    done

    default_branch="$(repo_default_branch "$repo_path")"

    printf 'One-line spec for %s (what it is -- goes into every prompt, no default): ' "$repo_name" >&2
    spec=""
    while [[ -z "$spec" ]]; do
      read -r spec || true
      [[ -n "$spec" ]] || printf 'spec cannot be blank, try again: ' >&2
    done

    local tasks_json="[]"
    if (( ${#chosen_tasks[@]} )); then
      tasks_json="$(printf '%s\n' "${chosen_tasks[@]}" | jq -R . | jq -s .)"
    fi
    local payload added
    payload="$(jq -n --arg n "$repo_name" --arg p "$repo_path" --arg s "$spec" \
                     --arg b "$default_branch" --argjson t "$tasks_json" \
               '{name:$n, path:$p, spec:$s, default_branch:$b, tasks:$t}')"
    added="$(python3 "$MANIFEST_PY" add-repo "$MANIFEST" "$payload")" \
      || die "discover: failed to add ${repo_name} — the manifest was not changed"
    note "discover: added '${added}' to $(basename "$MANIFEST") with tasks: ${chosen_tasks[*]:-<none>}"
  done
}
