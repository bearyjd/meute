#!/usr/bin/env bash
#
# Fleet status: `meute status`. Sourced by bin/meute.
#
# Quota, hold, what each slot runs next, this week's activity. next_for_slot
# is read-only unlike the runner it mirrors, and `doctor` reuses it.
#
# Expects from the caller: MEUTE_ROOT, MANIFEST_PY, MANIFEST, LOG_FILE,
# CURSOR_FILE, PLAN_QUEUE_FILE, PLAN_DONE_FILE, THIS_WEEK, die, cmd_reports,
# plus lib/state.sh and lib/fleet.sh.

cmd_status() {
  fleet_load_policy || die "could not read policy from ${MANIFEST}"
  local probe quota source codex_probe
  probe="$("${MEUTE_ROOT}/bin/quota.sh" --engine claude --with-source 2>/dev/null || echo '? ?')"
  quota="${probe%% *}"; source="${probe#* }"

  local gate="ok"
  [[ "$quota" != "?" ]] && (( quota < QUOTA_FLOOR )) && gate="BELOW FLOOR ${QUOTA_FLOOR}%"
  # The stub is not a reading. Say so on the line the eye lands on, rather than
  # let "quota 100% · ok" stand in for a gate that measures nothing.
  [[ "$source" == "stub" ]] && gate="UNMEASURED (stub) — run: meute install-statusline"
  # A hold overrides the gate, so it is the first thing said. A paused fleet
  # reading "quota 100% · ok" is how you conclude it is about to run.
  if hold_active; then
    printf 'PAUSED until %s%s\n' "$(hold_until_human "$HOLD_UNTIL")" "${HOLD_REASON:+ — ${HOLD_REASON}}"
    printf '  every slot declines until then; lift it with: meute resume\n'
  fi
  printf 'Claude quota %s%%  ·  %s\n' "$quota" "$gate"
  if codex_probe="$("${MEUTE_ROOT}/bin/quota.sh" --engine codex --with-source 2>/dev/null)"; then
    printf 'Codex quota %s%%  ·  configured (%s)\n' "${codex_probe%% *}" "${codex_probe#* }"
  else
    printf 'Codex quota unavailable  ·  configure MEUTE_CODEX_QUOTA_CMD before Codex jobs can run\n'
  fi

  # A staged plan is what the next fires will actually run, ahead of the
  # manifest, so the "next" lines below are meaningless without saying so.
  [[ -f "$PLAN_QUEUE_FILE" ]] && printf '  staged plan: %s\n' "$(plan_progress)"
  local slot
  for slot in daily weekly; do
    printf '  next %-7s %s\n' "$slot" "$(next_for_slot "$slot")"
  done

  local total community cost
  total="$(week_runs)"; community="$(week_runs community)"
  cost="$(awk -F'\t' -v wk="week=${THIS_WEEK}" '
      index($0, wk) == 0 { next }
      { for (i = 1; i <= NF; i++) if ($i ~ /^cost=/) { split($i, a, "="); if (a[2] + 0 > 0) s += a[2] } }
      END { printf "%.2f", s + 0 }' "$LOG_FILE" 2>/dev/null || echo 0)"
  local ceiling=""
  fleet_wire_self_budget >/dev/null 2>&1 || true
  [[ -n "${MEUTE_WEEKLY_COST_USD:-}" ]] && ceiling=" of \$${MEUTE_WEEKLY_COST_USD}"
  [[ -n "${MEUTE_WEEKLY_RUNS:-}" ]] && ceiling=" (ceiling ${MEUTE_WEEKLY_RUNS} runs)"
  printf '  week %s   %s runs (%s personal · %s community) · $%s%s\n' \
    "$THIS_WEEK" "$total" "$(( total - community ))" "$community" "$cost" "$ceiling"

  local in_flight=0
  if fleet_load_scope 2>/dev/null; then in_flight="$(tier3_in_flight 2>/dev/null || echo 0)"; fi
  printf '  tier-3 in flight  %s of %s\n' "${in_flight:-0}" "${TIER3_CAP}"

  local new_count; new_count="$(cmd_reports --new 2>/dev/null | grep -c '^NEW' || true)"
  printf '  reports unread    %s\n' "${new_count:-0}"
}

# What the runner would pick next, without running anything: a staged plan
# first, on its own cursor and minus the items already attempted or whose path
# is no longer a repository, then the manifest round-robin. Read-only, unlike
# the runner: it neither retires a finished plan nor marks a vanished repo.
next_for_slot() {
  local slot="$1" key staged
  if [[ -f "$PLAN_QUEUE_FILE" ]]; then
    # The runner dies on a plan it cannot validate; nothing runs until the
    # file is fixed or removed, so no manifest entry is "next" either.
    staged="$(python3 "$MANIFEST_PY" plan-queue "$MANIFEST" "$PLAN_QUEUE_FILE" "$slot" 2>/dev/null)" \
      || { printf -- '- (staged plan invalid; the runner refuses to run)\n'; return 0; }
    key="$(next_in_queue "plan-cursor.${slot}" plan <<< "$staged")"
    [[ -z "$key" ]] || { printf '%s\n' "$key"; return 0; }
  fi
  key="$(next_in_queue "cursor.${slot}" manifest \
           < <(python3 "$MANIFEST_PY" queue "$MANIFEST" "$slot" 2>/dev/null || true))"
  printf '%s\n' "${key:--}"
}

# First key after the cursor in the queue on stdin, wrapping, skipping what
# the runner would (bin/run.sh eligible): attempted or vanished staged items,
# and any entry whose engine's pool is unmeasured or below the floor. Blank
# when none.
next_in_queue() {
  local cursor_name="$1" mode="$2" cursor start=0 i idx total key path engine
  local -a queue
  local -A quota=()
  mapfile -t queue
  total=${#queue[@]}
  (( total )) || return 0
  cursor="$(kv_get "$CURSOR_FILE" "$cursor_name")"
  if [[ -n "$cursor" ]]; then
    for (( i = 0; i < total; i++ )); do
      if [[ "$(jq -r '.key' <<< "${queue[i]}")" == "$cursor" ]]; then start=$(( i + 1 )); break; fi
    done
  fi
  for (( i = 0; i < total; i++ )); do
    idx=$(( (start + i) % total ))
    { read -r key; read -r path; read -r engine; } < <(jq -r '.key, .path, .engine' <<< "${queue[idx]}")
    if [[ "$mode" == plan ]]; then
      [[ -z "$(kv_get "$PLAN_DONE_FILE" "$key")" ]] || continue
      [[ -d "$path/.git" || -f "$path/.git" ]] || continue
    fi
    # A publish stage (PRP-004) runs no engine: nothing to probe, so it is
    # next -- and "" is not a key an associative array will take.
    if [[ -z "$engine" ]]; then printf '%s\n' "$key"; return 0; fi
    # Once per engine per walk, as the runner probes once per engine per fire.
    if [[ -z "${quota[$engine]+set}" ]]; then
      quota[$engine]="$("${MEUTE_ROOT}/bin/quota.sh" --engine "$engine" 2>/dev/null)" || quota[$engine]="fail"
    fi
    [[ "${quota[$engine]}" != "fail" ]] || continue
    (( ${quota[$engine]} >= ${QUOTA_FLOOR:-0} )) || continue
    printf '%s\n' "$key"
    return 0
  done
}

# "<attempted> of <total> attempted" for the staged plan, across both slots
# -- or why the runner will refuse it, which reads nothing like an empty plan.
plan_progress() {
  local key total=0 attempted=0 staged
  staged="$(python3 "$MANIFEST_PY" plan-queue "$MANIFEST" "$PLAN_QUEUE_FILE" all 2>&1)" \
    || { printf 'invalid — %s\n' "$(head -n1 <<< "$staged" | sed 's|^meute/manifest: ||')"; return 0; }
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    total=$(( total + 1 ))
    [[ -z "$(kv_get "$PLAN_DONE_FILE" "$key")" ]] || attempted=$(( attempted + 1 ))
  done < <(jq -r '.key' <<< "$staged")
  printf '%s of %s attempted\n' "$attempted" "$total"
}
