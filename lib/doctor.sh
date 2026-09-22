#!/usr/bin/env bash
#
# Deployability: `meute doctor`. Sourced by bin/meute.
#
# Read-only apart from creating state/, reports/ and .worktrees/ so their
# writability can be reported. Every probe goes through the environment
# the scheduler will really provide, not the one you are typing in.
#
# Expects from the caller: MEUTE_ROOT, MANIFEST_PY, MANIFEST, SCRUBBED,
# AUTH_MODE, die, podman_cmd, podman_available, image_digest_on_host,
# egress_running, plus lib/fleet.sh,
# lib/preflight.sh, lib/status.sh (next_for_slot) and lib/timers.sh
# (unit_path_line, timer_state, linger_state).

# --------------------------------------------------------------------------
# Is this fleet actually deployable? Everything here is checked against the
# environment cron will really provide, not the one you are typing in.
# --------------------------------------------------------------------------
readonly CRON_PATH_DEFAULT="/usr/bin:/bin"
DOCTOR_ERRORS=0
DOCTOR_WARNINGS=0

d_ok()   { printf '    \033[32mok\033[0m   %s\n' "$*"; }
d_warn() { printf '    \033[33mwarn\033[0m %s\n' "$*"; DOCTOR_WARNINGS=$(( DOCTOR_WARNINGS + 1 )); }
d_err()  { printf '    \033[31mFAIL\033[0m %s\n' "$*"; DOCTOR_ERRORS=$(( DOCTOR_ERRORS + 1 )); }

# Sorted, de-duplicated, colon-joined, blanks dropped. Always exits 0: `grep -v`
# exits 1 when it selects zero lines, which is exactly what "nothing missing"
# looks like -- and a plain (non-`local`) assignment takes on that as its own
# exit status, which under `set -e` used to kill `doctor` with no message on
# the one machine state that should be the easiest to report.
dedup_dirs() {
  printf '%s\n' "$@" | sort -u | grep -v '^$' | paste -sd: - || true
}

cmd_doctor() {
  local missing_from_cron=()
  # Checking every binary against cron's PATH is only honest on a machine that
  # actually schedules through cron. On a systemd-only box it produced a
  # warning pointing at "the cron block below" — a block that branch of this
  # function never prints, since it goes to the systemd path instead. Check
  # against whatever `install-timers` would actually put in the unit.
  local has_cron=0; command -v crontab >/dev/null 2>&1 && has_cron=1
  local check_path="$CRON_PATH_DEFAULT"
  (( has_cron )) || check_path="$(unit_path_line)"

  printf '\n  binaries\n'
  local bin path
  for bin in git jq python3 flock timeout; do
    path="$(command -v "$bin" 2>/dev/null || true)"
    if [[ -z "$path" ]]; then d_err "$bin not found — required"; continue; fi
    if env -i PATH="$check_path" sh -c "command -v $bin" >/dev/null 2>&1; then
      d_ok "$(printf '%-8s %s' "$bin" "$path")"
    elif (( has_cron )); then
      d_warn "$(printf '%-8s %s  (outside cron PATH)' "$bin" "$path")"
      missing_from_cron+=( "$(dirname "$path")" )
    else
      d_warn "$(printf "%-8s %s  (outside the systemd timer's PATH — re-run install-timers)" "$bin" "$path")"
    fi
  done
  for bin in claude codex gh; do
    path="$(command -v "$bin" 2>/dev/null || true)"
    if [[ -z "$path" ]]; then
      [[ "$bin" == "gh" ]] && d_warn "gh not found — the community track needs it" \
                           || d_warn "$bin not found — that engine is unavailable"
      continue
    fi
    if env -i PATH="$check_path" sh -c "command -v $bin" >/dev/null 2>&1; then
      d_ok "$(printf '%-8s %s' "$bin" "$path")"
    elif (( has_cron )); then
      d_warn "$(printf '%-8s %s  ← NOT on cron PATH; the cron block below fixes this' "$bin" "$path")"
      missing_from_cron+=( "$(dirname "$path")" )
    else
      d_warn "$(printf "%-8s %s  ← NOT on the systemd timer's PATH — re-run install-timers" "$bin" "$path")"
    fi
  done

  printf '\n  auth (probed through the same scrubbed environment the runner uses)\n'
  scrub_env >/dev/null 2>&1
  if command -v claude >/dev/null; then
    if preflight_claude 2>/dev/null; then d_ok "claude   ${AUTH_MODE}"
    else d_err "claude   not on a subscription — run: claude auth login"; fi
  fi
  if command -v codex >/dev/null; then
    if preflight_codex 2>/dev/null; then d_ok "codex    ${AUTH_MODE}"
    else d_warn "codex    not signed in — run: codex login  (only needed for --engine codex)"; fi
  fi
  [[ -n "${SCRUBBED:-}" ]] && d_warn "API keys present and scrubbed: ${SCRUBBED}"

  printf '\n  manifest\n'
  if python3 "$MANIFEST_PY" validate "$MANIFEST" >/dev/null 2>&1; then
    d_ok "$(basename "$MANIFEST") is valid"
    fleet_load_policy >/dev/null 2>&1 || true
    local repos community
    repos="$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])) or {}; print(len(d.get('repos') or []))" "$MANIFEST")"
    community="$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])) or {}; print(len(d.get('community') or []))" "$MANIFEST")"
    if (( repos == 0 && community == 0 )); then
      d_warn "no projects configured — the fleet is inert until you fill in repos.yaml"
    else
      d_ok "${repos} repo(s), ${community} community project(s)"
      local slot
      for slot in daily weekly; do
        d_ok "$(printf '%-7s queue: %s item(s), next: %s' "$slot" \
          "$(python3 "$MANIFEST_PY" queue "$MANIFEST" "$slot" 2>/dev/null | wc -l)" "$(next_for_slot "$slot")")"
      done
      # PRP-004: a state/stages row whose ticket is gone from both sources
      # is skipped by the queue with a line on stderr nobody reads under the
      # timer. Here it reaches the owner, who can delete the row.
      local orphans
      orphans="$(python3 "$MANIFEST_PY" list-stages "$MANIFEST" 2>/dev/null \
                   | jq -r 'select(.orphan) | .key' 2>/dev/null | paste -sd, - || true)"
      [[ -z "$orphans" ]] \
        || d_warn "state/stages: $(tr ',' '\n' <<< "$orphans" | wc -l) row(s) name no ticket: ${orphans//,/, }"
    fi
  else
    d_err "$(basename "$MANIFEST") failed validation — run: ./bin/run.sh --validate"
  fi

  doctor_containers

  printf '\n  quota gates\n'
  # doctor must not die on a broken manifest — it exists to report one.
  fleet_load_policy 2>/dev/null || true

  # Gate 1: meute's own ceiling. Optional, but without it nothing bounds how
  # much of the week the fleet may take even when the pool has room.
  local left
  if fleet_wire_self_budget; then
    if left="$(fleet_self_budget_remaining 2>/dev/null)"; then
      d_ok "self-budget: ${left}% of meute's own weekly ceiling remaining"
      d_ok "ceiling: ${MEUTE_WEEKLY_COST_USD:+\$${MEUTE_WEEKLY_COST_USD}}${MEUTE_WEEKLY_RUNS:+${MEUTE_WEEKLY_RUNS} runs}/week, from the manifest"
    else
      d_err "self-budget: contrib/quota-self-budget.sh failed — the runner will decline every slot"
    fi
  else
    d_warn "self-budget: no ceiling declared — set policy.weekly_cost_usd in the manifest"
  fi

  # Gate 2: the subscription pool itself. This is the one the design is for.
  local probe
  if probe="$("${MEUTE_ROOT}/bin/quota.sh" --engine claude --with-source 2>/dev/null)"; then
    case "${probe#* }" in
      stub)
        d_warn "subscription (Claude): ${probe%% *}% from the stub — this gate measures NOTHING yet"
        d_warn "run: meute install-statusline   (snapshots the real 5h/7d windows)"
        ;;
      quota-subscription.sh)
        local age
        age="$(( $(date +%s) - $(jq -r '.captured_at // 0' "${MEUTE_ROOT}/state/rate-limits.json" 2>/dev/null || echo 0) ))"
        d_ok "subscription (Claude): ${probe%% *}% of the scarcer pool remaining (5h/7d windows, snapshot $(( age / 60 ))m old)"
        ;;
      *)
        d_ok "subscription (Claude): ${probe%% *}% remaining, from ${probe#* }"
        ;;
    esac
  else
    d_err "subscription (Claude) probe failed — Claude jobs will decline"
  fi
  if probe="$("${MEUTE_ROOT}/bin/quota.sh" --engine codex --with-source 2>/dev/null)"; then
    d_ok "subscription (Codex): ${probe%% *}% remaining, from ${probe#* }"
  else
    d_warn "subscription (Codex): unavailable — configure MEUTE_CODEX_QUOTA_CMD; Codex jobs will decline"
  fi

  printf '\n  triage UI\n'
  if [[ -x "${MEUTE_ROOT}/tui/.venv/bin/python" ]]; then
    d_ok "tui/.venv present: meute tui / meute web are ready"
  elif command -v uv >/dev/null; then
    d_warn "no tui/.venv yet: the first 'meute tui' or 'meute web' creates it with uv"
  else
    d_warn "no uv on PATH: the triage UI cannot create its venv (the runner does not need it)"
  fi

  printf '\n  state\n'
  local dir
  for dir in state reports .worktrees; do
    mkdir -p "${MEUTE_ROOT}/${dir}" 2>/dev/null || true
    [[ -w "${MEUTE_ROOT}/${dir}" ]] && d_ok "${dir}/ writable" || d_err "${dir}/ not writable"
  done
  # The runner never commits state/ or reports/: they name private
  # repositories and carry unfixed findings. A tracked file there means the
  # ignore rules were loosened, and the next `git push` would publish it.
  if git -C "$MEUTE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    local tracked
    tracked="$(git -C "$MEUTE_ROOT" ls-files state reports | grep -cv '\.gitkeep' || true)"
    if (( tracked > 0 )); then
      d_warn "${tracked} file(s) under state/ or reports/ are tracked by git — they belong to this machine only"
    else
      d_ok "state and reports are gitignored; the runner never commits them"
    fi
  fi

  if hold_active; then
    d_warn "the fleet is PAUSED until $(hold_until_human "$HOLD_UNTIL")${HOLD_REASON:+ — ${HOLD_REASON}}"
    d_warn "nothing will run until then; lift it with:  ./bin/meute resume"
  fi

  # Not every machine has cron. Immutable Fedora variants ship without cronie,
  # and a crontab block there is instructions that silently never fire.
  printf '\n  scheduling\n'
  local extra; extra="$(dedup_dirs "${missing_from_cron[@]:-}")"
  local cron_path="${extra:+${extra}:}${CRON_PATH_DEFAULT}"

  if command -v crontab >/dev/null 2>&1; then
    d_ok "cron is available"
    [[ -n "$extra" ]] && printf '    PATH must be set - %s is not on cron'"'"'s default PATH.\n' "$extra"
    printf '\n    # paste into `crontab -e`\n'
    printf '    PATH=%s\n' "$cron_path"
    printf '    17 3 * * *  cd %s && ./bin/run.sh daily  >> state/cron.log 2>&1\n' "$MEUTE_ROOT"
    printf '    41 4 * * 6  cd %s && ./bin/run.sh weekly >> state/cron.log 2>&1\n' "$MEUTE_ROOT"
  elif systemctl --user --version >/dev/null 2>&1; then
    d_warn "no cron on this machine - use systemd user timers"
    case "$(linger_state)" in
      yes) d_ok "lingering enabled - timers fire while you are logged out" ;;
      no)  d_warn "lingering is OFF: user timers will NOT fire unless you are logged in"
           d_warn "enable with:  loginctl enable-linger $USER" ;;
      *)   d_warn "lingering: cannot tell - no system bus reachable from here (a container?)"
           d_warn "check on the host with:  loginctl show-user $USER --property=Linger" ;;
    esac
    local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    if [[ -f "${unit_dir}/meute-daily.timer" ]]; then
      d_ok "units installed in ${unit_dir}"
      local slot state detail
      for slot in daily weekly; do
        IFS=$'\t' read -r state detail <<<"$(timer_state "meute-${slot}.timer")"
        case "$state" in
          armed)  d_ok   "meute-${slot}.timer armed - next ${detail}" ;;
          idle)   d_warn "meute-${slot}.timer is ${detail} on disk but NOT armed: no next firing, so the ${slot} slot will not run"
                  d_warn "arm it with:  systemctl --user start meute-${slot}.timer" ;;
          absent) d_warn "meute-${slot}.timer is not loaded - run:  ./bin/meute install-timers" ;;
          *)      d_warn "meute-${slot}.timer: cannot ask systemd whether it is armed" ;;
        esac
      done
    else
      d_warn "units not installed - run:  ./bin/meute install-timers"
    fi
  else
    d_err "neither cron nor systemd --user is available; nothing can schedule this"
  fi

  printf '\n  %s error(s), %s warning(s)\n\n' "$DOCTOR_ERRORS" "$DOCTOR_WARNINGS"
  (( DOCTOR_ERRORS == 0 ))
}

# PRP-004: a container repo runs in the image it pins, and every proxied run
# needs the egress proxy up. Under the timer a drifted image or a stopped
# proxy is a step-over visible only on stderr; this is where it reaches the
# owner. Prints nothing on a fleet with no container repo -- list-images is
# unvalidated on purpose, so a manifest broken elsewhere still gets this far.
doctor_containers() {
  local images
  images="$(python3 "$MANIFEST_PY" list-images "$MANIFEST" 2>/dev/null \
              | jq -c 'select(.runtime == "container")' 2>/dev/null || true)"
  [[ -n "$images" ]] || return 0

  printf '\n  containers\n'
  if ! podman_available; then
    d_err "podman not found (MEUTE_PODMAN=${MEUTE_PODMAN:-unset}) — resolved to '$(podman_cmd)'; the image and egress checks need the host's podman"
    return 0
  fi
  local row name tag digest actual
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    { read -r name; read -r tag; read -r digest; } < <(jq -r '.name, .tag, .digest' <<< "$row")
    if [[ -z "$tag" ]]; then
      d_err "image for ${name}: no image.tag in the manifest (rule 1 refuses this repo)"
    elif [[ -z "$digest" ]]; then
      d_err "image ${tag}: no digest pinned yet -- meute image bump ${name}"
    elif ! actual="$(image_digest_on_host "$tag")"; then
      d_err "image ${tag} not present on the host — build it with Atelier, then: meute image bump ${name}"
    elif [[ "$actual" == "$digest" ]]; then
      d_ok "image ${tag} present at pinned digest"
    else
      d_err "image ${tag} is not at the pinned digest (manifest ${digest:0:19}…, host ${actual:0:19}…) — if the rebuild was yours: meute image bump ${name}"
    fi
  done <<< "$images"

  if egress_running; then
    d_ok "atelier-egress running"
  else
    d_err "atelier-egress is not running — every proxied run would be stepped over; start it with Atelier"
  fi
}
