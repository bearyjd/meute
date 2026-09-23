#!/usr/bin/env bash
#
# The container boundary (PRP-004 §3, §4.4, §5). Sourced by bin/meute,
# bin/run.sh and lib/doctor.sh.
#
# Everything that speaks to podman lives here and nowhere else: the wrapper
# resolution, the digest assert, the egress checks, the flag set, and the run
# itself. One file owns the boundary, so widening it is a diff against this
# file rather than a flag added somewhere a reviewer does not look.
#
# The podman reached is the HOST's. Inside a distrobox (/run/.containerenv
# exists) that means `distrobox-host-exec podman`; MEUTE_PODMAN names a
# wrapper outright and wins. Every call is bounded: a podman waiting on a
# stuck socket must not hang a timer fire or an interactive doctor.
#
# Self-contained on purpose -- it defines its own note() rather than expecting
# the caller's, so a test can source it alone.

# Atelier's contract, fixed by its audit and not re-decided here (PRP-004 §5).
readonly CONTAINER_EGRESS="atelier-egress"
readonly CONTAINER_NETWORK="atelier-internal"
readonly CONTAINER_PROXY_URL="http://atelier-egress:3128"
readonly PODMAN_TIMEOUT=15
# The host path's own kill grace, so a container that ignores SIGTERM dies on
# the same schedule as an engine that ignores it on the host.
readonly CONTAINER_STOP_TIMEOUT=30
# One volume per engine, holding a COPY of that engine's credential (PRP-004
# §4.4). Mounted read-write on purpose: both CLIs write to their config
# directory, and a refresh that cannot be written is a refresh that fails --
# `:ro` would not prevent a rotation, only break it. The copy is why that is
# safe: a write here does not touch the host's file.
#
# No stage mounts more than one, and no engine stage mounts the GitHub
# volume: `just auth` fills atelier-auth-gh with the owner's interactive
# token, which is full-scope, so nothing unattended may hold it. Publishing
# waits for the two fine-grained PATs (§5 item 2).
#
# `:z`, not `:Z`, and the difference is load-bearing. Private relabel (`:Z`)
# rewrites the volume's SELinux categories to the calling container's, so it
# works -- for that run. These volumes are SHARED with Atelier's interactive
# `agent-enter` containers by design (§5), so each fire would steal the label
# and the owner's own container would be denied its own credentials until it
# stole it back, and then the next fire would be. Measured: after a `:Z`
# mount the volume reads container_file_t:s0:c534,c848 and a second container
# is DENIED; after `:z` it reads container_file_t:s0 and any container can
# read it. The isolation `:Z` appears to buy here is illusory -- reaching
# this volume at all means naming it in a mount, and whoever can do that has
# already lost. /work and /out keep `:Z`: those are private per-run
# directories, where private relabel is exactly right.
# Which stages run an engine, and so must carry exactly one credential
# (§4.4). `publish` carries a GitHub token instead (Phase 5) and `probe`
# carries nothing at all -- both deliberately, and neither by falling
# through the engine branch, which is how "no credential" would otherwise
# become the quiet default for a typo. An unknown stage is refused rather
# than guessed at.
# One authority for the set, so it cannot grow in a case arm nobody's test
# enumerates: the arrays ARE the definition, and a test pins them.
# Not `readonly`: lib/ is sourced more than once in some shells (the suite
# does it), and a readonly array turns that into an error on stderr, which
# then lands in any caller capturing 2>&1. The constants above predate that
# lesson; these do not repeat it.
CONTAINER_ENGINE_STAGES=(preflight build review review-2 resolve)
CONTAINER_UNCREDENTIALED_STAGES=(probe publish)

container_stage_credential() {
  local want="$1" stage
  for stage in "${CONTAINER_ENGINE_STAGES[@]}"; do
    [[ "$want" != "$stage" ]] || { printf 'engine\n'; return 0; }
  done
  for stage in "${CONTAINER_UNCREDENTIALED_STAGES[@]}"; do
    [[ "$want" != "$stage" ]] || { printf 'none\n'; return 0; }
  done
  return 1
}

container_auth_mount() {
  case "$1" in
    claude) printf 'atelier-auth-claude:/home/agent/.claude:z\n' ;;
    codex)  printf 'atelier-auth-codex:/home/agent/.codex:z\n' ;;
    "")     return 1 ;;
    *)      return 1 ;;
  esac
}

container_note() { printf 'meute: %s\n' "$*" >&2; }

podman_cmd() {
  if [[ -n "${MEUTE_PODMAN:-}" ]]; then printf '%s\n' "$MEUTE_PODMAN"
  elif [[ -e /run/.containerenv ]]; then printf 'distrobox-host-exec podman\n'
  else printf 'podman\n'; fi
}

# Is the resolved podman even on PATH? A wrapper that is not is a different
# failure from an image that is not, and the caller must say which.
podman_available() {
  local -a podman; read -ra podman <<< "$(podman_cmd)"
  command -v "${podman[0]}" >/dev/null 2>&1
}

podman_run() {
  local -a podman; read -ra podman <<< "$(podman_cmd)"
  timeout "$PODMAN_TIMEOUT" "${podman[@]}" "$@"
}

# What the tag points at right now: "<digest> <id>", from ONE inspect.
#
# One call, not two, because a tag is a moving name. Asking for the digest
# and then asking for the ID is two observations of something that can change
# between them: the first sees image A and passes the pin, the second
# resolves image B, and B is what runs. A single snapshot cannot disagree
# with itself, so the digest that is checked and the ID that is run are the
# same observation of the same image.
image_pin_on_host() {
  podman_run image inspect --format '{{.Digest}} {{.Id}}' -- "$1" 2>/dev/null
}

# Digest alone, for doctor, which reports on an image rather than running one.
image_digest_on_host() {
  local pin; pin="$(image_pin_on_host "$1")" || return 1
  printf '%s\n' "${pin%% *}"
}

egress_running() {
  [[ "$(podman_run container inspect --format '{{.State.Running}}' -- "$CONTAINER_EGRESS" 2>/dev/null)" == "true" ]]
}

# The proxy's address on the internal network, read at run time.
#
# atelier-internal is created with --disable-dns (Atelier's finding: podman
# ordered the proxy's nameservers non-deterministically, and about one start
# in four lost public DNS), so container names do not resolve there and every
# proxied run has to carry the address as an --add-host.
egress_ip() {
  local ip
  ip="$(podman_run inspect "$CONTAINER_EGRESS" \
          --format "{{(index .NetworkSettings.Networks \"${CONTAINER_NETWORK}\").IPAddress}}" 2>/dev/null)"
  [[ -n "$ip" && "$ip" != "<no value>" ]] || return 1
  printf '%s\n' "$ip"
}

# --------------------------------------------------------------------------
# Fail closed.
#
# Every precondition here is a per-entry condition, so the caller steps the
# entry OVER (eligible() returns 1 and the fire selects the next candidate)
# rather than calling skip(), which ends the fire without advancing the
# cursor and would starve every repo behind this one.
#
# Sets CONTAINER_BLOCKED to the reason, in the voice `eligible()` notes and
# `doctor` prints. On success sets CONTAINER_IMAGE_ID to the immutable ID the
# digest assert resolved, which is what the run must then be given. Returns 0
# when the entry may run in a container.
# --------------------------------------------------------------------------
container_ready() {
  local entry="$1" repo tag digest network pin actual
  { read -r repo; read -r tag; read -r digest; read -r network; } \
    < <(jq -r '.repo, (.image.tag // ""), (.image.digest // ""), (.network // "")' <<< "$entry")
  CONTAINER_BLOCKED=""
  # Cleared on the way in, not only on the way out: a value left over from a
  # repo that verified a moment ago must never be available to one that did
  # not. An identity that outlives what proved it is the defect this whole
  # function exists to prevent, at a different scale.
  CONTAINER_IMAGE_ID=""; CONTAINER_IMAGE_FOR=""

  if ! podman_available; then
    CONTAINER_BLOCKED="${repo}: podman not found (MEUTE_PODMAN=${MEUTE_PODMAN:-unset}), resolved to '$(podman_cmd)'"
    return 1
  fi
  if [[ -z "$tag" || -z "$digest" ]]; then
    CONTAINER_BLOCKED="${repo}: no image pinned (rule 1 requires tag and digest for a container runtime)"
    return 1
  fi
  pin="$(image_pin_on_host "$tag")" || pin=""
  actual="${pin%% *}"
  if [[ -z "$actual" ]]; then
    CONTAINER_BLOCKED="${repo}: image ${tag} is not present on this host"
    return 1
  fi
  # The assert is what makes it safe to run the tag: a local image has no
  # registry to be addressed by `<tag>@<digest>`, so the pin is checked here
  # and the tag is what podman is then given.
  if [[ "$actual" != "$digest" ]]; then
    CONTAINER_BLOCKED="${repo}: image ${tag} is not at the pinned digest (manifest ${digest:0:19}…, host ${actual:0:19}…)"
    return 1
  fi
  # From the same snapshot the digest came from. The tag stays in every
  # message a human reads; podman is handed the ID.
  CONTAINER_IMAGE_ID="${pin##* }"
  if [[ -z "$CONTAINER_IMAGE_ID" || "$CONTAINER_IMAGE_ID" == "$actual" ]]; then
    CONTAINER_BLOCKED="${repo}: image ${tag} has no resolvable image ID"
    CONTAINER_IMAGE_ID=""
    return 1
  fi
  # Bound to what was verified, so a later entry cannot inherit it: the argv
  # refuses unless the entry it is handed is the one this pin was for.
  CONTAINER_IMAGE_FOR="${tag} ${digest}"
  # A tier that takes no network needs neither the proxy nor its address.
  if [[ "$network" == "proxied" ]]; then
    if ! egress_running; then
      CONTAINER_BLOCKED="${repo}: ${CONTAINER_EGRESS} is not running"
      return 1
    fi
    if ! egress_ip >/dev/null; then
      CONTAINER_BLOCKED="${repo}: ${CONTAINER_EGRESS} has no address on ${CONTAINER_NETWORK}"
      return 1
    fi
  fi
  return 0
}

# --------------------------------------------------------------------------
# The flag set (PRP-004 §5, Atelier §4.3), built but not run, so a test can
# assert it field by field without starting anything.
#
#   container_argv <entry-json> <stage> <engine> <workdir> <outdir> -- <argv...>
#
# The engine is a PARAMETER, never read back out of the entry. `--engine`
# makes the engine that actually runs differ from the one the entry names,
# and a credential mount derived here from the entry would then put one
# provider's agent in front of the other's OAuth token -- in a writing
# container, holding danger-full-access over it. The effective engine is
# decided once, in run_entry, and travels down. Nothing in this file reads
# `.engine`; a second derivation is exactly how that defect arrived.
#
# Sets CONTAINER_ARGV. The only host paths that reach the container are the
# two directories named here: the scratch clone at /work and the capture
# directory at /out. The owner's checkout and its .git are never mounted.
# --------------------------------------------------------------------------
container_argv() {
  local entry="$1" stage="$2" engine="$3" workdir="$4" outdir="$5"
  shift 5
  [[ "${1:-}" == "--" ]] && shift
  local network timeout_seconds
  { read -r network; read -r timeout_seconds; } \
    < <(jq -r '(.network // ""), (.timeout_seconds // 1800)' <<< "$entry")
  # container_ready resolved this from the tag it verified; without it there
  # is no proven image to run, and guessing one is the whole risk. Non-empty
  # is not enough -- it must have been verified for THIS entry's pin.
  local image="${CONTAINER_IMAGE_ID:-}" want
  want="$(jq -r '(.image.tag // "") + " " + (.image.digest // "")' <<< "$entry")"
  if [[ -z "$image" ]]; then
    container_note "no verified image ID; call container_ready first"
    return 1
  fi
  if [[ "${CONTAINER_IMAGE_FOR:-}" != "$want" ]]; then
    container_note "the verified image is for ${CONTAINER_IMAGE_FOR:-nothing}, not ${want}"
    return 1
  fi

  # shellcheck disable=SC2054  # the commas are inside podman's own --userns
  # value (uid=1000,gid=1000), not argv separators.
  CONTAINER_ARGV=(
    run --rm
    --userns=keep-id:uid=1000,gid=1000
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --init
    --pids-limit=2048
    --timeout "$timeout_seconds"
    --stop-timeout "$CONTAINER_STOP_TIMEOUT"
    # An image that vanished between the assert and now is an error. Without
    # this podman would go and fetch something by that name from a registry.
    --pull=never
    # The image's own filesystem is not the agent's to change: it is pinned
    # by digest, so anything written there would be lost at --rm anyway, and
    # a writable root is one more place a compromised run could hide. /tmp is
    # the one thing both CLIs need to write outside their mounts. Measured:
    # a real `claude -p` and a real `codex exec` both complete under this
    # (PRP-004 §5 item 4, answered in Phase 2b).
    --read-only
    --tmpfs /tmp
  )
  # The preflight reads a credential and nothing else, so it takes neither
  # tree -- §4.4 gives it no mounts at all.
  if [[ -n "$workdir" ]]; then
    # A tier that does not write code has no business writing the branch it
    # was given to read. Measured: git status, diff <base>...HEAD, log and
    # show all work on a read-only mount, provided it is still relabelled.
    # `.writes_code // true` would be wrong here: jq's alternative operator
    # treats false as empty, so a reading tier would have come back "true"
    # and been given a writable branch. Ask for the value itself.
    local work_flags="Z"
    [[ "$(jq -r '.writes_code' <<< "$entry")" != "false" ]] || work_flags="ro,Z"
    CONTAINER_ARGV+=( --volume "${workdir}:/work:${work_flags}" --workdir /work )
  fi
  # /out is always writable: it is where the runner reads the engine's
  # capture back from, and it is NOT /work, so commit_worktree's `git add -A`
  # cannot sweep it into the branch.
  [[ -z "$outdir" ]] || CONTAINER_ARGV+=( --volume "${outdir}:/out:Z" )
  local need auth
  need="$(container_stage_credential "$stage")" \
    || { container_note "unknown stage '${stage}'; refusing to guess what it may hold"; return 1; }
  if [[ "$need" == "engine" ]]; then
    # The credential is chosen from the engine parameter, and the command
    # comes from the caller's argv. Two callers passing two different things
    # is the drift that put one provider's agent in front of the other's
    # token, so the two are bound -- by the CALLER'S declaration, never by
    # looking at the command. `claude`, `/usr/local/bin/claude` and `env
    # FOO=1 claude` are one engine and only one of them looks like it; a
    # check that pattern-matched argv[0] would pass for the other two while
    # the property was violated.
    #
    # An absent claim is a REFUSAL, not a pass. A guard that is skipped
    # when its input is missing stops working the moment a caller arrives
    # without one, and nothing announces that -- which is how this same
    # mistake arrived three times in this branch. Every dispatch that
    # mounts a credential declares what it is; stages that legitimately
    # hold none take the other branch, where no claim and no credential are
    # correct together.
    if [[ -z "${ENGINE_ARGV_ENGINE:-}" ]]; then
      container_note "stage ${stage} mounts a credential but the dispatch declared no engine; refusing"
      return 1
    fi
    if [[ "$ENGINE_ARGV_ENGINE" != "$engine" ]]; then
      container_note "the command was built for ${ENGINE_ARGV_ENGINE} but the credential is for ${engine:-none}; refusing to run one engine on the other's token"
      return 1
    fi
    # Fail closed: a stage that runs an engine and cannot be given that
    # engine's credential must be refused here, with a reason. Mounting
    # nothing and carrying on puts the failure inside the container, as an
    # auth error that names neither the stage nor the engine.
    auth="$(container_auth_mount "$engine")" \
      || { container_note "stage ${stage} runs an engine, and '${engine:-<none>}' has no credential volume"; return 1; }
    CONTAINER_ARGV+=( --volume "$auth" )
  fi
  local -a profile=()
  container_network_argv "$stage" "$network" || return 1
  profile=( "${CONTAINER_NETWORK_ARGV[@]}" )
  CONTAINER_ARGV+=( "${profile[@]}" "$image" "$@" )
}

# The stage's network profile (§4.4). `preflight` reads a credential and
# nothing else, so it takes no network whatever the tier declares -- that is
# the one stage whose profile is not the tier's.
container_network_argv() {
  local stage="$1" network="$2"
  CONTAINER_NETWORK_ARGV=()
  if [[ "$stage" == "preflight" || "$network" != "proxied" ]]; then
    CONTAINER_NETWORK_ARGV=( --network=none )
    return 0
  fi
  local ip
  ip="$(egress_ip)" || { container_note "no ${CONTAINER_EGRESS} address on ${CONTAINER_NETWORK}"; return 1; }
  # Both schemes, both spellings. https and plain http are separate variables
  # -- without the http pair a git http remote or a package mirror fails with
  # curl rc 6 rather than going through the allow-list, which is fail-closed
  # but reads like a broken network. Both cases because clients disagree:
  # measured on agent-base:g691e067, curl honours HTTPS_PROXY and https_proxy
  # alike, but of the http pair it reads ONLY the lowercase one -- it refuses
  # uppercase HTTP_PROXY by design, because a CGI request header named
  # `Proxy:` arrives in the environment under exactly that name. Other
  # clients read the spelling curl won't, so all four are set.
  # NO_PROXY is emptied so nothing decides for itself that a host is local
  # and skips the allow-list.
  CONTAINER_NETWORK_ARGV=(
    "--network=${CONTAINER_NETWORK}"
    --add-host "${CONTAINER_EGRESS}:${ip}"
    --env "HTTPS_PROXY=${CONTAINER_PROXY_URL}"
    --env "https_proxy=${CONTAINER_PROXY_URL}"
    --env "HTTP_PROXY=${CONTAINER_PROXY_URL}"
    --env "http_proxy=${CONTAINER_PROXY_URL}"
    --env "NO_PROXY="
  )
}

# How long the runner waits on podman itself.
#
# Deliberately NOT PODMAN_TIMEOUT: that bounds an inspect, and this bounds a
# run that is supposed to take the whole timeout_seconds. podman's own
# --timeout bounds the CONTAINER; it says nothing about a client or a
# control-plane call that stalls, and under a timer a stalled client holds
# the lock and starves every repo behind it. So the outer bound is always
# slack above the inner one -- the container's own timeout, its stop grace,
# and a minute for podman to do its work -- and can only fire when podman
# itself is stuck, never to pre-empt a run that is merely slow.
container_outer_bound() {
  local seconds="$1"
  [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=1800
  printf '%s\n' "$(( seconds + CONTAINER_STOP_TIMEOUT + 60 ))"
}

# Assemble and execute. Writes nothing to stdout of its own -- the command's
# output is the caller's to redirect, exactly as the host path's is -- and
# returns the command's exit status.
container_run() {
  local entry="$1"
  container_argv "$@" || return 1
  local -a podman; read -ra podman <<< "$(podman_cmd)"
  local seconds; seconds="$(jq -r '.timeout_seconds // ""' <<< "$entry")"
  timeout --kill-after="$CONTAINER_STOP_TIMEOUT" "$(container_outer_bound "$seconds")" \
    "${podman[@]}" "${CONTAINER_ARGV[@]}"
}
