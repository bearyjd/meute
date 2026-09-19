#!/usr/bin/env bash
#
# The portfolio plan: `meute plan`. Sourced by bin/meute.
#
# Inventory a directory tree without enrolling anything.  This is deliberately
# separate from `discover`: planning is read-only, safe to put in cron or run
# before deciding whether a repository belongs in the fleet.  Staging is not
# quite: each staged run still cuts a meute/<task>-<date> scratch branch and a
# worktree in the unenrolled repository (removed on exit; a killed run leaves
# them for `git worktree prune`).  The preview prints absolute paths, so it is
# for the operator's eyes, not a ticket.
#
# The ranking is intentionally boring and stable: a security baseline first,
# then an architecture review, then feature/market discovery.  Repositories
# sort by canonical path, so identical trees and manifests produce identical
# plans.  Only tasks a plan may stage are ranked (lib/manifest.py decides from
# the tier's tools): those that only read the checkout, and, with --allow-web,
# those that also reach the public web -- that would send what it learned
# about a private, never-enrolled repository to third parties, which is a
# decision, not a default.  A tier that can shell out or edit is never a
# plan's to stage; enrollment is the path for that work.
#
# Expects from the caller: MEUTE_ROOT, MANIFEST_PY, MANIFEST, STATE_DIR,
# dir_id, note, die.
# plan_collect_tasks sets PLAN_TASKS / PLAN_WEB_TASKS / PLAN_OTHER_TASKS.
# plan_scan_repos    sets PLAN_REPOS / PLAN_CONFIGURED / PLAN_UNCONFIGURED /
#                    PLAN_KNOWN_NAME.

declare -A PLAN_KNOWN_NAME=()

# A repository's identity that survives a reboot, for naming. dir_id's
# st_dev is not that: on btrfs a subvolume's device number is anonymous and
# can change at every mount, so the same repo would be a new name -- and a
# new plan-complete key -- after a reboot. The filesystem id (f_fsid, stable
# per filesystem, identical under a bind mount) plus the inode is.
repo_fingerprint() {
  printf '%s:%s' "$(stat -f -c '%i' -- "$1")" "$(stat -L -c '%i' -- "$1")"
}

# Is $1 at or below $2? Walked upwards and compared by identity, not by
# spelling, so a bind-mounted or symlinked root still matches. Stops at /.
under_scan_root() {
  local dir="$1" root_id; root_id="$(dir_id "$2")"
  while :; do
    [[ "$(dir_id "$dir")" == "$root_id" ]] && return 0
    [[ "$dir" == "/" ]] && return 1
    dir="$(dirname "$dir")"
  done
}

# The tasks a plan may stage, ranked, plus the two groups it left out.
plan_collect_tasks() {
  local allow_web="$1" line name plan_class
  local -a task_names=()
  PLAN_TASKS=(); PLAN_WEB_TASKS=(); PLAN_OTHER_TASKS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$(jq -r '.writes_code' <<< "$line")" == "false" ]] || continue
    name="$(jq -r '.name' <<< "$line")"
    # lib/manifest.py decides from the tier's tools what a plan may stage;
    # the runner-side validator applies the same verdict, so nothing ranked
    # here can be refused there. "other" -- Bash, Edit, anything unknown --
    # comes with an allowlist reviewed for enrolled projects only.
    plan_class="$(jq -r '.plan_class' <<< "$line")"
    case "$plan_class" in
      local) ;;
      web) (( allow_web )) || { PLAN_WEB_TASKS+=( "$name" ); continue; } ;;
      *) PLAN_OTHER_TASKS+=( "$name" ); continue ;;
    esac
    task_names+=( "$name" )
  done < <(python3 "$MANIFEST_PY" list-tasks "$MANIFEST")

  # Prefer the analyses that answer risk and structural questions before
  # opportunity research.  Unknown read-only tasks remain useful, but follow
  # the named baselines in lexical order.
  local preferred task
  for preferred in audit-security architecture-review suggest-features market-comparison; do
    for task in "${task_names[@]}"; do
      [[ "$task" == "$preferred" ]] && PLAN_TASKS+=( "$task" )
    done
  done
  while IFS= read -r preferred; do
    [[ -n "$preferred" ]] || continue
    case " ${PLAN_TASKS[*]} " in *" $preferred "*) ;; *) PLAN_TASKS+=( "$preferred" );; esac
  done < <(printf '%s\n' "${task_names[@]}" | LC_ALL=C sort -u)
}

# Every enrolled path, keyed by identity, not spelling: the manifest says
# /home/<you>/..., the scan may say /var/home/<you>/..., and both are the same
# directory.  This checkout counts as known under the name "meute".
plan_known_repos() {
  local line path name
  PLAN_KNOWN_NAME=()
  PLAN_KNOWN_NAME["$(dir_id "$MEUTE_ROOT")"]="meute"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    path="$(jq -r '.path' <<< "$line")"
    name="$(jq -r '.name // ""' <<< "$line")"
    PLAN_KNOWN_NAME["$(dir_id "$path")"]="$name"
  done < <(python3 "$MANIFEST_PY" list-repos "$MANIFEST")
}

# Is the directory holding this .git marker a repository of its own that a
# plan may audit?  Prints its path on stdout when so; says why not otherwise.
# A .git *file* marks a linked worktree or a submodule as readily as a
# checkout with --separate-git-dir; only git can tell them apart.  A linked
# worktree is another checkout of a repository already found (or enrolled),
# and a submodule is third-party code: neither is a repository of its own to
# audit on the operator's quota.
plan_classify() {
  local marker="$1" scan_dir="$2" real
  local -a gitdirs=()
  # A directory can vanish between find and cd (an agent worktree being
  # torn down); under set -e a bare assignment would abort the whole scan.
  real="$(cd "$(dirname "$marker")" 2>/dev/null && pwd)" \
    || { note "plan: skipping $(dirname "$marker"): vanished during the scan"; return 1; }
  # Line 1 is this checkout's git dir, line 2 the repository's; a linked
  # worktree has its own.  A third line is the superproject, printed only
  # for a submodule.
  mapfile -t gitdirs < <(git -C "$real" rev-parse --path-format=absolute \
    --git-dir --git-common-dir --show-superproject-working-tree 2>/dev/null)
  (( ${#gitdirs[@]} >= 2 )) \
    || { note "plan: skipping ${real}: git cannot read it"; return 1; }
  [[ "${gitdirs[0]}" == "${gitdirs[1]}" ]] || return 1
  [[ -z "${gitdirs[2]:-}" ]] || return 1
  # A `.git` file can point anywhere.  The repository git would actually
  # read has to live under the scan root, or a plan audits -- and cuts
  # scratch branches in -- a repository the operator never asked to scan.
  under_scan_root "${gitdirs[1]}" "$scan_dir" \
    || { note "plan: skipping ${real}: git dir outside the scan root"; return 1; }
  # `git init` and nothing else: no tree to audit, nothing to cut a
  # worktree from. Staged, it would fail every fire until someone noticed.
  git -C "$real" rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1 \
    || { note "plan: skipping ${real}: no commits yet"; return 1; }
  printf '%s\n' "$real"
}

# Find every repository under the scan root, once each, and split them by
# whether the manifest already knows them.
plan_scan_repos() {
  local scan_dir="$1" max_depth="$2" path real id
  local -A seen=()
  PLAN_REPOS=(); PLAN_CONFIGURED=(); PLAN_UNCONFIGURED=()
  plan_known_repos
  # Prune directory metadata so find does not descend into repository
  # internals.  -print0 preserves unusual paths.
  while IFS= read -r -d '' path; do
    real="$(plan_classify "$path" "$scan_dir")" || continue
    # The scan spelling is kept for display and staging; identity decides
    # whether two spellings are one repository.
    id="$(dir_id "$real")"
    [[ -n "${seen[$id]+present}" ]] && continue
    seen["$id"]=1
    PLAN_REPOS+=( "$real" )
  # `find` measures the .git marker, one level below the repository root.
  # The advertised limit is repository depth, so include that final marker.
  # Meute's own subtree -- this checkout and any in-flight .worktrees/* under
  # it -- is pruned by inode, so it is skipped under any spelling; the
  # trailing /. makes -samefile look through a symlinked MEUTE_ROOT.  -H so a
  # symlinked scan directory is descended (find otherwise stops at the link)
  # without following symlinks found inside the tree.
  done < <(find -H "$scan_dir" -mindepth 1 -maxdepth "$(( max_depth + 1 ))" \
    \( -samefile "${MEUTE_ROOT}/." -prune \) \
    -o \( -type d -name .git -prune -print0 \) \
    -o \( -type f -name .git -print0 \) 2>/dev/null)

  while IFS= read -r real; do
    [[ -n "$real" ]] || continue
    [[ -n "${PLAN_KNOWN_NAME[$(dir_id "$real")]+present}" ]] \
      && PLAN_CONFIGURED+=( "$real" ) || PLAN_UNCONFIGURED+=( "$real" )
  done < <(printf '%s\n' "${PLAN_REPOS[@]}" | LC_ALL=C sort -u)
}

# The inventory and the ranked proposal, with what was left out and why.
plan_print() {
  local scan_dir="$1" max_depth="$2" real task reason rank=1
  printf 'Portfolio inventory (read-only)\n'
  printf '  scan: %s (max depth: %s)\n' "$scan_dir" "$max_depth"
  printf '  discovered: %d  configured: %d  unconfigured: %d\n' \
    "${#PLAN_REPOS[@]}" "${#PLAN_CONFIGURED[@]}" "${#PLAN_UNCONFIGURED[@]}"
  printf '\nComparison\n'
  for real in "${PLAN_CONFIGURED[@]}"; do
    printf '  configured    %-24s %s\n' "${PLAN_KNOWN_NAME[$(dir_id "$real")]:-<unnamed>}" "$real"
  done
  for real in "${PLAN_UNCONFIGURED[@]}"; do
    printf '  unconfigured  %-24s %s\n' "$(basename "$real")" "$real"
  done
  (( ${#PLAN_REPOS[@]} )) || printf '  (no Git repositories found)\n'

  printf '\nProposed read-only analysis plan\n'
  printf '  Ranking: unconfigured repositories first; then security, architecture, features, market; path breaks ties.\n'
  if (( ${#PLAN_UNCONFIGURED[@]} == 0 )); then
    printf '  (nothing to enroll; configured repositories remain on their manifest schedules)\n'
  elif (( ${#PLAN_TASKS[@]} == 0 )); then
    printf '  (manifest declares no read-only tasks)\n'
  else
    for real in "${PLAN_UNCONFIGURED[@]}"; do
      for task in "${PLAN_TASKS[@]}"; do
        case "$task" in
          audit-security) reason="security baseline" ;;
          architecture-review) reason="structure and maintainability" ;;
          suggest-features) reason="feature opportunities" ;;
          market-comparison) reason="market gaps" ;;
          *) reason="declared read-only analysis" ;;
        esac
        printf '  %3d. %-24s %-22s %s\n' "$rank" "$(basename "$real")" "$task" "$reason"
        rank=$(( rank + 1 ))
      done
    done
  fi
  (( ${#PLAN_WEB_TASKS[@]} == 0 )) \
    || printf '  (excluded %d web-research task(s): %s — pass --allow-web to stage them)\n' \
         "${#PLAN_WEB_TASKS[@]}" "$(IFS=,; printf '%s' "${PLAN_WEB_TASKS[*]}")"
  (( ${#PLAN_OTHER_TASKS[@]} == 0 )) \
    || printf '  (excluded %d task(s) whose tier needs enrollment (Bash or other tools): %s)\n' \
         "${#PLAN_OTHER_TASKS[@]}" "$(IFS=,; printf '%s' "${PLAN_OTHER_TASKS[*]}")"
}

# Write state/plan-queue.json: one entry per (unconfigured repo, task), under
# a synthetic name the runner can use as a repo name.
plan_stage() {
  local scan_dir="$1" allow_web="$2" real task stem safe_name
  (( ${#PLAN_UNCONFIGURED[@]} && ${#PLAN_TASKS[@]} )) || die "plan: nothing to stage"
  mkdir -p "$STATE_DIR"
  local entries_file queue_tmp queue_file
  entries_file="$(mktemp "${STATE_DIR}/.plan-entries.XXXXXX")"
  queue_tmp="$(mktemp "${STATE_DIR}/.plan-queue.XXXXXX")"
  queue_file="${STATE_DIR}/plan-queue.json"
  for real in "${PLAN_UNCONFIGURED[@]}"; do
    stem="$(basename "$real" | tr -cs 'A-Za-z0-9._-' '-')"
    stem="${stem#-}"; stem="${stem%-}"
    [[ -n "$stem" && "$stem" =~ ^[A-Za-z0-9] ]] || stem="repository"
    # Named by identity, not by position: the same repository gets the same
    # name whichever spelling found it and whatever else appeared, and two
    # repos sharing a basename in different directories do not share one.
    safe_name="plan-${stem}-$(repo_fingerprint "$real" | sha1sum | cut -c1-6)"
    for task in "${PLAN_TASKS[@]}"; do
      jq -cn --arg name "$safe_name" --arg path "$real" --arg task "$task" \
        --arg spec "Unconfigured repository discovered by meute plan; read-only analysis only." \
        '{name:$name, path:$path, task:$task, spec:$spec}' >> "$entries_file"
    done
  done
  # The runner's validator re-checks every staged tier against this flag,
  # so a hand-edited plan cannot smuggle a web tier past a plan that never
  # allowed one.
  local web_json=false; (( allow_web )) && web_json=true
  jq -s . "$entries_file" | jq -n --arg scan "$scan_dir" --argjson entries "$(cat)" \
    --argjson web "$web_json" \
    '{version:1, scan:$scan, allow_web:$web, entries:$entries}' > "$queue_tmp" \
    || { rm -f "$entries_file" "$queue_tmp"; die "plan: could not stage plan queue"; }
  mv -f "$queue_tmp" "$queue_file"
  # Completion markers belong to the previous explicit plan.  The next plan
  # may reuse synthetic names and task names, so never let stale attempts
  # silently suppress newly staged work.
  rm -f "${STATE_DIR}/plan-complete"
  rm -f "$entries_file"
  printf '\nStaged %d read-only analysis item(s) in %s. The normal runner will prioritize this explicit queue; it cannot enroll repositories or run a writing tier, but each run still cuts a meute/<task>-<date> scratch branch and a worktree in the unenrolled repository (removed when the run ends; a killed run leaves them for git worktree prune).\n' \
    "$(( ${#PLAN_UNCONFIGURED[@]} * ${#PLAN_TASKS[@]} ))" "$queue_file"
}
