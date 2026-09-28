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
#
# The billing half of the list is lib/container.sh's ENGINE_BILLING_VARS, which
# the container path --unsetenv's too: one list, two consumers. Without it
# this file refuses to load rather than scrub nothing, and both callers run
# under `set -e`, so a failed source ends them.
if [[ -z "${ENGINE_BILLING_VARS[*]:-}" ]]; then
  printf 'meute: lib/preflight.sh needs ENGINE_BILLING_VARS; source lib/container.sh first\n' >&2
  return 1
fi
readonly ENGINE_SCRUB_VARS=(
  "${ENGINE_BILLING_VARS[@]}"
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
# codex's container mounts a COPY in a volume, and that copy can be absent,
# empty, or signed out while the host's is fine. So codex's probe runs inside
# the image, on --network=none, with only its volume mounted -- no network,
# no scratch tree, no cost. Claude's credential is a podman secret instead,
# which only proxied runs carry, so its check is host-side (see below).
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
  PREFLIGHT_DETAIL=""; PREFLIGHT_SECRET_RC=""
  case "$engine" in
    claude) preflight_container_claude "$entry" ;;
    codex)  preflight_container_codex "$entry" ;;
    *) PREFLIGHT_DETAIL="unknown engine: ${engine}"; return 1 ;;
  esac
}

# Claude's precondition is the token secret, asked of the HOST (PRP-004 §8).
# There is deliberately no container here. The preflight runs on
# --network=none, and the secret goes only to proxied runs, so an in-image
# `claude auth status` could only read the volume's .credentials.json --
# revoked, and not the credential the run uses. It would pass against a dead
# file, and refuse a good secret if the volume were ever emptied.
#
# Absent is a REFUSAL, never a fallback. A proxied claude run without the
# secret falls back to that volume file, and if it is ever valid its refresh
# revokes the host's token -- the original race. podman itself also refuses
# to start a container naming a missing secret; this is the check that says
# so with a stage and a remedy, before anything starts. A podman that cannot
# answer is not a podman that said yes: every non-zero status refuses.
#
# It proves presence, not validity: a revoked token still exists. That hole
# is the one §8 already names for the in-container probe, not a new one.
preflight_container_claude() {
  local entry="$1" secret rc=0 network
  # The secret reaches proxied runs only, so a claude container entry on any
  # other network would run with no credential but the volume's file. The
  # value itself, not `// "proxied"`: a default here would be a pass.
  network="$(jq -r '.network // ""' <<< "$entry")"
  if [[ "$network" != "proxied" ]]; then
    PREFLIGHT_DETAIL="claude runs in a container need network: proxied to receive the token secret (this entry: '${network:-unset}')"
    return 1
  fi
  # A rejected name is never echoed: it is not a secret name, so it may be
  # anything -- a pasted token, or a tab or newline that splits the log line.
  secret="$(container_claude_secret 2>/dev/null)" \
    || { PREFLIGHT_DETAIL="MEUTE_CLAUDE_SECRET is not a plain podman secret name (value not shown)"; return 1; }
  container_claude_secret_exists || rc=$?
  # For the runner's post-failure re-check: which answer podman gave, by
  # exit status, never by what it printed.
  PREFLIGHT_SECRET_RC="$rc"
  case "$rc" in
    0) AUTH_MODE="oauth-token/secret:${secret}" ;;
    1) PREFLIGHT_DETAIL="claude token secret ${secret} is not present on the host; in Atelier run: just auth-login claude"
       return 1 ;;
    *) PREFLIGHT_DETAIL="could not check the claude token secret ${secret} on the host (podman rc=${rc}); refusing rather than falling back to the volume; if it is missing, in Atelier run: just auth-login claude"
       return 1 ;;
  esac
}

preflight_container_codex() {
  local entry="$1" status
  local ENGINE_ARGV_ENGINE="codex"
  status="$(container_run "$entry" preflight codex "" "" -- codex login status 2>&1)" \
    || { PREFLIGHT_DETAIL="codex login status failed inside the container - the volume may be empty; in Atelier run: just auth-login codex"; return 1; }
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
