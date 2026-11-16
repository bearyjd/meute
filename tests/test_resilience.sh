# Resilience-plan tests (docs/meute-resilience-plan P0.x). Sourced from
# tests/test_meute.sh (uses ok/bad/is/has/hasnt, REPO and FIXTURE).

# P0.9: the status-line capture must not leave rate-limits.json.* strays when
# the final rename fails or the render is killed, and sweeps old strays.
test_p09_statusline_tmp() {
  local root="$FIXTURE/p09" cap="$REPO/contrib/statusline-capture.sh"
  local state="$root/state" shim="$root/shim" doc
  mkdir -p "$state" "$shim"
  doc='{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":9999999999}}}'

  # mv shimmed to fail, then a normal run: nothing may be left behind.
  printf '#!/bin/sh\nexit 1\n' > "$shim/mv"; chmod +x "$shim/mv"
  printf '%s' "$doc" | PATH="$shim:$PATH" MEUTE_ROOT="$root" "$cap" -- 'true'
  is "p0.9 capture: a failed rename leaves no stray temp file" \
     "$(ls "$state" | grep -c '^rate-limits\.json\.')" "0"
  printf '%s' "$doc" | MEUTE_ROOT="$root" "$cap" -- 'true'
  is "p0.9 capture: the normal run still writes the snapshot" \
     "$(jq -r .five_hour.used_percentage "$state/rate-limits.json")" "5"
  is "p0.9 capture: ...and leaves no sibling files" \
     "$(ls "$state" | grep -c '^rate-limits\.json\.')" "0"

  # opportunistic sweep: old strays go, a fresh sibling (a concurrent render) stays.
  rm -f "$state/rate-limits.json"
  : > "$state/rate-limits.json.OLD123"; touch -d '20 minutes ago' "$state/rate-limits.json.OLD123"
  : > "$state/rate-limits.json.NEW123"
  printf '%s' "$doc" | MEUTE_ROOT="$root" "$cap" -- 'true'
  [[ ! -e "$state/rate-limits.json.OLD123" ]] && ok "p0.9 capture: a stray older than 10 minutes is swept" \
    || bad "p0.9 capture: a stray older than 10 minutes is swept" "still present"
  [[ -e "$state/rate-limits.json.NEW123" ]] && ok "p0.9 capture: a fresh sibling is left alone" \
    || bad "p0.9 capture: a fresh sibling is left alone" "was deleted"
  rm -f "$state"/rate-limits.json.*

  # an unwritable state dir must not put a redirect error on stderr: the
  # status line this script wraps must never break.
  if [[ "$(id -u)" == 0 ]]; then
    skip "p0.9 capture: unwritable state dir stays silent" "running as root; chmod cannot block writes"
  else
    rm -f "$state/rate-limits.json"; chmod 555 "$state"
    local err
    err="$(printf '%s' "$doc" | MEUTE_ROOT="$root" "$cap" -- 'true' 2>&1 >/dev/null)"
    chmod 755 "$state"
    is "p0.9 capture: unwritable state dir stays silent" "$err" ""
  fi
}

# P0.10: a workflow runs both suites on push and PR, using no third-party
# action beyond checkout, so a red test blocks merge.
test_p0_ci_workflow() {
  local wf="$REPO/.github/workflows/test.yml"
  [[ -f "$wf" ]] || { bad "ci workflow exists" "missing $wf"; return; }
  ok "ci workflow exists"
  local text; text="$(cat "$wf")"
  has "ci triggers on push" "$text" "push:"
  has "ci triggers on pull_request" "$text" "pull_request:"
  has "ci runs the shell suite" "$text" "bash tests/test_meute.sh"
  has "ci runs the unit suite" "$text" "python3 -m unittest discover tests"
  local bad_uses
  bad_uses="$(grep -E '^\s*-?\s*uses:' "$wf" | grep -v 'actions/checkout@' || true)"
  is "ci uses only actions/checkout" "$bad_uses" ""
}
