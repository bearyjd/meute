#!/usr/bin/env bash
#
# Engine adapters for the meute runner. Sourced by bin/run.sh.
#
# Each invoke_*/extract_* pair normalises one CLI onto the same four globals:
#   REPORT         the engine's final message (the report body)
#   ENGINE_STATUS  ok | error
#   ENGINE_DETAIL  short reason when status is error
#   COST, TURNS    accounting for state/log, or "-" when unavailable
#   RATE_LIMITED   1 when the provider itself declined with HTTP 429 (claude
#                  only for now -- codex's failure shape is not yet observed)
#
# Add an engine by adding a pair here and a case arm in run_entry.

# --------------------------------------------------------------------------
# Engine invocation. Returns a normalised (report, status, cost, turns) via
# globals, because the two CLIs surface their results in different places:
# claude puts the final message in a JSON envelope on stdout, codex streams
# JSONL events and writes the final message to a file.
# --------------------------------------------------------------------------
invoke_claude() {
  local prompt_file="$1" out="$2" err="$3"
  local args=(
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
  [[ -n "$ALLOWED_TOOLS" ]] && args+=( --allowed-tools "$ALLOWED_TOOLS" )
  ( cd "$WORKTREE" && timeout --kill-after=30 "$TIMEOUT_SECONDS" \
      "${ENGINE_ENV[@]}" claude "${args[@]}" ) > "$out" 2> "$err"
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
    # is_error is true and this was actually an HTTP 429 -- report the thing
    # that actually happened instead of parroting a misleading field.
    if [[ "$(jq -r '.api_error_status // empty' "$out")" == "429" ]]; then
      RATE_LIMITED=1
      local msg; msg="$(jq -r '.result // "no message"' "$out")"
      msg="${msg//$'\t'/ }"; msg="${msg//$'\n'/ }"
      ENGINE_DETAIL="rate-limited: ${msg}"
    else
      ENGINE_DETAIL="$(jq -r '.subtype // "unknown"' "$out")"
    fi
    return 1
  fi
  ENGINE_STATUS="ok"; ENGINE_DETAIL=""
  return 0
}

invoke_codex() {
  local prompt_file="$1" out="$2" err="$3"
  local sandbox="read-only"
  (( WRITES_CODE )) && sandbox="workspace-write"
  local args=( exec --json -o "$CODEX_LAST" -s "$sandbox"
               -c approval_policy="never" --cd "$WORKTREE" --skip-git-repo-check )
  [[ -n "${MEUTE_CODEX_MODEL:-}" ]] && args+=( -m "${MEUTE_CODEX_MODEL}" )
  args+=( "$(cat "$prompt_file")" )
  ( timeout --kill-after=30 "$TIMEOUT_SECONDS" "${ENGINE_ENV[@]}" codex "${args[@]}" ) > "$out" 2> "$err"
}

extract_codex() {
  COST="-"; TURNS="-"
  if [[ -s "$CODEX_LAST" ]]; then
    REPORT="$(cat "$CODEX_LAST")"; ENGINE_STATUS="ok"; ENGINE_DETAIL=""; return 0
  fi
  REPORT=""; ENGINE_STATUS="error"; ENGINE_DETAIL="codex produced no final message"
  return 1
}

