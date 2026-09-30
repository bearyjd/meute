#!/usr/bin/env bash
#
# The scratch tree under `runtime: container` (PRP-004 §4.2). Sourced by
# bin/run.sh and bin/meute.
#
# A linked worktree cannot cross the boundary: its `.git` is a file pointing
# at $REPO_PATH/.git/worktrees/<name>, a host path that does not exist inside
# the container, so `git status`, `git diff` and every template's output
# contract fail there. Mounting the owner's `.git` was weighed and rejected --
# it puts the owner's real refs inside the agent's namespace and relabels the
# owner's inodes. So: a self-contained clone, which is a repository in its own
# right on the other side of the mount.
#
# Separate from lib/container.sh because none of this is podman: it is git,
# host-side, before and after the run. Under `runtime: host` the runner still
# cuts a worktree; this file is only for the container path and the probe.
#
# Self-contained: it defines its own note() rather than expecting the caller's.

scratch_note() { printf 'meute: %s\n' "$*" >&2; }

# --------------------------------------------------------------------------
# A repository that uses Git LFS, on a machine without git-lfs.
#
#   scratch_git_env <repo> <commit>
#
# The host the timers run on has no git-lfs. An LFS repository then cannot be
# checked out at all: the smudge filter cannot start, and the post-checkout
# hook `git lfs install` writes exits 2 (plan-UnrealClaude, 2026-09-27,
# worktree-add-failed). Every task reads source and none needs the binaries,
# so for such a repo the run keeps the pointer files: the filter is off, and
# SCRATCH_LFS_OVERRIDE=1 tells the caller so.
#
# Through the environment (GIT_CONFIG_COUNT), not -c on one command: every
# later git call in the run -- status, diff -- would otherwise hit the same
# missing filter. Never written into the owner's .git/config, which a linked
# worktree shares. The engine a host run starts inherits it too, so the
# agent's own `git status` works on the pointers. A container run does not;
# nothing in the container's environment comes from here.
#
# Only a read-only tier ever runs under it. With the clean filter off, any
# `git add` -- the runner's or the engine's -- stores an LFS file as its full
# content, so bin/run.sh refuses a writing tier whenever this sets the
# override (lfs-repo-needs-git-lfs-for-write-tiers), before any checkout.
#
# Hooks are not in it. Only bin/run.sh's host `git worktree add` runs with
# them off, and only under the override: that is where the post-checkout
# fails. Every other hook the run meets stays on.
#
# Whether the repo uses LFS is asked of <commit>, the tree about to be checked
# out, not of the owner's index: the owner may sit on a branch from before LFS
# arrived. Its .gitattributes are grepped for filter=lfs, which needs no
# git-lfs. git's own exit status answers, never a pipe into a reader that
# stops early: under the runner's pipefail the writer's SIGPIPE read as "no
# LFS" once the path list outgrew the pipe. A check that cannot be answered
# fails closed and says so: it is read as LFS present, so the override is on
# and bin/run.sh refuses a writing tier rather than letting one through on a
# guess.
# --------------------------------------------------------------------------
scratch_git_env() {
  local repo="$1" commit="$2" rc
  SCRATCH_LFS_OVERRIDE=0
  command -v git-lfs >/dev/null 2>&1 && return 0
  git -C "$repo" grep -q -e 'filter=lfs' "${commit:-}" -- .gitattributes '**/.gitattributes' 2>/dev/null \
    && rc=0 || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) scratch_note "could not tell whether ${repo##*/} uses Git LFS at ${commit:-<none>} (git grep exited ${rc}); treated as LFS present" ;;
  esac
  local n="${GIT_CONFIG_COUNT:-0}" kv
  # Appended after what the caller already set, read as git reads it
  # (strtoul): leading blanks and a plus sign skipped, 08 decimal rather than
  # bad octal. A count git rejects failed the git grep above already, and
  # is replaced: the list then starts at 0, a count git accepts.
  n="${n#"${n%%[![:space:]]*}"}"; n="${n#+}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$(( 10#$n ))
  for kv in filter.lfs.process= filter.lfs.smudge= filter.lfs.clean= \
            filter.lfs.required=false; do
    export "GIT_CONFIG_KEY_${n}=${kv%%=*}" "GIT_CONFIG_VALUE_${n}=${kv#*=}"
    n=$(( n + 1 ))
  done
  export GIT_CONFIG_COUNT="$n"
  SCRATCH_LFS_OVERRIDE=1
  scratch_note "${repo##*/} uses Git LFS and git-lfs is absent: pointer files kept"
}

# --------------------------------------------------------------------------
# The clone.
#
#   scratch_clone <repo> <scratch> <default_branch> <branch> <base_sha>
#
# `--no-local` is load-bearing, not a style choice. A local-path clone
# hardlinks the ENTIRE object store -- every branch, and purged history of
# the kind PRP-001 §10 had to rewrite out of a public repo -- because
# --single-branch cannot limit what hardlinking copies. The transport path
# honours --single-branch and cannot hardlink, so the clone carries one
# branch and relabelling it touches no inode the owner owns.
#
# `--branch` is passed only when the ref resolves; otherwise the clone takes
# the source's HEAD, matching the host path's own fallback. A later stage
# passes the branch it is continuing and gets that instead.
# --------------------------------------------------------------------------
scratch_clone() {
  local repo="$1" scratch="$2" default_branch="$3" branch="$4" base_sha="$5"
  local -a args=( clone --no-local --single-branch )
  # The branch a later stage continues already exists in the source; a build's
  # branch does not exist anywhere yet, so the clone takes the default branch
  # and cuts the new one from the recorded base afterwards.
  local clone_ref=""
  if git -C "$repo" rev-parse --verify -q "refs/heads/${branch}" >/dev/null 2>&1; then
    clone_ref="$branch"
  elif [[ -n "$default_branch" ]] \
       && git -C "$repo" rev-parse --verify -q "refs/heads/${default_branch}" >/dev/null 2>&1; then
    clone_ref="$default_branch"
  fi
  [[ -z "$clone_ref" ]] || args+=( --branch "$clone_ref" )
  git "${args[@]}" -- "$repo" "$scratch" >/dev/null 2>&1 \
    || { scratch_note "could not clone ${repo} into the scratch tree"; return 1; }

  # Already on the branch this stage continues: nothing to cut.
  [[ "$(git -C "$scratch" rev-parse --abbrev-ref HEAD)" != "$branch" ]] || return 0
  # The base must be in the clone to be checked out. It is for a build (the
  # default branch's tip came across) and for a later stage (an ancestor of
  # the branch that did). If it is not -- a base from a ref that never
  # arrived -- the clone is refused: the run resolved that base once, asked
  # it about LFS, and the host path checks out exactly it, so the clone's
  # own HEAD would be a different tree under the same name.
  git -C "$scratch" rev-parse --verify -q "${base_sha}^{commit}" >/dev/null 2>&1 \
    || { scratch_note "base ${base_sha:0:12} did not arrive in the scratch clone"; return 1; }
  git -C "$scratch" checkout -q -b "$branch" "$base_sha" \
    || { scratch_note "could not cut ${branch} in the scratch tree"; return 1; }
}

# Build plumbing git cannot see -- Android's local.properties with its
# sdk.dir, a .env -- travels into the clone exactly as into a worktree.
# Missing sources are skipped, never an error; the caller's own safety checks
# (bin/run.sh copy_worktree_files) decide what is safe to carry.
scratch_copy_files() {
  local repo="$1" scratch="$2" rel
  shift 2
  for rel in "$@"; do
    [[ -n "$rel" && -f "${repo}/${rel}" ]] || continue
    mkdir -p "${scratch}/$(dirname "$rel")"
    cp -p -- "${repo}/${rel}" "${scratch}/${rel}"
  done
}

# --------------------------------------------------------------------------
# Getting the work back out.
#
# git refuses to fetch onto a branch that is checked out anywhere in the
# target repository -- which is the expected way to read a draft -- and onto
# a non-fast-forward. Both are ordinary, and neither may cost the run its
# work: the clone is removed after the fire, so a refused import that is not
# caught leaves the branch nowhere at all.
# --------------------------------------------------------------------------

# Checked before the run, so an entry whose branch the owner has open is
# stepped over rather than worked on and then stranded.
scratch_branch_is_checked_out() {
  local repo="$1" branch="$2"
  git -C "$repo" worktree list --porcelain 2>/dev/null \
    | awk -v want="branch refs/heads/${branch}" '$0 == want { found = 1 } END { exit !found }'
}

# Sets SCRATCH_IMPORT to `branch` or `aside`, and SCRATCH_IMPORT_REF to what
# the work can be read from. The aside ref is dated and force-updated: a
# non-branch ref is never checked out, so it cannot be refused the same way,
# and a second refusal on the same branch still lands somewhere.
scratch_import() {
  local repo="$1" scratch="$2" branch="$3" date="$4"
  SCRATCH_IMPORT=""; SCRATCH_IMPORT_REF=""
  if git -C "$repo" fetch -q "$scratch" "${branch}:${branch}" 2>/dev/null; then
    SCRATCH_IMPORT="branch"; SCRATCH_IMPORT_REF="$branch"
    return 0
  fi
  local aside="refs/meute/import/${branch}-${date}"
  if git -C "$repo" fetch -q "$scratch" "+${branch}:${aside}" 2>/dev/null; then
    SCRATCH_IMPORT="aside"; SCRATCH_IMPORT_REF="$aside"
    scratch_note "could not fast-forward ${branch}; imported the run's work to ${aside}"
    return 0
  fi
  scratch_note "could not import ${branch} from the scratch tree"
  return 1
}
