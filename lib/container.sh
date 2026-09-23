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

# The digest podman holds for a tag, or non-zero when it has no such image.
image_digest_on_host() {
  podman_run image inspect --format '{{.Digest}}' -- "$1" 2>/dev/null
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
# `doctor` prints. Returns 0 when the entry may run in a container.
# --------------------------------------------------------------------------
container_ready() {
  local entry="$1" repo tag digest network actual
  { read -r repo; read -r tag; read -r digest; read -r network; } \
    < <(jq -r '.repo, (.image.tag // ""), (.image.digest // ""), (.network // "")' <<< "$entry")
  CONTAINER_BLOCKED=""

  if ! podman_available; then
    CONTAINER_BLOCKED="${repo}: podman not found (MEUTE_PODMAN=${MEUTE_PODMAN:-unset}), resolved to '$(podman_cmd)'"
    return 1
  fi
  if [[ -z "$tag" || -z "$digest" ]]; then
    CONTAINER_BLOCKED="${repo}: no image pinned (rule 1 requires tag and digest for a container runtime)"
    return 1
  fi
  actual="$(image_digest_on_host "$tag")" || actual=""
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
#   container_argv <entry-json> <stage> <workdir> <outdir> -- <argv...>
#
# Sets CONTAINER_ARGV. The only host paths that reach the container are the
# two directories named here: the scratch clone at /work and the capture
# directory at /out. The owner's checkout and its .git are never mounted.
# --------------------------------------------------------------------------
container_argv() {
  local entry="$1" stage="$2" workdir="$3" outdir="$4"
  shift 4
  [[ "${1:-}" == "--" ]] && shift
  local tag network timeout_seconds
  { read -r tag; read -r network; read -r timeout_seconds; } \
    < <(jq -r '(.image.tag // ""), (.network // ""), (.timeout_seconds // 1800)' <<< "$entry")

  # shellcheck disable=SC2054  # the commas are inside podman's own --userns
  # value (uid=1000,gid=1000), not argv separators.
  CONTAINER_ARGV=(
    run --rm
    --userns=keep-id:uid=1000,gid=1000
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --init
    --pids-limit=2048
    --volume "${workdir}:/work:Z"
    --volume "${outdir}:/out:Z"
    --workdir /work
    --timeout "$timeout_seconds"
    --stop-timeout "$CONTAINER_STOP_TIMEOUT"
  )
  local -a profile=()
  container_network_argv "$stage" "$network" || return 1
  profile=( "${CONTAINER_NETWORK_ARGV[@]}" )
  CONTAINER_ARGV+=( "${profile[@]}" "$tag" "$@" )
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
  # Both spellings, because HTTP clients disagree about which they read and
  # setting both costs nothing. (Measured on agent-base:g691e067: curl there
  # honours either, so the uppercase-only claim in Atelier's note does not
  # reproduce on this image -- but a client that reads only one spelling is
  # the kind of thing that surfaces as an unexplained timeout in an
  # unattended run, so neither is left out.) NO_PROXY is emptied so nothing
  # decides for itself that a host is local and skips the allow-list.
  CONTAINER_NETWORK_ARGV=(
    "--network=${CONTAINER_NETWORK}"
    --add-host "${CONTAINER_EGRESS}:${ip}"
    --env "HTTPS_PROXY=${CONTAINER_PROXY_URL}"
    --env "https_proxy=${CONTAINER_PROXY_URL}"
    --env "NO_PROXY="
  )
}

# Assemble and execute. Writes nothing to stdout of its own -- the command's
# output is the caller's to redirect, exactly as the host path's is -- and
# returns the command's exit status.
container_run() {
  container_argv "$@" || return 1
  local -a podman; read -ra podman <<< "$(podman_cmd)"
  "${podman[@]}" "${CONTAINER_ARGV[@]}"
}
