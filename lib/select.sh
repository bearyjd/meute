# Queue selection, sourced by bin/run.sh: the cursor, the per-candidate gates
# (share, cap, pool, container readiness) and the round-robin walk. Expects
# from the caller: SLOT, PLAN_MODE, FORCED, ONCE, ONCE_DONE, FORCE_REPO, FORCE_TASK,
# ENGINE_OVERRIDE, RUNTIME_OVERRIDE, QUOTA_FLOOR, TIER3_CAP, CURSOR_FILE,
# PLAN_DONE_FILE, MEUTE_ROOT, and note/skip (outcome.sh), refuse_entry,
# state_get, kv_get/kv_set (state.sh), community_allowed, tier3_in_flight,
# hold_active, hold_until_human, HOLD_UNTIL/HOLD_REASON (fleet.sh) and
# container_ready (container.sh).

# hold_gate: skip the fire as code=hold while a hold is in force. Called before
# the lock and, after a --wait-lock wait, again once the lock is taken.
hold_gate() {
  hold_active || return 0
  skip hold "paused until $(hold_until_human "$HOLD_UNTIL")${HOLD_REASON:+ — ${HOLD_REASON}}"
}


# A staged plan rotates on its own cursor. Sharing one would leave the
# manifest cursor pointing at a plan key once the plan retires -- a key no
# manifest entry has -- and restart the manifest rotation at 0. A narrowed
# fire (MEUTE_ONLY_REPOS) rotates on its own too (lib/cursor.sh).
source "${MEUTE_ROOT}/lib/cursor.sh"
cursor_key() {
  local mode=manifest; (( PLAN_MODE )) && mode=plan
  cursor_name "$SLOT" "$mode" "${MEUTE_ONLY_REPOS:-}"
}

# Would this entry be dispatched into a container, and is there a pin to
# assert? A container entry whose image drifted, or whose egress proxy is
# down, is stepped OVER -- not skipped: skip() ends the fire without
# advancing the cursor, so every repo behind this one would starve on a
# condition that has nothing to do with them. The fire runs the next
# candidate instead, and doctor names what is wrong (PRP-004 Phase 2).
#
# `--runtime container` on a repo with no `image:` at all is deliberately NOT
# claimed here: that is rule 5, which fails closed in run_entry with the
# validator's own message and a state/log line. Everything that could
# actually reach a container -- a repo whose manifest says so, or a CLI
# override on a repo that has a pin -- is asserted first.
container_entry_needs_pin() {
  local entry="$1"
  # `--runtime host` asks for the host, so no image would be run and there is
  # nothing to assert -- run_entry refuses that downgrade on its own terms.
  [[ "$RUNTIME_OVERRIDE" != "host" ]] || return 1
  [[ "$(jq -r '.runtime // ""' <<< "$entry")" == "container" ]] && return 0
  [[ "$RUNTIME_OVERRIDE" == "container" && -n "$(jq -r '.image.tag // ""' <<< "$entry")" ]]
}

eligible() {
  local entry="$1" key kind path tier engine stage_entry
  { read -r key; read -r kind; read -r path; read -r tier; read -r engine; read -r stage_entry; } \
    < <(jq -r '.key, .kind, .path, .tier, .engine, .stage_entry' <<< "$entry")

  if [[ ! -d "$path/.git" && ! -f "$path/.git" ]]; then
    note "skipping ${key}: not a git repository at $path"
    # A staged path that is no longer a repository (an agent worktree torn
    # down after staging) can never be attempted; unmarked, it would hold the
    # plan open forever. Recorded on dry runs too, like the retirement it
    # feeds -- a missing repo is a fact, not an effect of running.
    (( PLAN_MODE )) && kv_set "$PLAN_DONE_FILE" "$key" missing
    return 1
  fi
  # A forced selection is an explicit human decision about the QUEUE: it
  # skips the share, cap and quota gates below. It does not skip the
  # boundary's own readiness -- a drifted pin is not a gate the operator is
  # overriding, it is an image they did not choose and cannot see. Phase 1's
  # abort catches this today; Phase 2b removes that abort, and then a forced
  # run would be the one dispatch with no digest assert in front of it.
  if container_entry_needs_pin "$entry" && ! container_ready "$entry"; then
    # The asymmetry is deliberate. An unforced entry that cannot run is
    # queue rotation: the fire moves on and the entry that DOES run writes
    # the fire's one line. A forced one is a human's explicit request that
    # failed on a precondition they can remediate -- build the image, start
    # the proxy, bump the pin -- so it must be logged, and must stay
    # retryable. Not abort_entry: that also advances the cursor and marks a
    # staged plan item done, which would retire the very item they asked for
    # over a condition they are about to fix.
    (( FORCED )) && refuse_entry "$entry" "$CONTAINER_BLOCKED"
    note "skipping ${key}: ${CONTAINER_BLOCKED}"
    return 1
  fi
  # That includes re-running a staged item already attempted -- unless --once
  # (P1.4): then another fire finished it since the caller looked, and main
  # ends this one as already-done instead of falling back to the manifest.
  if (( FORCED )); then
    if (( ONCE && PLAN_MODE )) && [[ -n "$(kv_get "$PLAN_DONE_FILE" "$key")" ]]; then
      note "skipping ${key}: staged plan item already attempted (--once)"
      ONCE_DONE=1; return 1
    fi
    return 0
  fi

  if (( PLAN_MODE )) && [[ -n "$(kv_get "$PLAN_DONE_FILE" "$key")" ]]; then
    note "skipping ${key}: staged plan item already attempted"
    return 1
  fi
  if [[ "$kind" == "community" ]] && ! community_allowed; then
    note "skipping ${key}: community share exhausted this week"
    return 1
  fi
  # The cap gates NEW builds. A stage entry (PRP-004 §4.3) works a branch that
  # is itself one of the counted ones; at cap -- the designed steady state --
  # a resolve must still be able to run, or nothing ever frees a slot.
  if [[ "$tier" == "tier3" && "$stage_entry" != "true" ]]; then
    local in_flight; in_flight="$(tier3_in_flight)"
    if (( in_flight >= TIER3_CAP )); then
      note "skipping ${key}: ${in_flight} tier-3 drafts already in flight (cap ${TIER3_CAP})"
      return 1
    fi
  fi
  # A publish stage runs no engine, so there is no pool to ask about.
  [[ -n "$engine" ]] || return 0
  # Gate 2 of 2: the subscription pool the human shares -- per engine, so a
  # Codex entry is gated by a Codex source and never by the Claude status-line
  # snapshot. Checked per candidate rather than after selection: a fleet that
  # mixes engines must step over the one whose pool is spent or unmeasured,
  # not pin the rotation on it.
  engine="${ENGINE_OVERRIDE:-$engine}"
  quota_for_engine "$engine"
  if [[ "$QUOTA_PROBE" == "fail" ]]; then
    note "skipping ${key}: ${engine} quota unavailable"
    return 1
  fi
  if (( ${QUOTA_PROBE%% *} < QUOTA_FLOOR )); then
    note "skipping ${key}: ${engine} quota ${QUOTA_PROBE%% *}% below floor ${QUOTA_FLOOR}%"
    return 1
  fi
  return 0
}

# One quota.sh subprocess per engine per fire, however long the queue: the
# reading is cached so every candidate can be asked about. Sets QUOTA_PROBE
# to "<percent> <source>", or "fail" when no source for that engine answered.
declare -A QUOTA_BY_ENGINE=()
quota_for_engine() {
  local engine="$1"
  if [[ -z "${QUOTA_BY_ENGINE[$engine]+set}" ]]; then
    QUOTA_BY_ENGINE[$engine]="$(timeout --kill-after=5 35 "${MEUTE_ROOT}/bin/quota.sh" --engine "$engine" --with-source 9>&-)" \
      || QUOTA_BY_ENGINE[$engine]="fail"
  fi
  QUOTA_PROBE="${QUOTA_BY_ENGINE[$engine]}"
}

# Nothing was eligible. When a pool was the reason for any candidate, the
# reason names each such engine with its verdict, and quota=/engine= carry
# the readings in the same order -- so a wedged fleet reads as "codex quota
# probe failed", not as an inexplicable empty round.
skip_nothing_eligible() {
  local engine probe verdicts=() engines=() quotas=()
  for engine in $(printf '%s\n' "${!QUOTA_BY_ENGINE[@]}" | LC_ALL=C sort); do
    probe="${QUOTA_BY_ENGINE[$engine]}"
    if [[ "$probe" == "fail" ]]; then
      verdicts+=( "${engine} quota probe failed" ); quotas+=( "fail" )
    elif (( ${probe%% *} < QUOTA_FLOOR )); then
      verdicts+=( "${engine} quota ${probe%% *}% below floor ${QUOTA_FLOOR}%" )
      quotas+=( "${probe%% *}:${probe#* }" )
    else
      continue
    fi
    engines+=( "$engine" )
  done
  (( ${#verdicts[@]} )) || skip nothing-eligible "no eligible entry for slot ${SLOT}"
  local why; why="$(printf '%s; ' "${verdicts[@]}")"
  skip nothing-eligible "no eligible entry for slot ${SLOT} (${why%; })" \
    "quota=$(IFS=,; printf '%s' "${quotas[*]}")" "engine=$(IFS=,; printf '%s' "${engines[*]}")"
}

# A forced --repo/--task names one entry; nothing else is a candidate.
# MEUTE_ONLY_REPOS (newline-separated names, set by `meute drain --repo`)
# narrows an unforced queue instead: the cursor and every gate still apply.
load_queue() {
  local queue_file="$1"
  if (( FORCED )); then
    jq -c --arg r "$FORCE_REPO" --arg t "$FORCE_TASK" \
       'select(($r == "" or .repo == $r) and ($t == "" or .task == $t))' \
       "$queue_file" > "${queue_file}.f"
    mv "${queue_file}.f" "$queue_file"
  elif [[ -n "${MEUTE_ONLY_REPOS:-}" ]]; then
    jq -c --arg o "$MEUTE_ONLY_REPOS" '($o | split("\n")) as $l | select(.repo as $r | any($l[]; . == $r))' \
       "$queue_file" > "${queue_file}.f"
    mv "${queue_file}.f" "$queue_file"
  fi
  mapfile -t QUEUE < "$queue_file"
}

# Round-robin: resume at the entry after the last one executed for this slot,
# wrap around, and take the first eligible candidate into SELECTED. A global
# rather than stdout so the eligibility checks run in this shell, not a
# subshell whose caches would be thrown away.
select_entry() {
  local cursor start=0 i idx
  cursor="$(state_get "$(cursor_key)")"
  local total=${#QUEUE[@]}
  SELECTED=""
  if [[ -n "$cursor" ]]; then
    for (( i = 0; i < total; i++ )); do
      if [[ "$(jq -r '.key' <<< "${QUEUE[i]}")" == "$cursor" ]]; then start=$(( i + 1 )); break; fi
    done
  fi
  for (( i = 0; i < total; i++ )); do
    idx=$(( (start + i) % total ))
    if eligible "${QUEUE[idx]}"; then SELECTED="${QUEUE[idx]}"; return 0; fi
  done
  return 1
}
