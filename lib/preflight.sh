#!/usr/bin/env bash
#
# Subscription-only guarantees for the meute runner. Sourced by bin/run.sh.
#
# meute never runs on metered API billing. Two defences, both always on: keys
# are stripped from the child environment, and a zero-cost preflight refuses to
# start unless the engine resolved to a real subscription.

# A shell's ambient configuration can silently route a CLI through a proxy or a
# third-party endpoint as well as switch it from subscription to API-key auth.
# Keep this explicit rather than using `env -i`: the CLIs still need normal
# login/config discovery, PATH, locale, and terminal behaviour.
readonly ENGINE_SCRUB_VARS=(
  ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
  ANTHROPIC_BASE_URL ANTHROPIC_API_URL ANTHROPIC_ENDPOINT
  OPENAI_API_KEY OPENAI_BASE_URL OPENAI_API_BASE OPENAI_ORG_ID OPENAI_PROJECT
  CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
  HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
  http_proxy https_proxy all_proxy no_proxy
)

scrub_env() {
  local present=() var
  for var in "${ENGINE_SCRUB_VARS[@]}"; do
    if [[ -n "${!var:-}" ]]; then present+=( "$var" ); fi
  done
  ENGINE_ENV=(env)
  for var in "${ENGINE_SCRUB_VARS[@]}"; do
    ENGINE_ENV+=( -u "$var" )
  done
  if (( ${#present[@]} )); then
    note "WARNING: ${present[*]} present in this environment."
    note "WARNING: unset for the child process — meute uses direct subscription authentication only."
    SCRUBBED="${present[*]}"
  fi
}

# Preflight costs nothing: both CLIs report resolved auth without a round trip.
# Running the probe through the scrubbed env means we verify exactly the auth the
# child will use, not the auth this shell happens to have.
preflight() {
  case "$1" in
    claude) preflight_claude ;;
    codex)  preflight_codex ;;
    *) die "unknown engine: $1" ;;
  esac
}

# --------------------------------------------------------------------------
# The same guarantee, asked of the credential the run will actually use.
#
# Under `runtime: container` the host's login is not what the engine reaches:
# the container mounts a COPY in a volume, and that copy can be absent,
# empty, or signed out while the host's is fine. So the probe runs inside the
# image, on --network=none, with only that engine's volume mounted -- no
# network, no scratch tree, no cost.
#
# It RETURNS rather than dies. A missing credential is a precondition the
# operator can remediate (`just auth`, or a re-login), so bin/run.sh routes
# it through abort_precondition: a forced run stays retryable and an unforced
# one advances, which is the rule Phase 2a settled. The host path above still
# dies, because there the failure is the machine's own configuration.
#
# Sets PREFLIGHT_DETAIL on failure and AUTH_MODE on success.
# --------------------------------------------------------------------------
preflight_container() {
  local entry="$1" engine="$2"
  PREFLIGHT_DETAIL=""
  case "$engine" in
    claude) preflight_container_claude "$entry" ;;
    codex)  preflight_container_codex "$entry" ;;
    *) PREFLIGHT_DETAIL="unknown engine: ${engine}"; return 1 ;;
  esac
}

# jq lives on the host, not in the image: the container's job is to produce
# the status, and the host's is to judge it. That split also means the checks
# below are the same ones the host path applies.
preflight_container_claude() {
  local entry="$1" status key_source plan
  status="$(container_run "$entry" preflight claude "" "" -- claude auth status --json 2>/dev/null)" \
    || { PREFLIGHT_DETAIL="claude auth status failed inside the container - the volume may be empty; run: just auth"; return 1; }
  if [[ "$(jq -r '.loggedIn // false' <<< "$status" 2>/dev/null)" != "true" ]]; then
    PREFLIGHT_DETAIL="claude is not logged in inside the container; run: just auth"
    return 1
  fi
  key_source="$(jq -r '.apiKeySource // ""' <<< "$status")"
  if [[ -n "$key_source" ]]; then
    PREFLIGHT_DETAIL="claude resolved auth from ${key_source} inside the container; refusing metered billing"
    return 1
  fi
  plan="$(jq -r '.subscriptionType // ""' <<< "$status")"
  if [[ -z "$plan" || "$plan" == "null" ]]; then
    PREFLIGHT_DETAIL="claude reports no subscription plan inside the container; run: just auth"
    return 1
  fi
  AUTH_MODE="$(jq -r '.authMethod // "unknown"' <<< "$status")/${plan}"
}

preflight_container_codex() {
  local entry="$1" status
  status="$(container_run "$entry" preflight codex "" "" -- codex login status 2>&1)" \
    || { PREFLIGHT_DETAIL="codex login status failed inside the container - the volume may be empty; run: just auth"; return 1; }
  if ! grep -qi 'chatgpt' <<< "$status"; then
    PREFLIGHT_DETAIL="codex did not report a ChatGPT subscription inside the container (got: ${status})"
    return 1
  fi
  AUTH_MODE="codex/chatgpt"
}

preflight_claude() {
  local status key_source plan
  command -v claude >/dev/null || die "preflight: the 'claude' CLI is not on PATH."
  status="$("${ENGINE_ENV[@]}" claude auth status --json 2>/dev/null)" \
    || die "preflight: 'claude auth status' failed — most likely not signed in. Run:  claude auth login"
  [[ "$(jq -r '.loggedIn // false' <<< "$status")" == "true" ]] \
    || die "preflight: claude is not logged in. Run:  claude auth login"
  key_source="$(jq -r '.apiKeySource // ""' <<< "$status")"
  [[ -z "$key_source" ]] \
    || die "preflight: claude still resolved auth from ${key_source} after scrubbing. Refusing to run on metered billing."
  plan="$(jq -r '.subscriptionType // ""' <<< "$status")"
  [[ -n "$plan" && "$plan" != "null" ]] \
    || die "preflight: claude is authenticated but reports no subscription plan. Run:  claude auth login"
  AUTH_MODE="$(jq -r '.authMethod // "unknown"' <<< "$status")/${plan}"
}

preflight_codex() {
  local status
  command -v codex >/dev/null || die "preflight: the 'codex' CLI is not on PATH."
  status="$("${ENGINE_ENV[@]}" codex login status 2>&1)" \
    || die "preflight: codex is not logged in. Run:  codex login"
  grep -qi 'chatgpt' <<< "$status" \
    || die "preflight: codex did not report a ChatGPT subscription (got: ${status}). Run:  codex login"
  AUTH_MODE="codex/chatgpt"
}
