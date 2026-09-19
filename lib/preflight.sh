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
