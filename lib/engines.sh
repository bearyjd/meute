#!/usr/bin/env bash
#
# Engine adapters for the meute runner. Sourced by bin/run.sh.
#
# Each engine_argv_*/extract_* pair normalises one CLI onto the same four globals:
#   REPORT         the engine's final message (the report body)
#   ENGINE_STATUS  ok | error
#   ENGINE_DETAIL  short reason when status is error
#   COST, TURNS    accounting for state/log, or "-" when unavailable
#   RATE_LIMITED   1 when the provider itself declined with HTTP 429 (claude
#                  only for now -- codex's failure shape is not yet observed)
#
# Add an engine by adding a pair here and a case arm in run_entry.
#
# Each builder also sets ENGINE_ARGV_ENGINE to the engine it just built a
# command for. That declaration is what lib/container.sh checks before it
# mounts a credential, rather than inspecting the command itself: argv[0]
# can be `claude`, `/usr/local/bin/claude`, `env FOO=1 claude` or any
# wrapper, and a check that recognised only the bare name would pass while
# one provider's agent ran on the other's OAuth token. The builder knows
# what it built; the mount checks the claim.
#
# The argv builders RUN NOTHING. They populate ENGINE_ARGV and return; the
# caller supplies the working directory, the timeout and the redirection,
# because those three differ on the two sides of the container boundary
# (PRP-004 §4.4): on the host the runner cds into the worktree and wraps the
# call in `timeout`, while in a container the working directory is /work,
# podman enforces the timeout, and the paths the engine is told about are the
# container's. The host path is reconstructed by bin/run.sh exactly as it was.

# --------------------------------------------------------------------------
# Engine invocation. Returns a normalised (report, status, cost, turns) via
# globals, because the two CLIs surface their results in different places:
# claude puts the final message in a JSON envelope on stdout, codex streams
# JSONL events and writes the final message to a file.
# --------------------------------------------------------------------------
engine_argv_claude() {
  local prompt_file="$1"
  # The builder declares what it built, so the container's credential check
  # never has to inspect the command. See the note above ENGINE_ARGV_ENGINE.
  ENGINE_ARGV_ENGINE="claude"
  ENGINE_ARGV=(
    claude
    -p "$(cat "$prompt_file")"
    --output-format json
    --model "$MODEL"
    --tools "$TOOLS"
    --permission-mode "$PERMISSION_MODE"
    --strict-mcp-config
    --disable-slash-commands
    --setting-sources "${MEUTE_SETTING_SOURCES:-}"
  )
  # A narrow Bash allowlist is what lets a write tier actually run its own test
  # suite: acceptEdits auto-approves edits but still denies arbitrary execution,
  # so without this a "self-verifying" task cannot verify anything.
  [[ -n "$ALLOWED_TOOLS" ]] && ENGINE_ARGV+=( --allowed-tools "$ALLOWED_TOOLS" )
  return 0
}

extract_claude() {
  local out="$1"
  if ! jq -e . "$out" > /dev/null 2>&1; then
    REPORT=""; ENGINE_STATUS="error"; ENGINE_DETAIL="non-json output"; return 1
  fi
  REPORT="$(jq -r '.result // ""' "$out")"
  COST="$(jq -r '.total_cost_usd // "-"' "$out")"
  TURNS="$(jq -r '.num_turns // "-"' "$out")"
  RATE_LIMITED=0
  if [[ "$(jq -r '.is_error // false' "$out")" == "true" ]]; then
    ENGINE_STATUS="error"
    # subtype is the CLI's own event name and reads as "success" even when
    # is_error is true and the call actually failed -- first observed on a
    # 429, and again on the 401 a revoked credential returns. Whenever the
    # provider gave a status, report THAT and the message it came with;
    # parroting the field that is easiest to print puts the word "success"
    # on the line an operator greps to find failures.
    local status_code msg
    status_code="$(jq -r '.api_error_status // empty' "$out")"
    if [[ -n "$status_code" ]]; then
      msg="$(jq -r '.result // "no message"' "$out")"
      # state/log is tab-separated, one line per fire; a detail carrying
      # either would split the record it is part of.
      msg="${msg//$'\t'/ }"; msg="${msg//$'\n'/ }"
      if [[ "$status_code" == "429" ]]; then
        RATE_LIMITED=1
        ENGINE_DETAIL="rate-limited: ${msg}"
      else
        ENGINE_DETAIL="api ${status_code}: ${msg}"
      fi
    else
      ENGINE_DETAIL="$(jq -r '.subtype // "unknown"' "$out")"
    fi
    return 1
  fi
  ENGINE_STATUS="ok"; ENGINE_DETAIL=""
  return 0
}

# Which sandbox codex runs under, decided by what else is holding the line.
#
# On the host, codex's own sandbox IS the only boundary: the agent shares the
# owner's filesystem, home directory and network, and nothing else stands
# between a write and any of it. There it keeps workspace-write.
#
# Inside the container that boundary has been replaced and exceeded -- no
# $HOME, no other repositories, no unrestricted network, every capability
# dropped, no-new-privileges, a read-only image root. Measured inside that
# container, everything writable is already the agent's own: /work (its
# scratch clone), /out (the capture directory the runner reads back), /tmp
# and /var/tmp (tmpfs, gone at --rm), and codex's own credential volume,
# which is a COPY and which it must read to authenticate at all. /etc, /usr,
# /var, /run, / and /home/agent are read-only.
#
# And codex's in-process sandbox cannot initialise there: it reports "both
# available write methods failed due to environment permissions" and the run
# completes GREEN having changed nothing -- status=ok, commit=none, and a
# report explaining it could not write. A second layer that cannot start is
# not security; it is the silent-success failure PRP-001 §10a is about.
#
# A tier that writes nothing relaxes nothing, in either runtime.
codex_sandbox() {
  local runtime="$1" writes_code="$2"
  [[ "$writes_code" == "1" ]] || { printf 'read-only\n'; return 0; }
  [[ "$runtime" == "container" ]] || { printf 'workspace-write\n'; return 0; }
  printf 'danger-full-access\n'
}

# codex names its working directory and its final-message file on the command
# line rather than inheriting them, so both are parameters: the host passes
# the worktree and a mktemp, a container passes /work and a path under /out
# (nothing the runner reads may land in the branch -- commit_worktree runs
# `git add -A`). The runtime is a parameter for the same reason -- it decides
# the sandbox above, and it comes from the entry, never from the environment.
engine_argv_codex() {
  local prompt_file="$1" workdir="$2" last_message="$3" runtime="${4:-host}"
  ENGINE_ARGV_ENGINE="codex"
  local sandbox; sandbox="$(codex_sandbox "$runtime" "${WRITES_CODE:-0}")"
  ENGINE_ARGV=( codex exec --json -o "$last_message" -s "$sandbox"
                -c approval_policy="never" --cd "$workdir" --skip-git-repo-check )
  [[ -n "${MEUTE_CODEX_MODEL:-}" ]] && ENGINE_ARGV+=( -m "${MEUTE_CODEX_MODEL}" )
  ENGINE_ARGV+=( "$(cat "$prompt_file")" )
  return 0
}

extract_codex() {
  COST="-"; TURNS="-"
  if [[ -s "$CODEX_LAST" ]]; then
    REPORT="$(cat "$CODEX_LAST")"; ENGINE_STATUS="ok"; ENGINE_DETAIL=""; return 0
  fi
  REPORT=""; ENGINE_STATUS="error"; ENGINE_DETAIL="codex produced no final message"
  return 1
}

