# Startup sweep of what a killed runner left behind (R14), sourced by
# bin/run.sh and bin/meute.
#
# A SIGKILL, an OOM kill or a reboot skips every exit trap, so the dead run's
# worktree (.worktrees/<repo>-<task>-<date>.<pid>), its scratch branch, its
# state/tmp/run.<pid>.* directory and any state/.kv.* temp file stay behind.
# bin/run.sh calls sweep_stale once, under the run lock; `meute doctor` calls
# sweep_stale --dry-run and prints what it would remove.
#
# An entry belongs to a live runner only when /proc/<pid>/cmdline names
# run.sh, which also covers a PID the kernel has handed to something else.
# MEUTE_PROC replaces /proc (tests). This process's own PID is always live.
# The scratch branch goes only while it still sits where it was cut (its
# first reflog entry): a branch that holds a commit is a draft and stays.
#
# Expects STATE_DIR (default <root>/state), WORKTREE_DIR (default
# <root>/.worktrees) and note() from the caller. Never fails the caller.

_sweep_dry=0

_sweep_say() {
  if (( _sweep_dry )); then printf 'would remove %s\n' "$*"
  else note "sweep: removed $*"; fi
}

# _sweep_live <pid>
_sweep_live() {
  local pid="$1" cmd
  [[ "$pid" == "$$" ]] && return 0
  [[ -r "${MEUTE_PROC:-/proc}/${pid}/cmdline" ]] || return 1
  cmd="$(tr '\0' ' ' < "${MEUTE_PROC:-/proc}/${pid}/cmdline" 2>/dev/null)" || return 1
  [[ "$cmd" == *run.sh* ]]
}

# _sweep_worktree <dir>: a registered worktree or, under runtime: container,
# a plain clone. Both are named for the runner's PID.
_sweep_worktree() {
  local dir="$1" common="" branch="" tip="" first=""
  if [[ -f "$dir/.git" ]]; then
    common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
    branch="$(git -C "$dir" symbolic-ref -q --short HEAD 2>/dev/null)" || branch=""
    if [[ -n "$common" && -n "$branch" ]]; then
      tip="$(git --git-dir="$common" rev-parse -q --verify "refs/heads/${branch}" 2>/dev/null)" || tip=""
      first="$(git --git-dir="$common" reflog show --format=%H "refs/heads/${branch}" 2>/dev/null | tail -n 1)" || first=""
    fi
  fi
  _sweep_say "worktree ${dir}"
  (( _sweep_dry )) && return 0
  if [[ -n "$common" ]]; then
    git --git-dir="$common" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
    git --git-dir="$common" worktree prune >/dev/null 2>&1 || true
    if [[ -n "$tip" && "$tip" == "$first" ]] \
       && git --git-dir="$common" branch -q -D "$branch" >/dev/null 2>&1; then
      _sweep_say "branch ${branch}"
    fi
  else
    rm -rf "$dir"
  fi
}

# sweep_stale [--dry-run]
sweep_stale() {
  _sweep_dry=0; [[ "${1:-}" == "--dry-run" ]] && _sweep_dry=1
  local state="${STATE_DIR:-${MEUTE_ROOT}/state}" wtd="${WORKTREE_DIR:-${MEUTE_ROOT}/.worktrees}"
  local tmpd="${MEUTE_TMPDIR:-${state}/tmp}" d pid f

  for d in "$wtd"/*; do
    [[ -d "$d" && ! -L "$d" && "$d" =~ \.([0-9]+)$ ]] || continue
    pid="${BASH_REMATCH[1]}"
    _sweep_live "$pid" || _sweep_worktree "$d"
  done

  for d in "$tmpd"/run.*; do
    [[ -d "$d" && ! -L "$d" && "${d##*/}" =~ ^run\.([0-9]+)\. ]] || continue
    pid="${BASH_REMATCH[1]}"
    if ! _sweep_live "$pid"; then
      _sweep_say "temp dir ${d}"
      (( _sweep_dry )) || rm -rf "$d"
    fi
  done

  while IFS= read -r -d '' f; do
    _sweep_say "stale ${f}"
    (( _sweep_dry )) || rm -f "$f"
  done < <(find "$state" -maxdepth 1 -type f -name '.kv.*' -mmin +60 -print0 2>/dev/null)
  return 0
}
