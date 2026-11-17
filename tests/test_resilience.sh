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

# P0.5: `meute status` and `meute findings` must cost a constant number of
# python3 spawns, not one or more per report. A `python3` shim on PATH counts
# invocations; the output must stay byte-identical to the per-report version.
test_p0_5_single_process_reads() {
  local root="$FIXTURE/p05" i n
  mkdir -p "$root/reports/alpha" "$root/reports/beta" "$root/state" "$root/tasks" "$root/shim"
  ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO"/tasks/*.md "$root/tasks/"
  cp "$FIXTURE/repos.yaml" "$root/repos.yaml"
  # 50 reports: 25 per repo, each with two findings of differing severity.
  for i in $(seq 1 50); do
    local repo=alpha; (( i % 2 )) || repo=beta
    printf -- '---\nrepo: %s\ntask: audit-security\ntier: tier2\nstarted: 2026-09-%02dT04:00:00-04:00\nstatus: ok\n---\n\n## Summary\nx\n\n## Findings\n\n### [%s] Title %s one\n- **Anchor:** `src/a.py:%s`\n\n### [LOW] Title %s two\n- **Anchor:** `src/b.py:%s`\n' \
      "$repo" "$(( i % 28 + 1 ))" "$( (( i % 3 )) && echo HIGH || echo CRITICAL )" "$i" "$i" "$i" "$i" \
      > "$root/reports/$repo/audit-$(printf '%02d' "$i").md"
  done
  # Decisions: one report read, one finding dismissed, one finding promoted.
  printf 'alpha/audit-01\tread\t2026-09-01T00:00:00-04:00\t\nalpha/audit-01#1\tdismissed\t2026-09-01T00:00:00-04:00\tdup\nbeta/audit-02#2\tactioned\t2026-09-01T00:00:00-04:00\tdone\n' \
    > "$root/state/reports"
  # A report that cannot be parsed still counts as unread, as it does today.
  printf 'not a report\n' > "$root/reports/beta/audit-zz-broken.md"

  local real_py; real_py="$(command -v python3)"
  printf '#!/usr/bin/env bash\necho x >> %q\nexec %q "$@"\n' "$root/spawns" "$real_py" > "$root/shim/python3"
  chmod +x "$root/shim/python3"

  local out_new out_all status_out
  : > "$root/spawns"
  out_new="$(PATH="$root/shim:$PATH" "$root/bin/meute" findings --new 2>&1)"
  n="$(wc -l < "$root/spawns")"
  (( n <= 2 )) && ok "p0.5: findings --new spawns <= 2 python3 on 50 reports ($n)" \
               || bad "p0.5: findings --new spawn count" "$n python3 spawns, want <= 2"
  : > "$root/spawns"
  out_all="$(PATH="$root/shim:$PATH" "$root/bin/meute" findings --all 2>&1)"
  n="$(wc -l < "$root/spawns")"
  (( n <= 2 )) && ok "p0.5: findings --all spawns <= 2 python3 ($n)" \
               || bad "p0.5: findings --all spawn count" "$n python3 spawns, want <= 2"
  : > "$root/spawns"
  status_out="$(PATH="$root/shim:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/meute" status 2>&1)"
  n="$(wc -l < "$root/spawns")"
  (( n <= 6 )) && ok "p0.5: status spawns <= 6 python3 on 50 reports ($n)" \
               || bad "p0.5: status spawn count" "$n python3 spawns, want <= 6"

  # Golden output, identical before and after the change.
  has "p0.5: status unread count (51 reports, one read)" "$status_out" "reports unread    50"
  is  "p0.5: findings --new row count" "$(grep -c '^    NEW' <<< "$out_new")" "98"
  is  "p0.5: findings --all row count" "$(grep -c '^    [A-Za-z]' <<< "$out_all")" "100"
  is  "p0.5: dismissed finding hidden from --new" "$(grep -c 'alpha/audit-01#1' <<< "$out_new")" "0"
  is  "p0.5: dismissed finding shown by --all"    "$(grep 'alpha/audit-01#1' <<< "$out_all" | awk '{print $1}')" "dismissed"
  is  "p0.5: first rows grouped by repo, most severe first" "$(sed -n 1,4p <<< "$out_new")" \
"  alpha
    NEW       CRITICAL  alpha/audit-03#1                               Title 3 one
    NEW       CRITICAL  alpha/audit-09#1                               Title 9 one
    NEW       CRITICAL  alpha/audit-15#1                               Title 15 one"
  is  "p0.5: footer" "$(tail -1 <<< "$out_new")" "meute: act with: meute promote <id> -f <n>   |   meute dismiss <id> -f <n> -r <reason>"
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

  # A death with no temp directory to work in. (TMPDIR no longer reaches it:
  # since P0.4 the run's directory is under state/tmp or MEUTE_TMPDIR.)
  before="$(_log_lines "$log")"
  rc=0; out="$(env MEUTE_TMPDIR=/nonexistent "${fire[@]}" 2>&1)" || rc=$?
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

# P0.5 follow-ups: a crash in inbox.py must be loud, and non-regular `.md`
# entries (symlinks, directories) are not reports, in the count or the list.
test_p0_5_findings_failure_and_nonregular() {
  local root="$FIXTURE/p05b" out rc
  mkdir -p "$root/reports/alpha" "$root/reports/beta" "$root/state" "$root/tasks" "$root/lib"
  ln -sfn "$REPO/bin" "$root/bin"
  cp "$REPO"/lib/* "$root/lib/" 2>/dev/null
  cp "$REPO"/tasks/*.md "$root/tasks/"
  cp "$FIXTURE/repos.yaml" "$root/repos.yaml"
  printf -- '---\nrepo: alpha\ntask: audit-security\ntier: tier2\nstarted: 2026-09-01T04:00:00-04:00\nstatus: ok\n---\n\n## Summary\nx\n\n## Findings\n\n### [HIGH] Real one\n- **Anchor:** `src/a.py:1`\n' \
    > "$root/reports/alpha/audit-01.md"
  # Non-regular entries that the shell `find -type f` never listed.
  ln -s "audit-01.md" "$root/reports/alpha/audit-link.md"
  mkdir "$root/reports/beta/dir.md"
  out="$("$root/bin/meute" status 2>&1 | grep 'reports unread')"
  has "p0.5: unread count ignores symlinks and directories" "$out" "reports unread    1"
  out="$("$root/bin/meute" findings --all 2>&1)"
  is "p0.5: findings ignores symlinked report" "$(grep -c 'audit-link' <<< "$out")" "0"

  # state/reports parity with the shell kv_row: first duplicate wins, a
  # key-only row (no tab) is not a decision.
  printf 'alpha/audit-01#1\tdismissed\t2026-09-02\nalpha/audit-01#1\tactioned\t2026-09-03\n' > "$root/state/reports"
  out="$("$root/bin/meute" findings --all 2>&1)"
  has "p0.5: duplicate state rows: first wins" "$(grep 'audit-01#1' <<< "$out")" "dismissed"
  printf 'alpha/audit-01#1\n' > "$root/state/reports"
  out="$("$root/bin/meute" findings --new 2>&1)"
  is  "p0.5: key-only state row hides the finding from --new" "$(grep -c 'audit-01#1' <<< "$out")" "0"
  : > "$root/state/reports"

  # An unreadable report is named on stderr, not silently dropped.
  if [[ "$(id -u)" != 0 ]]; then
    cp "$root/reports/alpha/audit-01.md" "$root/reports/alpha/audit-02.md"
    chmod 000 "$root/reports/alpha/audit-02.md"
    out="$("$root/bin/meute" findings --all 2>&1)"
    chmod 644 "$root/reports/alpha/audit-02.md"
    has "p0.5: unreadable report is warned about" "$out" "skipping unreadable report alpha/audit-02"
    rm "$root/reports/alpha/audit-02.md"
  fi

  # A crashing inbox.py: stderr is shown, a warning is printed, exit is non-zero.
  printf 'import sys\nsys.stderr.write("boom-from-inbox\\n")\nsys.exit(3)\n' > "$root/lib/inbox.py"
  rc=0; out="$("$root/bin/meute" findings --new 2>&1)" || rc=$?
  is  "p0.5: findings exits non-zero when inbox.py crashes" "$(( rc != 0 ))" "1"
  has "p0.5: findings shows the inbox.py error" "$out" "boom-from-inbox"
  has "p0.5: findings warns instead of 'no new findings'" "$out" "meute: findings failed"
  is  "p0.5: no false 'no new findings' on crash" "$(grep -c 'no new findings' <<< "$out")" "0"
}

# P0.3 (R1, second half): --strict-exit (or MEUTE_STRICT_EXIT=1) makes the exit
# status say how the fire ended, so a loop can branch on $? alone. Without it
# every skip still exits 0 (cron and the installed units are unaffected; the
# P0.2 tests above pin that). One case per code in the table.
test_strict_exit_codes() {
  local root="$FIXTURE/strict" repo="$FIXTURE/strict/git-lk" log rc
  _runlock_fixture "$root" "$repo" tier2
  log="$root/state/log"
  cp "$root/repos.yaml" "$root/repos.yaml.good"
  local run=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" )
  # _strict <label> <expected status> <command...>
  _strict() {
    local label="$1" want="$2"; shift 2
    local got=0; "$@" >/dev/null 2>&1 || got=$?
    is "strict exit: $label" "$got" "$want"
  }

  _strict "a completed run is 0"           0 "${run[@]}" daily --strict-exit
  _strict "a dry run is 0"                 0 "${run[@]}" daily --dry-run --strict-exit

  sed -i 's/is_error:false/is_error:true/' "$root/stub/claude"
  _strict "a run that ran and failed is 1" 1 "${run[@]}" daily --strict-exit
  sed -i 's/is_error:true/is_error:false/' "$root/stub/claude"

  _strict "a missing slot is 2 (usage)"     2 "${run[@]}" --strict-exit
  _strict "an unknown argument is 2 (usage)" 2 "${run[@]}" daily --bogus --strict-exit

  printf 'hold\t%s\t%s\n' "$(( $(date +%s) + 3600 ))" "testing" > "$root/state/hold"
  _strict "a hold is 10" 10 "${run[@]}" daily --strict-exit
  _strict "the env var enables it too" 10 env MEUTE_STRICT_EXIT=1 "${run[@]}" daily
  _strict "...but a hold is 0 without either" 0 "${run[@]}" daily
  rm -f "$root/state/hold"

  local held; exec {held}>"$root/state/.lock"; flock -n "$held"
  _strict "a held lock is 11" 11 "${run[@]}" daily --strict-exit
  exec {held}>&-

  cp "$root/repos.yaml.good" "$root/repos.yaml"
  python3 - "$root/repos.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); d["policy"]["weekly_runs"] = 1
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PY
  _strict "a spent self-budget is 12" 12 "${run[@]}" daily --strict-exit
  cp "$root/repos.yaml.good" "$root/repos.yaml"

  _strict "a quota below the floor is 13" 13 \
    env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=10 "$root/bin/run.sh" daily --repo lk --task t --strict-exit
  _strict "an unreadable quota is 13" 13 \
    env PATH="$root/stub:$PATH" MEUTE_CLAUDE_QUOTA_CMD=false "$root/bin/run.sh" daily --repo lk --task t --strict-exit
  _strict "nothing eligible is 14" 14 \
    env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=10 "$root/bin/run.sh" daily --strict-exit

  printf 'version: 1\nrepos: not-a-list\n' > "$root/repos.yaml"
  _strict "a runner that died is 70" 70 "${run[@]}" daily --strict-exit
  _strict "...but 1 without the flag" 1 "${run[@]}" daily
  _strict "a death with no temp directory is 70" 70 env MEUTE_TMPDIR=/nonexistent "${run[@]}" daily --strict-exit
  mv "$root/repos.yaml.good" "$root/repos.yaml"

  # The codes with no reachable trigger in a fixture (the load and disk gates
  # are not wired yet) are pinned through the table itself.
  local code want
  for code in "hold 10" "lock 11" "budget 12" "quota-floor 13" "quota-unknown 13" \
              "nothing-eligible 14" "no-queue 14" "load 15" "disk 15" "ok 0" "failed 1" "died 70"; do
    want="${code#* }"; code="${code% *}"
    is "strict exit: table maps code=$code to $want" \
      "$(MEUTE_ROOT="$REPO" bash -c 'source "$MEUTE_ROOT/lib/outcome.sh"; outcome_exit_status "$1"' _ "$code")" "$want"
  done
  unset -f _strict
}

# P0.4 (R3, R14 part): a fire's temp files live in one directory of its own,
# under state/tmp (or MEUTE_TMPDIR), and that directory goes on every exit.
# Before, five bare mktemp files per full run landed in $TMPDIR and stayed
# (queue_file's RETURN trap never fires: main exits, it does not return), and
# a full or unwritable /tmp killed the fire. The sentinel TMPDIR catches a
# file that escapes the run's directory; the state/tmp count catches a run
# directory that is never removed.
_count_entries() { [[ -d "$1" ]] && find "$1" -mindepth 1 | wc -l || echo 0; }

test_run_tmp_cleaned() {
  local root="$FIXTURE/runtmp" repo="$FIXTURE/runtmp/git-lk" sentinel="$FIXTURE/runtmp-sentinel" rc
  _runlock_fixture "$root" "$repo" tier2
  mkdir -p "$sentinel"

  # _tmp_case <label> <expected last-log fragment or ""> <quota> [run.sh args...]
  _tmp_case() {
    local label="$1" want="$2" quota="$3"; shift 3
    env TMPDIR="$sentinel" PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB="$quota" "$root/bin/run.sh" daily "$@" >/dev/null 2>&1
    is "run tmp: $label leaves nothing in TMPDIR"   "$(_count_entries "$sentinel")" "0"
    is "run tmp: $label leaves nothing in state/tmp" "$(_count_entries "$root/state/tmp")" "0"
    [[ -z "$want" ]] || has "run tmp: $label ends as expected" "$(tail -1 "$root/state/log" 2>/dev/null)" "$want"
  }
  _tmp_case "a full run"    $'\tcode=ok'               100
  _tmp_case "a dry run"     ""                         100 --dry-run
  _tmp_case "a skipped run" $'\tcode=nothing-eligible' 10
  unset -f _tmp_case

  # A dry run's point is the prompt it names, so that file is not a temp file:
  # it outlives the run at one fixed path under state/, overwritten each time.
  local out prompt
  out="$(env TMPDIR="$sentinel" PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily --dry-run 2>&1)"
  prompt="$(grep -oE 'prompt=\S+' <<< "$out" | cut -d= -f2)"
  is  "run tmp: a dry run's prompt is kept at a fixed state path" "$prompt" "$root/state/dry-run-prompt.md"
  has "run tmp: ...and is readable after the run"                  "$(cat "$prompt" 2>/dev/null)" "Task lk"

  # /tmp unwritable is no longer fatal: the run's directory is under state/.
  rc=0; env TMPDIR=/nonexistent PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily >/dev/null 2>&1 || rc=$?
  has "run tmp: a run with TMPDIR unwritable completes" "$(tail -1 "$root/state/log")" $'\tcode=ok'
  is  "run tmp: ...and exits 0"                         "$rc" "0"

  # MEUTE_TMPDIR moves it; the run's directory is created and removed there.
  # A probe engine records the TMPDIR it is handed mid-run, so a runner that
  # ignored MEUTE_TMPDIR (and used state/tmp) fails here, not just elsewhere.
  local alt="$FIXTURE/runtmp-alt" probe="$FIXTURE/runtmp-probe" seen
  mkdir -p "$alt" "$probe"
  printf '#!/usr/bin/env bash\n[[ "$1" == auth ]] || { [[ -d "$TMPDIR" ]] && printf "%%s\\n" "$TMPDIR" > "%s/seen"; }\nexec "%s/stub/claude" "$@"\n' \
    "$probe" "$root" > "$probe/claude"
  chmod +x "$probe/claude"
  env MEUTE_TMPDIR="$alt" TMPDIR="$sentinel" PATH="$probe:$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily >/dev/null 2>&1
  seen="$(cat "$probe/seen" 2>/dev/null)"
  has "run tmp: MEUTE_TMPDIR is honoured"           "$(tail -1 "$root/state/log")" $'\tcode=ok'
  has "run tmp: ...the run directory is made there" "$seen" "$alt/run."
  is  "run tmp: ...and removed after the run"       "$([[ -n "$seen" && ! -e "$seen" ]] && echo gone || echo "present:$seen")" "gone"
  is  "run tmp: ...and left empty"                  "$(_count_entries "$alt")" "0"
  is  "run tmp: ...with nothing in TMPDIR"          "$(_count_entries "$sentinel")" "0"

  # The runner's temp files are private to the user who runs it.
  has "run tmp: the run directory template is private" \
    "$(MEUTE_ROOT="$REPO" bash -c 'die() { exit 1; }; source "$MEUTE_ROOT/lib/tmp.sh"; tmp_init "$1"; stat -c %a "$RUN_TMP"; tmp_cleanup' _ "$root/state")" "700"

  # meute findings: same treatment. Its temp file used to be a bare mktemp.
  local want got
  want="$(meute findings --new 2>&1)"
  rc=0; got="$(TMPDIR=/nonexistent meute findings --new 2>&1)" || rc=$?
  is "run tmp: meute findings works with TMPDIR unwritable" "$got" "$want"
  is "run tmp: ...and exits 0"                              "$rc" "0"
  is "run tmp: ...leaving nothing in state/tmp"             "$(_count_entries "$FIXTURE/state/tmp")" "0"
}

# P0.6 (R9): a probe that hangs used to hang the fire while it held the lock.
# Each probe is now bounded (30 s), so a hung one reads as "unknown" and the
# slot is declined, not wedged. The three cases run side by side because each
# one costs the full bound when the guard is missing.
test_bounded_probes() {
  local root="$FIXTURE/probes" repo="$FIXTURE/probes/git-lk" d
  _runlock_fixture "$root" "$repo" tier2
  # A root whose quota.sh itself hangs, to reach the outer bound at the call site.
  local hroot="$FIXTURE/probes-hang"
  _runlock_fixture "$hroot" "$FIXTURE/probes-hang/git-lk" tier2
  rm "$hroot/bin"; mkdir "$hroot/bin"; cp "$REPO/bin/run.sh" "$hroot/bin/run.sh"
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$hroot/bin/quota.sh"; chmod +x "$hroot/bin/quota.sh"
  # A self-budget adapter that hangs.
  local broot="$FIXTURE/probes-budget"; mkdir -p "$broot/contrib"
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$broot/contrib/quota-self-budget.sh"; chmod +x "$broot/contrib/quota-self-budget.sh"

  local t0=$SECONDS
  ( env PATH="$root/stub:$PATH" MEUTE_CLAUDE_QUOTA_CMD='sleep 300' timeout 90 "$root/bin/run.sh" daily --repo lk --task t >/dev/null 2>&1
    echo $((SECONDS - t0)) > "$root/elapsed" ) &
  ( env PATH="$hroot/stub:$PATH" timeout 90 "$hroot/bin/run.sh" daily --repo lk --task t >/dev/null 2>&1
    echo $((SECONDS - t0)) > "$hroot/elapsed" ) &
  ( MEUTE_ROOT="$broot" timeout 90 bash -c 'source "$1"; fleet_self_budget_remaining' _ "$REPO/lib/fleet.sh" >/dev/null 2>&1
    echo "$?" > "$broot/rc"; echo $((SECONDS - t0)) > "$broot/elapsed" ) &
  # quota.sh called directly (doctor and status do), without run.sh's bound.
  ( MEUTE_CLAUDE_QUOTA_CMD='sleep 300' timeout 90 "$REPO/bin/quota.sh" --engine claude >/dev/null 2>&1
    echo "$?" > "$root/direct.rc"; echo $((SECONDS - t0)) > "$root/direct.elapsed" ) &
  wait

  [[ "$(cat "$root/direct.rc")" == 1 && "$(cat "$root/direct.elapsed")" -lt 40 ]] \
    && ok "probes: quota.sh on its own gives up on a hung command within 40 s" \
    || bad "probes: quota.sh on its own gives up on a hung command within 40 s" "rc=$(cat "$root/direct.rc") took $(cat "$root/direct.elapsed") s"
  has "probes: a hung configured quota command is skipped as quota-unknown" "$(tail -1 "$root/state/log" 2>/dev/null)" "code=quota-unknown"
  [[ "$(cat "$root/elapsed")" -lt 40 ]] && ok "probes: ...within 40 s" || bad "probes: ...within 40 s" "took $(cat "$root/elapsed") s"
  has "probes: a hung quota.sh is skipped as quota-unknown" "$(tail -1 "$hroot/state/log" 2>/dev/null)" "code=quota-unknown"
  [[ "$(cat "$hroot/elapsed")" -lt 45 ]] && ok "probes: ...within 45 s" || bad "probes: ...within 45 s" "took $(cat "$hroot/elapsed") s"
  [[ "$(cat "$broot/rc")" != 0 && "$(cat "$broot/elapsed")" -lt 40 ]] \
    && ok "probes: a hung self-budget adapter fails within 40 s" \
    || bad "probes: a hung self-budget adapter fails within 40 s" "rc=$(cat "$broot/rc") took $(cat "$broot/elapsed") s"
}

# P0.6 (R9): bounding the probe must not loosen it. eval ran a configured probe
# under quota.sh's own pipefail and nounset, with quota.sh's MEUTE_ROOT in scope;
# the bounded child shell has to keep all three, or a broken probe reads as a quota.
test_probe_shell_options() {
  local rc out
  rc=0; MEUTE_CLAUDE_QUOTA_CMD='false | echo 50' "$REPO/bin/quota.sh" --engine claude >/dev/null 2>&1 || rc=$?
  is "probes: a pipeline whose first stage fails still declines (exit 1)" "$rc" "1"
  rc=0; MEUTE_CLAUDE_QUOTA_CMD='echo $MEUTE_UNSET_PROBE_VAR; echo 50' "$REPO/bin/quota.sh" --engine claude >/dev/null 2>&1 || rc=$?
  is "probes: a probe reading an unset variable still declines (exit 1)" "$rc" "1"
  rc=0; MEUTE_CLAUDE_QUOTA_CMD='false; echo 50' "$REPO/bin/quota.sh" --engine claude >/dev/null 2>&1 || rc=$?
  is "probes: a probe whose earlier command fails declines (exit 1)" "$rc" "1"
  rc=0; out="$(env -u MEUTE_ROOT MEUTE_CLAUDE_QUOTA_CMD='test "$MEUTE_ROOT" = "'"$REPO"'" && echo 77' \
    "$REPO/bin/quota.sh" --engine claude 2>/dev/null)" || rc=$?
  is "probes: a probe sees quota.sh's MEUTE_ROOT when the caller did not export it" "$rc:$out" "0:77"
}

# P0.6 (R9, R7 part): the generated service gets resource limits and a start
# timeout, so a hung fire can neither starve the desktop nor outlive its
# manifest's longest timeout_seconds (60 in this fixture) plus ten minutes.
test_unit_limits() {
  local root="$FIXTURE/unitlimits" repo="$FIXTURE/unitlimits/git-lk" home="$FIXTURE/unitlimits/home" stub="$FIXTURE/unitlimits/sysstub" unit
  _runlock_fixture "$root" "$repo" tier2
  mkdir -p "$home" "$stub"
  printf '#!/usr/bin/env bash\n[[ "$*" == *show* ]] && printf "LoadState=loaded\\nUnitFileState=enabled\\nActiveState=active\\nNextElapseUSecRealtime=Sun 2026-08-30 03:17:00 EDT\\n"\nexit 0\n' > "$stub/systemctl"
  printf '#!/usr/bin/env bash\nprintf "yes\\n"\n' > "$stub/loginctl"
  chmod +x "$stub/systemctl" "$stub/loginctl"
  XDG_CONFIG_HOME="$home/.config" PATH="$stub:$PATH" MEUTE_MANIFEST="$root/repos.yaml" \
    "$root/bin/meute" install-timers >/dev/null 2>&1
  for unit in daily weekly; do
    local text; text="$(cat "$home/.config/systemd/user/meute-${unit}.service" 2>/dev/null)"
    has "unit limits: ${unit} service has Nice=10"                 "$text" "Nice=10"
    has "unit limits: ${unit} service has IOSchedulingClass=idle"  "$text" "IOSchedulingClass=idle"
    has "unit limits: ${unit} service has CPUWeight=20"            "$text" "CPUWeight=20"
    has "unit limits: ${unit} service has TimeoutStartSec = max timeout + 600" "$text" "TimeoutStartSec=660"
  done

  # doctor: an installed unit without the directives is flagged; one with them is not.
  local old="$FIXTURE/unitlimits/old"; mkdir -p "$old"
  printf '[Service]\nType=oneshot\nExecStart=/x/run.sh daily\n' > "$old/meute-daily.service"
  cp "$home/.config/systemd/user/meute-weekly.service" "$old/meute-weekly.service"
  local out
  out="$(bash -c 'source "$1"; d_warn() { printf "WARN %s\n" "$*"; }; doctor_unit_limits "$2"' _ "$REPO/bin/meute" "$old" 2>&1)"
  has   "unit limits: doctor warns on a unit lacking them"   "$out" "meute-daily.service"
  has   "unit limits: ...and says to re-run install-timers"  "$out" "re-run install-timers"
  hasnt "unit limits: ...but not on a current unit"          "$out" "meute-weekly.service"
}

# P0.8 (R13). A staged plan that fails validation used to
# make the runner die before the manifest queue was read, so nothing ran until
# someone deleted the file. Now the file is renamed aside, one code=plan-invalid
# line says so, and the same fire runs the manifest's next item.
test_plan_quarantine() {
  local root="$FIXTURE/planq" repo="$FIXTURE/planq/git-lk" log out rc before bad
  _runlock_fixture "$root" "$repo" tier2
  log="$root/state/log"
  local fire=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily )

  for bad in '{"version":2}' '{broken'; do
    rm -f "$root"/state/plan-queue.invalid-*.json "$root/state/plan-queue.json"
    printf '%s\n' "$bad" > "$root/state/plan-queue.json"
    : > "$log"
    rc=0; out="$("${fire[@]}" 2>&1)" || rc=$?
    is  "plan quarantine: ${bad}: the fire exits 0"                    "$rc" "0"
    has "plan quarantine: ${bad}: the manifest item ran (status=ok)"   "$(tail -1 "$log")" $'\tstatus=ok'
    is  "plan quarantine: ${bad}: one plan-invalid error line"         "$(grep -c $'\tstatus=error\t.*code=plan-invalid' "$log")" "1"
    is  "plan quarantine: ${bad}: the staged file is gone"             "$([[ -e "$root/state/plan-queue.json" ]] && echo present || echo gone)" "gone"
    is  "plan quarantine: ${bad}: ...renamed aside, content intact"    "$(cat "$root"/state/plan-queue.invalid-*.json 2>/dev/null)" "$bad"
  done

  # The next fire is plain: nothing staged, one line, no second quarantine.
  : > "$log"
  rc=0; "${fire[@]}" >/dev/null 2>&1 || rc=$?
  is  "plan quarantine: the next fire is unaffected"  "$(grep -c 'plan-invalid' "$log")" "0"
  is  "plan quarantine: ...and exits 0"              "$rc" "0"
}

# P0.8 review: only a bad plan is quarantined. A manifest that breaks while a
# valid plan is staged (here the agent run corrupts it, so validate has already
# passed and the post-run plan-queue call is the first to see it) must leave
# the plan where it is; the fire dies on the manifest as it always did.
test_plan_quarantine_manifest_broken() {
  local root="$FIXTURE/planqm" repo="$FIXTURE/planqm/git-lk" log rc
  _runlock_fixture "$root" "$repo" tier2
  log="$root/state/log"
  printf '{"version":1,"scan":"%s","allow_web":false,"entries":[{"name":"plan-001-x","path":"%s","task":"t"}]}\n' \
    "$root" "$repo" > "$root/state/plan-queue.json"
  local plan; plan="$(cat "$root/state/plan-queue.json")"
  is "plan quarantine (manifest broken): the staged plan is valid" \
    "$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.yaml" "$root/state/plan-queue.json" daily >/dev/null 2>&1; echo $?)" "0"
  # The stub agent breaks the manifest while it runs.
  sed -i "2i printf 'version: [\\\\n' > '$root/repos.yaml'" "$root/stub/claude"
  local out; rc=0; out="$(env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily 2>&1)" || rc=$?
  is  "plan quarantine (manifest broken): the manifest really broke" \
    "$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" validate "$root/repos.yaml" >/dev/null 2>&1; echo $?)" "1"
  is  "plan quarantine (manifest broken): the fire fails on the manifest" "$(( rc != 0 ))" "1"
  has "plan quarantine (manifest broken): ...saying so on stderr" "$out" "meute: manifest failed validation"
  is  "plan quarantine (manifest broken): the plan stays in place" "$(cat "$root/state/plan-queue.json" 2>/dev/null)" "$plan"
  is  "plan quarantine (manifest broken): nothing is quarantined" \
    "$(compgen -G "$root/state/plan-queue.invalid-*" || echo none)" "none"
  is  "plan quarantine (manifest broken): no plan-invalid line" "$(grep -c 'plan-invalid' "$log")" "0"
}

# P1.1 (R6, owner decision D2): an expiring policy override in state/, read
# after the manifest, so the floor can be lowered for a night without editing
# the manifest and remembering to put it back.
test_policy_override() {
  local root="$FIXTURE/polov" repo="$FIXTURE/polov/git-lk" now out rc
  _runlock_fixture "$root" "$repo" tier2
  now="$(date +%s)"
  local M=( env MEUTE_MANIFEST="$root/repos.yaml" MEUTE_NOW="$now" )
  local R=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=20 )
  local mtime; mtime="$(stat -c '%Y.%y' "$root/repos.yaml")"
  local sum; sum="$(sha256sum < "$root/repos.yaml")"

  out="$("${R[@]}" "$root/bin/run.sh" daily 2>&1)"
  has "policy override: with none set, quota 20% is below the floor of 30" "$out\n$(tail -1 "$root/state/log")" "below floor 30%"

  out="$("${M[@]}" "$root/bin/meute" policy set quota_floor_percent=1 --for 8h -r "night run" 2>&1)"; rc=$?
  is  "policy set: exits 0" "$rc" "0"
  has "policy set: says when it expires" "$out" "until"
  out="$("${R[@]}" MEUTE_NOW="$now" "$root/bin/run.sh" daily 2>&1)"
  has "policy override: an override in force changes the gate" "$(tail -1 "$root/state/log")" "status=ok"
  has "policy override: the run line says policy=override" "$(tail -1 "$root/state/log")" "policy=override"
  is  "policy override: the manifest was not edited (content)" "$(sha256sum < "$root/repos.yaml")" "$sum"
  is  "policy override: the manifest was not edited (mtime)" "$(stat -c '%Y.%y' "$root/repos.yaml")" "$mtime"

  out="$("${M[@]}" "$root/bin/meute" policy show 2>&1)"
  has "policy show: names the key and value" "$out" "quota_floor_percent=1"
  has "policy show: names the reason"        "$out" "night run"
  out="$(env MEUTE_NOW="$now" MEUTE_MANIFEST="$root/repos.yaml" MEUTE_QUOTA_STUB=100 PATH="$root/stub:$PATH" "$root/bin/meute" status 2>&1)"
  has "status: says a policy override is in force" "$out" "POLICY OVERRIDE"
  out="$(env MEUTE_NOW="$now" MEUTE_MANIFEST="$root/repos.yaml" "$root/bin/meute" doctor 2>&1)"
  has "doctor: says a policy override is in force" "$out" "policy override"

  # Expired: ignored without anyone clearing it.
  out="$("${R[@]}" MEUTE_NOW=$(( now + 9 * 3600 )) "$root/bin/run.sh" daily 2>&1)"
  has   "policy override: an expired row is ignored" "$(tail -1 "$root/state/log")" "below floor 30%"
  hasnt "policy override: ...and the line is not marked" "$(tail -1 "$root/state/log")" "policy=override"
  out="$(env MEUTE_MANIFEST="$root/repos.yaml" MEUTE_NOW=$(( now + 9 * 3600 )) "$root/bin/meute" policy show 2>&1)"
  has "policy show: an expired override reads as none" "$out" "no policy override"

  # Refused at set time, leaving what was there alone.
  local before; before="$(cat "$root/state/policy-override")"
  "${M[@]}" "$root/bin/meute" policy set quota_floor_percent=101 --for 1h >/dev/null 2>&1; rc=$?
  [[ "$rc" != 0 ]] && ok "policy set: an out-of-range value is refused" || bad "policy set: an out-of-range value is refused" "exit 0"
  "${M[@]}" "$root/bin/meute" policy set weekly_cost_usd=0 --for 1h >/dev/null 2>&1; rc=$?
  [[ "$rc" != 0 ]] && ok "policy set: a non-positive cost is refused" || bad "policy set: a non-positive cost is refused" "exit 0"
  "${M[@]}" "$root/bin/meute" policy set quota_floor_percent=5 --for 8d >/dev/null 2>&1; rc=$?
  [[ "$rc" != 0 ]] && ok "policy set: more than 7 days is refused" || bad "policy set: more than 7 days is refused" "exit 0"
  "${M[@]}" "$root/bin/meute" policy set quota_floor_percent=5 >/dev/null 2>&1; rc=$?
  [[ "$rc" != 0 ]] && ok "policy set: an expiry is mandatory" || bad "policy set: an expiry is mandatory" "exit 0"
  "${M[@]}" "$root/bin/meute" policy set branch_prefix=x --for 1h >/dev/null 2>&1; rc=$?
  [[ "$rc" != 0 ]] && ok "policy set: a key that is not overridable is refused" || bad "policy set: a key that is not overridable is refused" "exit 0"
  # A non-finite cost reads as no ceiling downstream (jq turns NaN into null).
  local bad_cost
  for bad_cost in nan inf -inf 1e999; do
    "${M[@]}" "$root/bin/meute" policy set weekly_cost_usd="$bad_cost" --for 1h >/dev/null 2>&1; rc=$?
    [[ "$rc" != 0 ]] && ok "policy set: a non-finite cost ($bad_cost) is refused" || bad "policy set: a non-finite cost ($bad_cost) is refused" "exit 0"
  done
  is "policy set: refusals left the file alone" "$(cat "$root/state/policy-override")" "$before"

  # One invocation: the env var, nothing written.
  rm -f "$root/state/policy-override"
  out="$("${R[@]}" MEUTE_QUOTA_FLOOR=1 "$root/bin/run.sh" daily 2>&1)"
  has "policy override: MEUTE_QUOTA_FLOOR lowers the gate for one run" "$(tail -1 "$root/state/log")" "status=ok"
  has "policy override: ...and marks the line" "$(tail -1 "$root/state/log")" "policy=override"
  [[ ! -e "$root/state/policy-override" ]] && ok "policy override: the env var writes nothing" \
    || bad "policy override: the env var writes nothing" "state/policy-override exists"

  # An override that sets the other ceiling replaces the manifest's, never
  # trips the one-ceiling rule. The manifest carries weekly_runs=1, already
  # spent by the runs above, so only the cost ceiling lets this run through.
  cp "$root/repos.yaml" "$root/repos.yaml.noceiling"
  python3 - "$root/repos.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); d["policy"]["weekly_runs"] = 1
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PY
  out="$("${R[@]}" MEUTE_NOW="$now" MEUTE_QUOTA_FLOOR=1 "$root/bin/run.sh" daily 2>&1)"
  has "policy override: the manifest's weekly_runs=1 is spent before the cost override" \
    "$(tail -1 "$root/state/log")" "ceiling is spent"
  "${M[@]}" "$root/bin/meute" policy set weekly_cost_usd=50 --for 1h >/dev/null 2>&1; rc=$?
  is  "policy set: a cost ceiling over a manifest weekly_runs is accepted" "$rc" "0"
  out="$("${M[@]}" python3 "$root/lib/manifest.py" policy-effective "$root/repos.yaml" "$root/state/policy-override" 2>&1)"
  has "policy-effective: the cost override replaces the manifest's weekly_runs" "$out" '"weekly_runs": null'
  out="$("${R[@]}" MEUTE_NOW="$now" MEUTE_QUOTA_FLOOR=1 "$root/bin/run.sh" daily 2>&1)"
  has   "policy override: a cost ceiling override is accepted" "$(tail -1 "$root/state/log")" "status=ok"
  hasnt "policy override: ...and the manifest's weekly_runs no longer gates" "$(tail -1 "$root/state/log")" "ceiling is spent"
  mv "$root/repos.yaml.noceiling" "$root/repos.yaml"

  # Two separate sets of the two ceilings: the later one evicts the earlier,
  # so the file never holds an incoherent pair and the floor row stays live.
  "${M[@]}" "$root/bin/meute" policy set quota_floor_percent=1 --for 8h >/dev/null 2>&1
  "${M[@]}" "$root/bin/meute" policy set weekly_runs=100 --for 1d >/dev/null 2>&1; rc=$?
  is    "policy set: the other ceiling in a second call is accepted" "$rc" "0"
  hasnt "policy set: ...and evicts the earlier ceiling row" "$(cut -f1 "$root/state/policy-override")" "weekly_cost_usd"
  hasnt "policy show: ...which is no longer listed" "$("${M[@]}" "$root/bin/meute" policy show 2>&1)" "weekly_cost_usd"
  out="$("${R[@]}" MEUTE_NOW="$now" "$root/bin/run.sh" daily 2>&1)"
  has "policy override: the floor row still applies after the ceiling swap" "$(tail -1 "$root/state/log")" "status=ok"
  has "policy override: ...and the line is marked" "$(tail -1 "$root/state/log")" "policy=override"

  # A hand-edited row past the 7-day cap is ignored like an expired one.
  printf 'quota_floor_percent\t1\t%s\thand edit\n' "$(( now + 8 * 86400 ))" > "$root/state/policy-override"
  out="$("${R[@]}" MEUTE_NOW="$now" "$root/bin/run.sh" daily 2>&1)"
  has   "policy override: a row past the 7-day cap is ignored" "$(tail -1 "$root/state/log")" "below floor 30%"
  hasnt "policy override: ...and the line is not marked" "$(tail -1 "$root/state/log")" "policy=override"

  # A hand-edited non-finite cost is skipped like an expired row: the floor row
  # beside it stays live, and `policy show` lists only what the run obeys.
  printf 'quota_floor_percent\t1\t%s\thand edit\nweekly_cost_usd\tnan\t%s\thand edit\n' \
    "$(( now + 3600 ))" "$(( now + 3600 ))" > "$root/state/policy-override"
  out="$("${R[@]}" MEUTE_NOW="$now" "$root/bin/run.sh" daily 2>&1)"
  has   "policy override: a hand-edited nan cost row is skipped, the floor row applies" "$(tail -1 "$root/state/log")" "status=ok"
  has   "policy override: ...and the line is marked" "$(tail -1 "$root/state/log")" "policy=override"
  out="$("${M[@]}" "$root/bin/meute" policy show 2>&1)"
  hasnt "policy show: ...the nan row is not listed" "$out" "weekly_cost_usd"
  has   "policy show: ...the floor row is" "$out" "quota_floor_percent=1"

  # clear
  out="$("${M[@]}" "$root/bin/meute" policy clear 2>&1)"
  [[ ! -e "$root/state/policy-override" ]] && ok "policy clear: removes the file" \
    || bad "policy clear: removes the file" "still there"
  out="$("${R[@]}" "$root/bin/run.sh" daily 2>&1)"
  has "policy clear: the manifest's floor applies again" "$(tail -1 "$root/state/log")" "below floor 30%"
}

# P1.2 (R7, R3 part; owner decision D6): a fire on a host that is overloaded or
# out of disk declines in a fraction of a second, before the lock and before
# any quota probe. Load per CPU is read from MEUTE_LOADAVG (default
# /proc/loadavg) and MEUTE_NCPU (default nproc); free space comes from
# MEUTE_DF (default df).
test_host_gate() {
  local root="$FIXTURE/hostgate" repo="$FIXTURE/hostgate/git-lk" out rc line
  _runlock_fixture "$root" "$repo" tier1
  local R=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=90 MEUTE_NCPU=22 MEUTE_LOADAVG="$root/loadavg" )
  printf '90.00 80.00 70.00 1/100 1\n' > "$root/loadavg"
  printf '#!/bin/sh\nprintf "Filesystem 1M-blocks Used Available Capacity Mounted\\nfake 1000 900 100 90/\\n"\n' > "$root/df-low"
  printf '#!/bin/sh\nprintf "Filesystem 1M-blocks Used Available Capacity Mounted\\nfake 1000 100 900 10/\\n"\n' > "$root/df-ok"
  chmod +x "$root/df-low" "$root/df-ok"

  # load 90 on 22 CPUs is 4.1 per CPU, over the default 2.0
  local start=$SECONDS
  out="$("${R[@]}" "$root/bin/run.sh" daily --strict-exit 2>&1)"; rc=$?
  line="$(tail -1 "$root/state/log")"
  is    "host gate: load 90 on 22 CPUs exits 15 under --strict-exit" "$rc" "15"
  has   "host gate: ...logged as code=load" "$line" "code=load"
  has   "host gate: ...status skipped" "$line" "status=skipped"
  hasnt "host gate: ...nothing ran" "$line" "status=ok"
  (( SECONDS - start <= 2 )) && ok "host gate: ...and it returned within seconds" \
    || bad "host gate: ...and it returned within seconds" "took $(( SECONDS - start ))s"
  [[ ! -e "$root/state/lock-info" ]] && ok "host gate: ...before the lock was taken" \
    || bad "host gate: ...before the lock was taken" "lock-info exists"
  "${R[@]}" "$root/bin/run.sh" daily >/dev/null 2>&1; rc=$?
  is    "host gate: ...exit 0 without --strict-exit, as every skip" "$rc" "0"

  # a forced run obeys the load check too ...
  "${R[@]}" "$root/bin/run.sh" daily --repo lk --task t >/dev/null 2>&1
  has   "host gate: a forced run at load 90 is also declined" "$(tail -1 "$root/state/log")" "code=load"
  # ... unless --ignore-load
  "${R[@]}" "$root/bin/run.sh" daily --repo lk --task t --ignore-load >/dev/null 2>&1
  has   "host gate: --ignore-load lets the forced run through" "$(tail -1 "$root/state/log")" "status=ok"

  # below the threshold: 40 / 22 = 1.8
  printf '40.00 40.00 40.00 1/100 1\n' > "$root/loadavg"
  "${R[@]}" "$root/bin/run.sh" daily >/dev/null 2>&1
  has   "host gate: load 40 on 22 CPUs (1.8 per CPU) runs" "$(tail -1 "$root/state/log")" "status=ok"

  # max_load_per_cpu: 0 disables the gate; a lower value tightens it
  printf '90.00 80.00 70.00 1/100 1\n' > "$root/loadavg"
  sed -i 's/^policy:/policy:\n  max_load_per_cpu: 0/' "$root/repos.yaml"
  "${R[@]}" "$root/bin/run.sh" daily >/dev/null 2>&1
  has   "host gate: max_load_per_cpu: 0 disables the load check" "$(tail -1 "$root/state/log")" "status=ok"
  sed -i 's/max_load_per_cpu: 0/max_load_per_cpu: 1.0/' "$root/repos.yaml"
  printf '30.00 30.00 30.00 1/100 1\n' > "$root/loadavg"
  "${R[@]}" "$root/bin/run.sh" daily >/dev/null 2>&1
  has   "host gate: a manifest max_load_per_cpu of 1.0 declines load 30 on 22 CPUs" "$(tail -1 "$root/state/log")" "code=load"
  sed -i '/max_load_per_cpu/d' "$root/repos.yaml"

  # disk: under min_free_mb (default 512) declines, forced runs obey it
  printf '0.10 0.10 0.10 1/100 1\n' > "$root/loadavg"
  out="$("${R[@]}" MEUTE_DF="$root/df-low" "$root/bin/run.sh" daily --strict-exit 2>&1)"; rc=$?
  is    "host gate: 100 MB free is declined with exit 15" "$rc" "15"
  has   "host gate: ...logged as code=disk" "$(tail -1 "$root/state/log")" "code=disk"
  "${R[@]}" MEUTE_DF="$root/df-low" "$root/bin/run.sh" daily --repo lk --task t --ignore-load >/dev/null 2>&1
  has   "host gate: a forced run with --ignore-load still obeys the disk check" "$(tail -1 "$root/state/log")" "code=disk"
  "${R[@]}" MEUTE_DF="$root/df-ok" "$root/bin/run.sh" daily >/dev/null 2>&1
  has   "host gate: 900 MB free runs" "$(tail -1 "$root/state/log")" "status=ok"
  sed -i 's/^policy:/policy:\n  min_free_mb: 50/' "$root/repos.yaml"
  "${R[@]}" MEUTE_DF="$root/df-low" "$root/bin/run.sh" daily >/dev/null 2>&1
  has   "host gate: min_free_mb: 50 lets 100 MB free run" "$(tail -1 "$root/state/log")" "status=ok"
  sed -i '/min_free_mb/d' "$root/repos.yaml"

  # a df that fails (odd mount, container permissions) is "unknown": the gate
  # passes and the fire runs, it does not die under set -e
  printf '#!/bin/sh\nexit 1\n' > "$root/df-fail"; chmod +x "$root/df-fail"
  out="$("${R[@]}" MEUTE_DF="$root/df-fail" "$root/bin/run.sh" daily --strict-exit 2>&1)"; rc=$?
  is    "host gate: a failing df is unknown, the fire runs (exit 0)" "$rc" "0"
  has   "host gate: ...logged as status=ok" "$(tail -1 "$root/state/log")" "status=ok"
  hasnt "host gate: ...not code=died" "$(tail -1 "$root/state/log")" "code=died"

  # a directory that cannot be written is the same verdict (root ignores modes)
  if [[ "$(id -u)" == 0 ]]; then
    skip "host gate: an unwritable directory is declined" "running as root; chmod cannot block writes"
  else
    mkdir -p "$root/ro"; chmod 555 "$root/ro"
    out="$(MEUTE_ROOT="$REPO" bash -c 'source "$MEUTE_ROOT/lib/hostcheck.sh"; hostcheck_writable "$1"' _ "$root/ro" 2>&1)"; rc=$?
    is  "host gate: hostcheck_writable refuses a read-only directory" "$rc" "1"
    chmod 755 "$root/ro"
    MEUTE_ROOT="$REPO" bash -c 'source "$MEUTE_ROOT/lib/hostcheck.sh"; hostcheck_writable "$1"' _ "$root/ro" >/dev/null 2>&1; rc=$?
    is  "host gate: ...and accepts a writable one" "$rc" "0"
  fi

  # manifest: the default (neither key) validates; bad values are refused
  out="$(validate "$root/repos.yaml" "$root")"
  hasnt "host gate: a manifest with neither key validates" "$out" "policy."
  yaml_edit "$root/repos.yaml" "$root/bad1.yaml" 'd["policy"]["max_load_per_cpu"] = -1'
  has   "host gate: max_load_per_cpu -1 is refused" "$(validate "$root/bad1.yaml" "$root")" "policy.max_load_per_cpu"
  yaml_edit "$root/repos.yaml" "$root/bad2.yaml" 'd["policy"]["max_load_per_cpu"] = True'
  has   "host gate: max_load_per_cpu true is refused" "$(validate "$root/bad2.yaml" "$root")" "policy.max_load_per_cpu"
  yaml_edit "$root/repos.yaml" "$root/bad3.yaml" 'd["policy"]["min_free_mb"] = "lots"'
  has   "host gate: min_free_mb \"lots\" is refused" "$(validate "$root/bad3.yaml" "$root")" "policy.min_free_mb"
  yaml_edit "$root/repos.yaml" "$root/bad4.yaml" 'd["policy"]["min_free_mb"] = -5'
  has   "host gate: min_free_mb -5 is refused" "$(validate "$root/bad4.yaml" "$root")" "policy.min_free_mb"
}

# P1.9 (R14, owner decision D8): a fire that finds what a killed runner left
# behind (its worktree, its scratch branch, its state/tmp/run.<pid>.* directory,
# state/.kv.* strays) clears it under the run lock. Ownership is the PID in the
# name checked against /proc/<pid>/cmdline (MEUTE_PROC overrides /proc), so a
# reused PID does not protect a dead runner's leftovers. `doctor` only lists.
test_startup_sweep() {
  local root="$FIXTURE/sweep" repo="$FIXTURE/sweep/git-lk" out wt="$FIXTURE/sweep/.worktrees"
  _runlock_fixture "$root" "$repo" tier1
  local g=( git -C "$repo" -c user.email=t@t -c user.name=t )
  mkdir -p "$wt" "$root/state/tmp" "$root/proc/4242" "$root/proc/4343"
  printf 'bash\0%s/bin/run.sh\0daily\0' "$root" > "$root/proc/4242/cmdline"   # a live runner
  printf 'sleep\0100\0' > "$root/proc/4343/cmdline"                           # a reused PID
  "${g[@]}" worktree add -q -b meute/dead-empty "$wt/lk-t-2026-01-01.4999991"
  "${g[@]}" worktree add -q -b meute/dead-work  "$wt/lk-t-2026-01-01.4999992"
  git -C "$wt/lk-t-2026-01-01.4999992" -c user.email=t@t -c user.name=t commit -q --allow-empty -m draft
  "${g[@]}" worktree add -q -b meute/live       "$wt/lk-t-2026-01-01.4242"
  "${g[@]}" worktree add -q -b meute/reused     "$wt/lk-t-2026-01-01.4343"
  mkdir -p "$root/state/tmp/run.4999993.AAAAAA" "$root/state/tmp/run.4242.BBBBBB"
  : > "$root/state/.kv.OLD111"; touch -d '2 hours ago' "$root/state/.kv.OLD111"
  : > "$root/state/.kv.NEW111"
  local R=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=90 MEUTE_PROC="$root/proc" )

  # doctor lists, removes nothing
  out="$("${R[@]}" "$root/bin/meute" doctor 2>&1)"
  has "sweep: doctor lists a dead runner's worktree" "$out" "lk-t-2026-01-01.4999991"
  has "sweep: ...and the stale kv file" "$out" ".kv.OLD111"
  [[ -d "$wt/lk-t-2026-01-01.4999991" && -e "$root/state/.kv.OLD111" ]] \
    && ok "sweep: doctor removed nothing" || bad "sweep: doctor removed nothing" "something is gone"

  out="$("${R[@]}" "$root/bin/run.sh" daily 2>&1)"
  [[ ! -e "$wt/lk-t-2026-01-01.4999991" ]] && ok "sweep: a dead runner's worktree is removed" \
    || bad "sweep: a dead runner's worktree is removed" "still there"
  [[ ! -e "$wt/lk-t-2026-01-01.4999992" ]] && ok "sweep: ...also the one whose branch has a commit" \
    || bad "sweep: ...also the one whose branch has a commit" "still there"
  [[ -d "$wt/lk-t-2026-01-01.4242" ]] && ok "sweep: a live runner's worktree stays" \
    || bad "sweep: a live runner's worktree stays" "removed"
  [[ ! -e "$wt/lk-t-2026-01-01.4343" ]] && ok "sweep: a reused PID (cmdline is not run.sh) does not protect it" \
    || bad "sweep: a reused PID (cmdline is not run.sh) does not protect it" "still there"
  git -C "$repo" rev-parse --verify -q refs/heads/meute/dead-empty >/dev/null \
    && bad "sweep: an unmoved scratch branch is deleted" "branch still exists" \
    || ok "sweep: an unmoved scratch branch is deleted"
  git -C "$repo" rev-parse --verify -q refs/heads/meute/dead-work >/dev/null \
    && ok "sweep: a branch with a commit is kept" || bad "sweep: a branch with a commit is kept" "deleted"
  is "sweep: the repository's worktree list is pruned" \
     "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree .*\.4999991$')" "0"
  [[ ! -e "$root/state/tmp/run.4999993.AAAAAA" && -d "$root/state/tmp/run.4242.BBBBBB" ]] \
    && ok "sweep: a dead run's tmp dir goes, a live one stays" \
    || bad "sweep: a dead run's tmp dir goes, a live one stays" "$(ls "$root/state/tmp")"
  [[ ! -e "$root/state/.kv.OLD111" && -e "$root/state/.kv.NEW111" ]] \
    && ok "sweep: .kv strays older than an hour go, a fresh one stays" \
    || bad "sweep: .kv strays older than an hour go, a fresh one stays" "$(ls -A "$root/state")"
  is "sweep: one note per removal" "$(grep -c "sweep: removed" <<< "$out")" "7"
  has "sweep: the fire itself still ran" "$(tail -1 "$root/state/log")" "status=ok"
}

# P1.8 (R8): a fleet that stops silently must be noticed. `meute health`
# prints one line per problem and exits non-zero; with --alert the same text
# goes to policy.alert_cmd on stdin. Owner decision D4: the text names no
# repository, so the fixture's repo is called something greppable.
_health_log() {   # <file> <epoch> <status> [code]
  printf '%s\tweek=x\tslot=daily\tstatus=%s\trepo=zorblax-secret\tcode=%s\tdur=1s\n' \
    "$(date -d "@$2" --iso-8601=seconds)" "$3" "${4:-ok}" >> "$1"
}
test_health() {
  local root="$FIXTURE/health" repo="$FIXTURE/health/git-zorblax" now=1800000000 out rc all=""
  _runlock_fixture "$root" "$repo" tier2
  sed -i 's/name: lk$/name: zorblax-secret/' "$root/repos.yaml"
  local st="$root/hstub" state="$root/state"
  mkdir -p "$st" "$root/proc/4242" "$root/cfg"
  cat > "$st/systemctl" <<'SH'
#!/usr/bin/env bash
[[ "$*" == *show* ]] || exit 0
if [[ "${STUB_TIMER:-armed}" == idle ]]; then printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=inactive\nNextElapseUSecRealtime=\n'
# systemd 258 while the timer's service runs: active/running, no next elapse
elif [[ "$STUB_TIMER" == running ]]; then printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nSubState=running\nNextElapseUSecRealtime=\n'
else printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\nNextElapseUSecRealtime=Sun 2027-01-17 03:17:00 EST\n'; fi
SH
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${STUB_LINGER:-yes}"\n' > "$st/loginctl"
  cat > "$st/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1M-blocks Used Available Capacity Mounted\n/dev/x 100000 1 %s 1%% /\n' "${STUB_DF_FREE:-99999}"
SH
  chmod +x "$st"/*
  printf 'bash\0%s/bin/run.sh\0daily\0' "$root" > "$root/proc/4242/cmdline"
  local H=( env PATH="$st:$PATH" XDG_CONFIG_HOME="$root/cfg" MEUTE_NOW="$now" MEUTE_MANIFEST="$root/repos.yaml"
            MEUTE_DF="$st/df" MEUTE_PROC="$root/proc" )
  _hreset() {
    rm -rf "$state/log" "$state/hold" "$state/lock-info" "$state/rate-limits.json" "$state/policy-override" "$root/.worktrees" "$root/alert.txt" "$state/health-alerted"
    _health_log "$state/log" $(( now - 3600 )) ok
  }
  _hcase() {   # <name> <expected substring> [env...] -- the fixture is already crafted
    local name="$1" want="$2"; shift 2
    out="$("${H[@]}" "$@" "$root/bin/meute" health 2>/dev/null)"; rc=$?
    all+="$out"$'\n'
    [[ "$rc" != 0 ]] && ok "health: $name exits non-zero" || bad "health: $name exits non-zero" "exit 0, output [$out]"
    has "health: $name is reported" "$out" "$want"
  }

  _hreset
  out="$("${H[@]}" "$root/bin/meute" health 2>&1)"; rc=$?
  is "health: a healthy fleet exits 0" "$rc" "0"
  is "health: ...and prints nothing" "$out" ""

  _hreset; : > "$state/log"; _health_log "$state/log" $(( now - 3 * 86400 )) ok
  _hcase "no log line within twice the daily cadence" "no run logged"
  # An empty log is news only once the daily timer has had twice the cadence
  # to fire: right after install-timers it is not.
  local dtimer="$root/cfg/systemd/user/meute-daily.timer"; mkdir -p "${dtimer%/*}"
  _hreset; : > "$state/log"; : > "$dtimer"; touch -d "@$(( now - 3600 ))" "$dtimer"
  out="$("${H[@]}" "$root/bin/meute" health 2>&1)"; rc=$?
  is "health: an empty log an hour after install-timers is not a problem" "$rc:$out" "0:"
  _hreset; : > "$state/log"; touch -d "@$(( now - 3 * 86400 ))" "$dtimer"
  _hcase "an empty log three days after install-timers" "no run has been logged yet"
  rm -f "$dtimer"
  # On a UTC host systemd-analyze prints no "(in UTC)" lines; the weekend gap
  # of a Mon..Fri calendar must still widen the silence threshold.
  python3 - "$root/repos.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); d["policy"]["daily_calendar"] = "Mon..Fri *-*-* 03:17:00"
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PY
  _hreset; : > "$state/log"; _health_log "$state/log" $(( now - 5 * 43200 )) ok
  out="$("${H[@]}" TZ=UTC "$root/bin/meute" health 2>&1)"
  hasnt "health: on a UTC host a Mon..Fri calendar's weekend gap is not silence" "$out" "no run logged"
  python3 - "$root/repos.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); d["policy"].pop("daily_calendar", None)
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PY

  _hreset; : > "$state/log"; _health_log "$state/log" $(( now - 5 * 86400 )) ok
  _health_log "$state/log" $(( now - 600 )) skipped quota-unknown
  _hcase "a last status=ok older than the threshold" "no successful run"
  # Declining by design is not failing: a spent budget, nothing eligible, or a
  # quota under the floor is the fleet working, not a fleet that stopped.
  local benign
  for benign in budget nothing-eligible no-queue quota-floor; do
    _hreset; : > "$state/log"; _health_log "$state/log" $(( now - 5 * 86400 )) ok
    for i in 4 3 2 1; do _health_log "$state/log" $(( now - i * 86400 )) skipped "$benign"; done
    out="$("${H[@]}" "$root/bin/meute" health 2>&1)"; rc=$?
    is "health: days of code=$benign skips are not a failure" "$rc:$out" "0:"
  done

  _hreset; local i; for i in 3 2 1; do _health_log "$state/log" $(( now - i * 60 )) error died; done
  _hcase "three consecutive errors" "3 consecutive"
  _hreset; _health_log "$state/log" $(( now - 120 )) error died; _health_log "$state/log" $(( now - 60 )) error died
  "${H[@]}" "$root/bin/meute" health >/dev/null 2>&1; rc=$?
  is "health: two errors are not yet a problem" "$rc" "0"

  _hreset; printf 'hold\t%s\tauto: provider rate limit — zorblax-secret said 429\n' $(( now + 3600 )) > "$state/hold"
  _hcase "an automatic hold in force" "automatic hold"
  _hreset; printf 'hold\t%s\towner pause\n' $(( now + 3600 )) > "$state/hold"
  "${H[@]}" "$root/bin/meute" health >/dev/null 2>&1; rc=$?
  is "health: a pause the owner set is not a problem" "$rc" "0"
  # Every fire of a long owner pause logs skipped code=hold; those are not
  # failures, during the pause or after it ends, so no hourly false alarm.
  _hlog_paused() {   # <hold reason prefix>: ok 5 days ago, then a hold skip each day
    : > "$state/log"; _health_log "$state/log" $(( now - 5 * 86400 )) ok
    for i in 4 3 2 1; do
      printf '%s\tweek=x\tslot=daily\tstatus=skipped\treason=paused until x — %spause\tcode=hold\tdur=0s\n' \
        "$(date -d "@$(( now - i * 86400 ))" --iso-8601=seconds)" "$1" >> "$state/log"
    done
  }
  _hreset; _hlog_paused ""; printf 'hold\t%s\towner pause\n' $(( now + 3 * 86400 )) > "$state/hold"
  out="$("${H[@]}" "$root/bin/meute" health 2>&1)"; rc=$?
  is "health: a long owner pause raises nothing" "$rc:$out" "0:"
  _hreset; _hlog_paused ""; printf 'hold\t%s\towner pause\n' $(( now - 3600 )) > "$state/hold"
  out="$("${H[@]}" "$root/bin/meute" health 2>&1)"; rc=$?
  is "health: ...nor the hours after it ends, before the next fire" "$rc:$out" "0:"
  _hreset; _hlog_paused "auto: provider rate limit "
  _hcase "days of automatic-hold skips with no success" "no successful run"

  _hreset; printf 'pid=4242 started=%s slot=daily key=zorblax-secret/t\n' "$(date -d "@$(( now - 3000 ))" --iso-8601=seconds)" > "$state/lock-info"
  _hcase "a lock held longer than the largest timeout" "lock held"
  _hreset; printf 'pid=4999991 started=%s slot=daily key=zorblax-secret/t\n' "$(date -d "@$(( now - 3000 ))" --iso-8601=seconds)" > "$state/lock-info"
  "${H[@]}" "$root/bin/meute" health >/dev/null 2>&1; rc=$?
  is "health: lock-info of a dead runner is not a held lock" "$rc" "0"
  _hreset; printf 'pid=4242 started=%s slot=daily key=zorblax-secret/t\n' "$(date -d "@$(( now - 60 ))" --iso-8601=seconds)" > "$state/lock-info"
  "${H[@]}" "$root/bin/meute" health >/dev/null 2>&1; rc=$?
  is "health: a lock held for a minute is not a problem" "$rc" "0"

  _hreset; _hcase "a timer that is not armed" "not armed" STUB_TIMER=idle
  # The hourly health run sees its own timer in SubState=running (empty next
  # elapse); counting that as idle alerted every hour on a healthy fleet.
  _hreset; out="$("${H[@]}" STUB_TIMER=running "$root/bin/meute" health 2>&1)"; rc=$?
  is "health: a timer whose run is in progress counts as armed" "$rc:$out" "0:"
  _hreset; _hcase "linger off" "linger" STUB_LINGER=no
  _hreset; "${H[@]}" STUB_LINGER=unknown "$root/bin/meute" health >/dev/null 2>&1; rc=$?
  is "health: linger unknown (no system bus) is not a problem" "$rc" "0"

  _hreset; _hcase "a state filesystem low on space" "MB free" STUB_DF_FREE=100

  _hreset; mkdir -p "$root/.worktrees/zorblax-secret-t-2026-01-01.4999991"
  _hcase "a leftover of a killed run" "leftover"

  _hreset; printf '{"captured_at": %s}\n' $(( now - 2 * 86400 )) > "$state/rate-limits.json"
  _hcase "a quota snapshot older than a day" "quota snapshot"
  _hreset; printf '{"captured_at": %s}\n' $(( now - 600 )) > "$state/rate-limits.json"
  "${H[@]}" "$root/bin/meute" health >/dev/null 2>&1; rc=$?
  is "health: a fresh quota snapshot is not a problem" "$rc" "0"

  _hreset; printf 'quota_floor_percent\t1\t%s\tnight\n' $(( now + 3600 )) > "$state/policy-override"
  _hcase "a policy override in force" "policy override"

  hasnt "health: no line names a repository (D4)" "$all" "zorblax"

  # alert_cmd: the text arrives on stdin under --alert, and only when there is a problem.
  python3 - "$root/repos.yaml" "$root/alert.txt" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); d["policy"]["alert_cmd"] = f"tee {sys.argv[2]}"
yaml.safe_dump(d, open(sys.argv[1], "w"), sort_keys=False)
PY
  _hreset; "${H[@]}" "$root/bin/meute" health --alert >/dev/null 2>&1; rc=$?
  is "health --alert: healthy exits 0" "$rc" "0"
  [[ ! -e "$root/alert.txt" ]] && ok "health --alert: healthy sends nothing" || bad "health --alert: healthy sends nothing" "$(cat "$root/alert.txt")"
  _hreset; "${H[@]}" STUB_TIMER=idle "$root/bin/meute" health --alert >/dev/null 2>&1
  has "health --alert: alert_cmd receives the text on stdin" "$(cat "$root/alert.txt" 2>/dev/null)" "not armed"
  _hreset; "${H[@]}" "$root/bin/meute" health --alert --failed >/dev/null 2>&1; rc=$?
  has "health --alert --failed: a failed run unit alerts even on a healthy fleet" "$(cat "$root/alert.txt" 2>/dev/null)" "meute run failed"
  [[ "$rc" != 0 ]] && ok "health --alert --failed: exits non-zero" || bad "health --alert --failed: exits non-zero" "exit 0"
  hasnt "health --alert: the alert names no repository (D4)" "$(cat "$root/alert.txt" 2>/dev/null)" "zorblax"
  # One alert per problem, not one an hour: a 24 h automatic hold alerts once.
  _hreset; printf 'hold\t%s\tauto: provider rate limit\n' $(( now + 86400 )) > "$state/hold"
  "${H[@]}" "$root/bin/meute" health --alert >/dev/null 2>&1
  has "health --alert: an automatic hold alerts" "$(cat "$root/alert.txt" 2>/dev/null)" "automatic hold"
  rm -f "$root/alert.txt"
  out="$("${H[@]}" MEUTE_NOW=$(( now + 3600 )) "$root/bin/meute" health --alert 2>/dev/null)"; rc=$?
  [[ ! -e "$root/alert.txt" ]] && ok "health --alert: the same hold an hour later is not sent again" \
    || bad "health --alert: the same hold an hour later is not sent again" "$(cat "$root/alert.txt")"
  [[ "$rc" != 0 ]] && ok "health --alert: ...it is still reported, exit non-zero" || bad "health --alert: ...it is still reported, exit non-zero" "exit 0"
  has "health --alert: ...and printed" "$out" "automatic hold"
  "${H[@]}" MEUTE_NOW=$(( now + 7200 )) STUB_DF_FREE=100 "$root/bin/meute" health --alert >/dev/null 2>&1
  has "health --alert: a new problem beside it is sent" "$(cat "$root/alert.txt" 2>/dev/null)" "MB free"
  rm -f "$root/alert.txt" "$state/hold"
  "${H[@]}" MEUTE_NOW=$(( now + 7200 )) "$root/bin/meute" health --alert >/dev/null 2>&1; rc=$?
  is "health --alert: once healthy again, exit 0" "$rc" "0"
  printf 'hold\t%s\tauto: provider rate limit\n' $(( now + 86400 )) > "$state/hold"
  "${H[@]}" MEUTE_NOW=$(( now + 10800 )) "$root/bin/meute" health --alert >/dev/null 2>&1
  has "health --alert: a problem that cleared and came back alerts again" "$(cat "$root/alert.txt" 2>/dev/null)" "automatic hold"
  rm -f "$state/hold"
  local v
  v="$(python3 - "$root/repos.yaml" "$root/bad.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])); d["policy"]["alert_cmd"] = ["tee", "x"]
yaml.safe_dump(d, open(sys.argv[2], "w"), sort_keys=False)
PY
  MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" validate "$root/bad.yaml" 2>&1)"
  has "health: a non-string alert_cmd is refused by validate" "$v" "policy.alert_cmd"
  "${H[@]}" "$root/bin/meute" policy set alert_cmd=x --for 1h >/dev/null 2>&1; rc=$?
  [[ "$rc" != 0 ]] && ok "health: alert_cmd cannot be set by a policy override" || bad "health: alert_cmd cannot be set by a policy override" "exit 0"
  rm -f "$state/policy-override"

  # install-timers: the hourly health timer, the alert unit, OnFailure on both run units.
  local unit="$root/cfg/systemd/user"
  "${H[@]}" "$root/bin/meute" install-timers >/dev/null 2>&1
  has "install-timers: writes an hourly meute-health.timer" "$(cat "$unit/meute-health.timer" 2>/dev/null)" "OnCalendar=hourly"
  has "install-timers: meute-health.service runs health --alert" "$(cat "$unit/meute-health.service" 2>/dev/null)" "bin/meute health --alert"
  has "install-timers: meute-alert.service runs health --alert --failed" "$(cat "$unit/meute-alert.service" 2>/dev/null)" "bin/meute health --alert --failed"
  for v in daily weekly; do
    is "install-timers: meute-${v}.service has OnFailure in [Unit]" \
       "$(awk '/^\[/{s=$0} /^OnFailure=/{print s "|" $0}' "$unit/meute-${v}.service" 2>/dev/null)" "[Unit]|OnFailure=meute-alert.service"
  done
}
