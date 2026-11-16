# Resilience tests (meute-resilience-plan.md, Phase 0 onward). Sourced from
# tests/test_meute.sh, which supplies REPO, FIXTURE and the ok/bad/is/has
# helpers; nothing here runs on its own.

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

# P0.1 (R2): the run lock is fd 9 of run.sh. Every child used to inherit it,
# so an engine that left a process behind (here: one in its own session,
# which no process-group kill reaches) held the lock after run.sh exited and
# every later fire skipped with "another run holds the lock".
test_run_lock_not_inherited() {
  local root="$FIXTURE/runlock" repo="$FIXTURE/runlock/git-lk"
  mkdir -p "$root/state" "$root/tasks" "$root/stub" "$repo"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  printf 'Task {{REPO_NAME}} {{REPO_PATH}} {{FILE_BUDGET}} {{LENS}} {{REPORT_PATH}} {{DATE}} {{BRANCH}} {{TASK}} {{TIER}} {{REPO_SPEC}} {{ALLOWED_COMMANDS}} {{DEFAULT_BRANCH}} {{UPSTREAM}} {{ETIQUETTE}} {{ETIQUETTE_CONTENT}} {{TICKET_ID}} {{TICKET_TITLE}} {{TICKET_NOTES}}\n' > "$root/tasks/t.md"
  git -C "$repo" init -q -b main
  echo x > "$repo/f.txt"; git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init

  # The stub engine leaves an orphan in a new session, stdio detached, and
  # records its pid. The auth probe does not, so only the engine call is tested.
  local pidfile="$root/orphan.pid"
  cat > "$root/stub/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
setsid sleep 60 </dev/null >/dev/null 2>&1 &
printf '%s\n' "\$!" > "$pidfile"
jq -n --arg r "## Summary
stub" '{is_error:false,result:\$r,total_cost_usd:0.01,num_turns:1}'
STUB
  chmod +x "$root/stub/claude"

  python3 - "$root" "$repo" <<'PY'
import sys, pathlib, yaml
root, repo = sys.argv[1], sys.argv[2]
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.20,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"t": {"tier": "tier2", "template": "tasks/t.md", "slots": ["daily"]}},
    "repos": [{"name": "lk", "path": repo, "spec": "lock fixture", "tasks": ["t"]}],
    "community": [],
}, open(pathlib.Path(root) / "repos.yaml", "w"), sort_keys=False)
PY

  local out out2 orphan="" fds=""
  out="$(env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily 2>&1)"
  has "run lock: the first run completes through the stub engine" "$out" "status=ok"
  orphan="$(cat "$pidfile" 2>/dev/null)"
  if [[ -n "$orphan" && -d "/proc/$orphan" ]]; then
    fds="$(ls -l "/proc/$orphan/fd" 2>/dev/null)"
    hasnt "run lock: the engine's orphan does not hold state/.lock" "$fds" "state/.lock"
  else
    bad "run lock: the engine's orphan does not hold state/.lock" "stub orphan not running (pid [$orphan])"
  fi
  has "run lock: lock-info names the holder's pid" "$(cat "$root/state/lock-info" 2>/dev/null)" "pid="
  has "run lock: lock-info names the slot"         "$(cat "$root/state/lock-info" 2>/dev/null)" "slot=daily"

  # With the orphan still alive, the next fire must get past the lock.
  out2="$(env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily 2>&1)"
  hasnt "run lock: a later run is not blocked by the orphan" "$out2" "another run holds the lock"
  has   "run lock: ...and runs the queue past the lock"     "$(tail -1 "$root/state/log")" "status=ok"
  # Both runs left an orphan; neither may outlive the test.
  kill "$orphan" "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null

  # Positive control: a real holder still makes a run skip, and the loser
  # leaves the holder's lock-info alone.
  local info_before; info_before="$(cat "$root/state/lock-info" 2>/dev/null)"
  local held
  exec {held}>"$root/state/.lock"
  flock -n "$held"
  out2="$(env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily 2>&1)"
  exec {held}>&-
  has "run lock: a live holder still makes a run skip" "$out2" "another run holds the lock"
  is  "run lock: the skipped run leaves lock-info alone" "$(cat "$root/state/lock-info" 2>/dev/null)" "$info_before"
}

# A fixture for the lock tests below: one repo, one task on the given tier
# (tier1 writes code, tier2 does not), a stub claude that appends to f.txt
# and reports. Prints nothing; run with "$1/bin/run.sh".
_runlock_fixture() {
  local root="$1" repo="$2" tier="$3"
  mkdir -p "$root/state" "$root/tasks" "$root/stub" "$repo"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  printf 'Task {{REPO_NAME}} {{REPO_PATH}} {{FILE_BUDGET}} {{LENS}} {{REPORT_PATH}} {{DATE}} {{BRANCH}} {{TASK}} {{TIER}} {{REPO_SPEC}} {{ALLOWED_COMMANDS}} {{DEFAULT_BRANCH}} {{UPSTREAM}} {{ETIQUETTE}} {{ETIQUETTE_CONTENT}} {{TICKET_ID}} {{TICKET_TITLE}} {{TICKET_NOTES}}\n' > "$root/tasks/t.md"
  git -C "$repo" init -q -b main
  echo x > "$repo/f.txt"; git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
printf 'changed by the stub\n' >> f.txt
jq -n '{is_error:false,result:"## Summary\nstub ran",total_cost_usd:0.01,num_turns:1}'
STUB
  chmod +x "$root/stub/claude"
  python3 - "$root" "$repo" "$tier" <<'PY'
import sys, pathlib, yaml
root, repo, tier = sys.argv[1], sys.argv[2], sys.argv[3]
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.20,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier1": {"tools": "Read", "permission_mode": "acceptEdits", "writes_code": True, "network": "proxied"},
              "tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"t": {"tier": tier, "template": "tasks/t.md", "slots": ["daily"]}},
    "repos": [{"name": "lk", "path": repo, "spec": "lock fixture", "tasks": ["t"]}],
    "community": [],
}, open(pathlib.Path(root) / "repos.yaml", "w"), sort_keys=False)
PY
}

# P0.1 (R2), the call sites the engine test does not reach: git runs the
# target repo's own hooks and filters (pre-commit, post-checkout,
# reference-transaction, clean/smudge), and one that leaves a daemon behind
# (eslint_d, prettierd, a gradle daemon) would hold the lock exactly as an
# engine orphan would. Here the owner's pre-commit leaves one at the commit.
test_run_lock_git_hooks() {
  local root="$FIXTURE/runlock-hook" repo="$FIXTURE/runlock-hook/git-lk" out pid="" fds=""
  _runlock_fixture "$root" "$repo" tier1
  printf '#!/bin/sh\nsetsid sleep 60 </dev/null >/dev/null 2>&1 &\necho $! > "%s/hook.pid"\n' "$root" > "$repo/.git/hooks/pre-commit"
  chmod +x "$repo/.git/hooks/pre-commit"
  out="$(env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily 2>&1)"
  has "run lock: a write run commits through the owner's pre-commit" "$(tail -1 "$root/state/log")" "status=ok"
  pid="$(cat "$root/hook.pid" 2>/dev/null)"
  if [[ -n "$pid" && -d "/proc/$pid" ]]; then
    fds="$(ls -l "/proc/$pid/fd" 2>/dev/null)"
    hasnt "run lock: a git hook's orphan does not hold state/.lock" "$fds" "state/.lock"
  else
    bad "run lock: a git hook's orphan does not hold state/.lock" "hook orphan not running (pid [$pid]); run said: $out"
  fi
  out="$(env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily 2>&1)"
  hasnt "run lock: a later run is not blocked by the hook's orphan" "$out" "another run holds the lock"
  kill "$pid" "$(cat "$root/hook.pid" 2>/dev/null)" 2>/dev/null
}

# "another run holds the lock" must mean exactly that. A lock file that
# cannot be opened is a broken state directory and ends the run as an error;
# lock-info is diagnosis only, and failing to write it never stops a run.
test_run_lock_error_paths() {
  local root="$FIXTURE/runlock-err" repo="$FIXTURE/runlock-err/git-lk" out rc
  _runlock_fixture "$root" "$repo" tier2

  mkdir "$root/state/.lock"
  rc=0; out="$(env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily 2>&1)" || rc=$?
  hasnt "run lock: an unopenable lock file is not reported as a holder" "$out" "another run holds the lock"
  has   "run lock: ...it is named as the error"                        "$out" "cannot open the run lock"
  is    "run lock: ...and the run fails"                               "$rc" "1"
  rmdir "$root/state/.lock"

  mkdir "$root/state/lock-info"
  rc=0; out="$(env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily 2>&1)" || rc=$?
  hasnt "run lock: an unwritable lock-info is not reported as a holder" "$out" "another run holds the lock"
  has   "run lock: ...and the run goes on"                              "$(tail -1 "$root/state/log")" "status=ok"
  is    "run lock: ...to a clean exit"                                  "$rc" "0"
  rmdir "$root/state/lock-info"
}

# P0.2 (R1): every fire leaves exactly one state/log line, and that line names
# its outcome in a code= field. A fatal path used to exit with
# nothing in state/log, so a broken manifest stopped the fleet silently.
_log_lines() { [[ -f "$1" ]] && wc -l < "$1" || echo 0; }

test_exit_log_line() {
  local root="$FIXTURE/exitlog" repo="$FIXTURE/exitlog/git-lk" log out rc before
  _runlock_fixture "$root" "$repo" tier2
  log="$root/state/log"
  local fire=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily )

  # A manifest that fails validation: one died line, naming the cause.
  cp "$root/repos.yaml" "$root/repos.yaml.good"
  printf 'version: 1\nrepos: not-a-list\n' > "$root/repos.yaml"
  before="$(_log_lines "$log")"
  rc=0; out="$("${fire[@]}" 2>&1)" || rc=$?
  is  "exit log: an invalid manifest adds exactly one line" "$(( $(_log_lines "$log") - before ))" "1"
  has "exit log: ...with code=died"                         "$(tail -1 "$log" 2>/dev/null)" $'\tcode=died'
  has "exit log: ...and status=error"                       "$(tail -1 "$log" 2>/dev/null)" $'\tstatus=error'
  has "exit log: ...naming the cause in detail="            "$(tail -1 "$log" 2>/dev/null)" "detail=manifest failed validation"
  is  "exit log: ...and the run still fails"                "$rc" "1"
  has "exit log: ...still saying why on stderr"             "$out" "meute: manifest failed validation"
  mv "$root/repos.yaml.good" "$root/repos.yaml"

  # A death no die() reports: mktemp fails under set -e.
  before="$(_log_lines "$log")"
  rc=0; out="$(env TMPDIR=/nonexistent "${fire[@]}" 2>&1)" || rc=$?
  is  "exit log: a failed mktemp adds exactly one line" "$(( $(_log_lines "$log") - before ))" "1"
  has "exit log: ...with code=died"                     "$(tail -1 "$log" 2>/dev/null)" $'\tcode=died'

  # A skip: one line, its reason= unchanged, and a code= from the fixed list.
  printf 'hold\t%s\t%s\n' "$(( $(date +%s) + 3600 ))" "testing" > "$root/state/hold"
  before="$(_log_lines "$log")"
  rc=0; out="$("${fire[@]}" 2>&1)" || rc=$?
  is  "exit log: a hold adds exactly one line"   "$(( $(_log_lines "$log") - before ))" "1"
  has "exit log: ...keeping its reason="         "$(tail -1 "$log")" $'\treason=paused until'
  has "exit log: ...with code=hold"              "$(tail -1 "$log")" $'\tcode=hold'
  is  "exit log: ...and exits 0"                 "$rc" "0"
  rm -f "$root/state/hold"

  local held; exec {held}>"$root/state/.lock"; flock -n "$held"
  before="$(_log_lines "$log")"
  "${fire[@]}" >/dev/null 2>&1
  exec {held}>&-
  is  "exit log: a held lock adds exactly one line" "$(( $(_log_lines "$log") - before ))" "1"
  has "exit log: ...with code=lock"                 "$(tail -1 "$log")" $'\tcode=lock'

  before="$(_log_lines "$log")"
  env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=10 "$root/bin/run.sh" daily >/dev/null 2>&1
  is  "exit log: a quota below the floor adds exactly one line" "$(( $(_log_lines "$log") - before ))" "1"
  has "exit log: ...with code=nothing-eligible"                  "$(tail -1 "$log")" $'\tcode=nothing-eligible'

  # A completed run: exactly one line (no second line from the exit trap),
  # still ending in code=.
  before="$(_log_lines "$log")"
  rc=0; "${fire[@]}" >/dev/null 2>&1 || rc=$?
  is  "exit log: a completed run adds exactly one line" "$(( $(_log_lines "$log") - before ))" "1"
  has "exit log: ...status=ok"                          "$(tail -1 "$log")" $'\tstatus=ok'
  has "exit log: ...with code=ok"                       "$(tail -1 "$log")" $'\tcode=ok'
  is  "exit log: ...and exits 0"                        "$rc" "0"

  # A failed run logs its own line and exits 1; the exit trap adds nothing.
  sed -i 's/is_error:false/is_error:true/' "$root/stub/claude"
  before="$(_log_lines "$log")"
  rc=0; "${fire[@]}" >/dev/null 2>&1 || rc=$?
  is  "exit log: a failed run adds exactly one line" "$(( $(_log_lines "$log") - before ))" "1"
  has "exit log: ...with code=failed"                "$(tail -1 "$log")" $'\tcode=failed'
  is  "exit log: ...and exits 1"                     "$rc" "1"
  sed -i 's/is_error:true/is_error:false/' "$root/stub/claude"

  # A dry run is not a fire and writes nothing, as before.
  before="$(_log_lines "$log")"
  "${fire[@]}" --dry-run >/dev/null 2>&1
  is  "exit log: a dry run adds no line" "$(( $(_log_lines "$log") - before ))" "0"

  # A died fire ran no engine, so it is not a run and spends no budget. The
  # log now holds two died lines, three skips, one ok and one failed: 2 runs.
  is  "exit log: died fires are not runs in the inbox" \
      "$(MEUTE_ROOT="$root" python3 "$root/lib/inbox.py" dump | jq -r .status.runs)" "2"
  is  "exit log: ...nor spend weekly_runs" \
      "$(MEUTE_ROOT="$root" MEUTE_WEEKLY_RUNS=10 "$root/contrib/quota-self-budget.sh")" "80"
  is  "exit log: ...nor count in week_runs" \
      "$(LOG_FILE="$log" THIS_WEEK="$(date +%G-%V)"; source "$root/lib/fleet.sh"; week_runs)" "2"
  has "exit log: ...nor in the status total" \
      "$(env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/meute" status 2>&1)" "  2 runs ("
  local last_ok; last_ok="$(grep $'\tcode=failed\t' "$log" | tail -1 | cut -f1)"
  printf '9999-12-31T00:00:00+00:00\tweek=%s\tslot=daily\tstatus=error\tdetail=x\tcode=died\tdur=0s\truntime=-\timage=-\tstage=-\tpr=-\n' \
    "$(date +%G-%V)" >> "$log"
  is  "exit log: ...nor become the inbox's last_run" \
      "$(MEUTE_ROOT="$root" python3 "$root/lib/inbox.py" dump | jq -r .status.last_run)" "$last_ok"
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
