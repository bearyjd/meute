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
  local at="$base_sha"
  # The base must be in the clone to be checked out. It is for a build (the
  # default branch's tip came across) and for a later stage (an ancestor of
  # the branch that did). If it is not -- a base from a branch that never
  # arrived -- the clone's own HEAD is the honest answer, as on the host.
  git -C "$scratch" rev-parse --verify -q "${at}^{commit}" >/dev/null 2>&1 || at="HEAD"
  git -C "$scratch" checkout -q -b "$branch" "$at" \
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
