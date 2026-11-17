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
  # Each its own lens, so no report supersedes another (P1.7 b): this fixture
  # pins the read path and layout, not staleness.
  for i in $(seq 1 50); do
    local repo=alpha; (( i % 2 )) || repo=beta
    printf -- '---\nrepo: %s\ntask: audit-security\ntier: tier2\nlens: l'"$i"'\nstarted: 2026-09-%02dT04:00:00-04:00\nstatus: ok\n---\n\n## Summary\nx\n\n## Findings\n\n### [%s] Title %s one\n- **Anchor:** `src/a.py:%s`\n\n### [LOW] Title %s two\n- **Anchor:** `src/b.py:%s`\n' \
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
              "nothing-eligible 14" "no-queue 14" "load 15" "disk 15" "already-done 16" "ok 0" "failed 1" "died 70"; do
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

  # A hand-edited non-finite cost is skipped (and reported): the floor row
  # beside it stays live, and `policy show` marks it IGNORED.
  printf 'quota_floor_percent\t1\t%s\thand edit\nweekly_cost_usd\tnan\t%s\thand edit\n' \
    "$(( now + 3600 ))" "$(( now + 3600 ))" > "$root/state/policy-override"
  out="$("${R[@]}" MEUTE_NOW="$now" "$root/bin/run.sh" daily 2>&1)"
  has   "policy override: a hand-edited nan cost row is skipped, the floor row applies" "$(tail -1 "$root/state/log")" "status=ok"
  has   "policy override: ...and the line is marked" "$(tail -1 "$root/state/log")" "policy=override"
  out="$("${M[@]}" "$root/bin/meute" policy show 2>&1)"
  has   "policy show: ...the nan row is marked IGNORED" "$out" "weekly_cost_usd=nan  IGNORED"
  has   "policy show: ...the floor row is" "$out" "quota_floor_percent=1"
  # The web inbox shows the floor a run obeys, not the manifest's.
  out="$(MEUTE_ROOT="$root" "${M[@]}" python3 "$root/lib/inbox.py" dump 2>/dev/null | jq -r .status.floor)"
  is    "inbox: the floor shown is the override's" "$out" "1"

  # A hand edit that is not UTF-8, or an until with a non-ASCII digit, is a
  # bad row, skipped and logged: the run goes on and the good row applies.
  printf 'quota_floor_percent\t1\t%s\thand edit\nweekly_runs\t5\t\xc2\xb2\tsuperscript\ncommunity_share\t0.1\t%s\t\xff\xfe\n' \
    "$(( now + 3600 ))" "$(( now + 3600 ))" > "$root/state/policy-override"
  out="$("${R[@]}" MEUTE_NOW="$now" "$root/bin/run.sh" daily 2>&1)"
  hasnt "policy override: a non-UTF-8 or unicode-digit row does not kill the run" "$out" "could not read policy"
  has   "policy override: ...the good floor row still applies" "$(tail -1 "$root/state/log")" "status=ok"
  has   "policy override: ...and the bad rows are reported" "$out" "policy override: skipped"
  # An unreadable override file (a directory) is no override, not a dead run.
  rm -f "$root/state/policy-override"; mkdir "$root/state/policy-override"
  out="$("${R[@]}" MEUTE_NOW="$now" "$root/bin/run.sh" daily 2>&1)"
  hasnt "policy override: an unreadable override file does not kill the run" "$out" "could not read policy"
  has   "policy override: ...the manifest's floor applies" "$(tail -1 "$root/state/log")" "below floor 30%"
  rmdir "$root/state/policy-override"

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
  # The run's temp directory is checked as well as state/: a df that is low
  # only for $RUN_TMP (MEUTE_TMPDIR) still declines the fire as code=disk.
  cat > "$root/df-tmplow" <<EOF
#!/bin/sh
case "\$2" in "$root/tmpdir"/*) a=100 ;; *) a=900 ;; esac
printf 'Filesystem 1M-blocks Used Available Capacity Mounted\nfake 1000 0 %s 10%% /\n' "\$a"
EOF
  chmod +x "$root/df-tmplow"
  out="$("${R[@]}" MEUTE_TMPDIR="$root/tmpdir" MEUTE_DF="$root/df-tmplow" "$root/bin/run.sh" daily --strict-exit 2>&1)"; rc=$?
  line="$(tail -1 "$root/state/log")"
  is    "host gate: low free space only in the run's temp dir exits 15" "$rc" "15"
  has   "host gate: ...logged as code=disk" "$line" "code=disk"
  has   "host gate: ...naming the temp dir" "$line" "$root/tmpdir/run."

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
    # End to end: a state directory that cannot take a new file declines the
    # fire as code=disk, through run.sh, without dying.
    mkdir -p "$root/state/tmp"; chmod 555 "$root/state"
    out="$("${R[@]}" MEUTE_DF="$root/df-ok" "$root/bin/run.sh" daily --strict-exit 2>&1)"; rc=$?
    chmod 755 "$root/state"
    line="$(tail -1 "$root/state/log")"
    is    "host gate: an unwritable state dir declines the fire with exit 15" "$rc" "15"
    has   "host gate: ...logged as code=disk" "$line" "code=disk"
    has   "host gate: ...naming the directory it cannot write" "$line" "cannot write to $root/state"
    hasnt "host gate: ...not code=died" "$line" "code=died"
  fi

  # an unreadable load average is unknown: no error text, the fire runs
  out="$("${R[@]}" MEUTE_LOADAVG="$root/no-such-loadavg" MEUTE_DF="$root/df-ok" "$root/bin/run.sh" daily --strict-exit 2>&1)"; rc=$?
  is    "host gate: a missing load average is unknown, the fire runs (exit 0)" "$rc" "0"
  hasnt "host gate: ...and prints no file error" "$out" "No such file"

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

# Review findings on P1.1: a hand-edited or special override file must never
# stop the fleet or hang it, and one bad row must cost that row only, loudly.
test_policy_override_hardening() {
  local root="$FIXTURE/polovh" repo="$FIXTURE/polovh/git-lk" now out err rc f
  _runlock_fixture "$root" "$repo" tier2
  now="$(date +%s)"; f="$root/state/policy-override"
  local E=( env MEUTE_NOW="$now" python3 "$root/lib/manifest.py" policy-effective "$root/repos.yaml" "$f" )

  # An until of thousands of digits trips Python's int-string limit: that row
  # is skipped and logged, the run's policy is still computed.
  { printf 'quota_floor_percent\t1\t%s\tgood\n' "$(( now + 3600 ))"
    printf 'tier3_max_in_flight\t1\t%s\thuge\n' "$(printf '9%.0s' {1..5000})"; } > "$f"
  out="$("${E[@]}" 2>"$root/err")"; rc=$?; err="$(cat "$root/err")"
  is    "policy override: a 5000-digit until does not fail policy-effective" "$rc" "0"
  hasnt "policy override: ...no traceback" "$err" "Traceback"
  has   "policy override: ...the row is reported skipped" "$err" "skipped"
  is    "policy override: ...the good row still applies" "$(jq -r .quota_floor_percent <<< "$out")" "1"
  out="$(MEUTE_NOW="$now" MEUTE_MANIFEST="$root/repos.yaml" "$root/bin/meute" policy show 2>&1)"
  has   "policy show: a 5000-digit until does not break show" "$out" "quota_floor_percent=1"

  # Special files: a FIFO would block forever, /dev/zero would read forever.
  rm -f "$f"; mkfifo "$f"
  out="$(timeout 10 "${E[@]}" 2>"$root/err")"; rc=$?; err="$(cat "$root/err")"
  is  "policy override: a FIFO does not hang policy-effective" "$rc" "0"
  is  "policy override: ...the manifest's floor applies" "$(jq -r .quota_floor_percent <<< "$out" 2>/dev/null)" "30"
  has "policy override: ...and it says why" "$err" "not a regular file"
  rm -f "$f"; ln -s /dev/zero "$f"
  out="$( (ulimit -v 2000000; timeout 10 "${E[@]}") 2>"$root/err")"; rc=$?; err="$(cat "$root/err")"
  is  "policy override: a symlink to /dev/zero is refused, not read" "$rc" "0"
  is  "policy override: ...the manifest's floor applies" "$(jq -r .quota_floor_percent <<< "$out" 2>/dev/null)" "30"
  has "policy override: ...and it says why" "$err" "not a regular file"
  rm -f "$f"
  { printf 'quota_floor_percent\t1\t%s\tgood\n' "$(( now + 3600 ))"; head -c 1100000 /dev/zero | tr '\0' 'x'; echo; } > "$f"
  out="$("${E[@]}" 2>"$root/err")"; rc=$?; err="$(cat "$root/err")"
  is  "policy override: a file over 1 MiB is refused" "$(jq -r .quota_floor_percent <<< "$out" 2>/dev/null)" "30"
  has "policy override: ...and it says why" "$err" "too large"

  # One row failing the manifest rules costs that row only, and is said so:
  # the tightening rows beside it still apply.
  { printf 'weekly_cost_usd\tabc\t%s\ttypo\n' "$(( now + 3600 ))"
    printf 'tier3_max_in_flight\t1\t%s\ttighten\n' "$(( now + 3600 ))"
    printf 'community_share\t0.05\t%s\ttighten\n' "$(( now + 3600 ))"; } > "$f"
  out="$("${E[@]}" 2>"$root/err")"; err="$(cat "$root/err")"
  is  "policy override: a bad row does not void the tightening rows (tier3)" "$(jq -r .tier3_max_in_flight <<< "$out")" "1"
  is  "policy override: ...(community_share)" "$(jq -r .community_share <<< "$out")" "0.05"
  is  "policy override: ...override lists only the applied keys" "$(jq -c .override <<< "$out")" '["community_share","tier3_max_in_flight"]'
  has "policy override: ...the ignored row is named" "$(jq -c .override_ignored <<< "$out")" "weekly_cost_usd"
  has "policy override: ...and reported on stderr" "$err" "weekly_cost_usd"
  out="$(env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 MEUTE_NOW="$now" "$root/bin/run.sh" daily 2>&1)"
  has "policy override: the run line names the ignored row" "$(tail -1 "$root/state/log")" "policy_ignored=weekly_cost_usd"
  has "policy override: ...and is still marked overridden" "$(tail -1 "$root/state/log")" "policy=override"
  out="$(MEUTE_NOW="$now" MEUTE_MANIFEST="$root/repos.yaml" "$root/bin/meute" policy show 2>&1)"
  has "policy show: marks the ignored row" "$out" "weekly_cost_usd=abc  IGNORED"
  has "policy show: ...and lists the applied ones" "$out" "tier3_max_in_flight=1"
  # A tightening cost ceiling survives a bad row beside it.
  { printf 'community_share\tabc\t%s\ttypo\n' "$(( now + 3600 ))"
    printf 'weekly_cost_usd\t5\t%s\ttighten\n' "$(( now + 3600 ))"; } > "$f"
  is  "policy override: a tightening cost ceiling survives a bad row" "$(jq -r .weekly_cost_usd <<< "$("${E[@]}" 2>/dev/null)")" "5"
  # Both ceilings by hand: the first applies, the second is ignored.
  { printf 'weekly_runs\t5\t%s\tx\n' "$(( now + 3600 ))"
    printf 'weekly_cost_usd\t10\t%s\ty\n' "$(( now + 3600 ))"; } > "$f"
  out="$("${E[@]}" 2>/dev/null)"
  is  "policy override: two hand-edited ceilings: the first applies" "$(jq -r .weekly_runs <<< "$out")" "5"
  has "policy override: ...the second is ignored" "$(jq -c .override_ignored <<< "$out")" "weekly_cost_usd"

  # An invalid MEUTE_QUOTA_FLOOR is one ignored value, not every file row.
  { printf 'quota_floor_percent\t1\t%s\tnight\n' "$(( now + 3600 ))"
    printf 'tier3_max_in_flight\t1\t%s\ttighten\n' "$(( now + 3600 ))"; } > "$f"
  out="$(MEUTE_QUOTA_FLOOR=abc "${E[@]}" 2>/dev/null)"
  is  "policy override: a bad MEUTE_QUOTA_FLOOR keeps the file's floor" "$(jq -r .quota_floor_percent <<< "$out")" "1"
  is  "policy override: ...and the file's other rows" "$(jq -r .tier3_max_in_flight <<< "$out")" "1"
  has "policy override: ...and is named as ignored" "$(jq -c .override_ignored <<< "$out")" "MEUTE_QUOTA_FLOOR"

  is "gitignore: state/policy-override is ignored" \
     "$(git -C "$REPO" check-ignore -q -- state/policy-override; echo $?)" "0"
  rm -f "$f" "$root/err"
}

# A bad row in a hand-edited override must never be a silent revert to the
# looser manifest value: a short row, a nan/inf, and a later bad duplicate are
# each reported, and an earlier valid row for the key is kept.
test_policy_override_bad_rows() {
  local root="$FIXTURE/polovrows" repo="$FIXTURE/polovrows/git-lk" now out err f
  _runlock_fixture "$root" "$repo" tier2
  now="$(date +%s)"; f="$root/state/policy-override"
  local E=( env MEUTE_NOW="$now" python3 "$root/lib/manifest.py" policy-effective "$root/repos.yaml" "$f" )
  local fut="$(( now + 3600 ))"

  # (1) fewer than 3 fields: no until.
  printf 'tier3_max_in_flight\t1\n' > "$f"
  out="$("${E[@]}" 2>"$root/err")"; err="$(cat "$root/err")"
  has "policy override: a row without an until is reported on stderr" "$err" "tier3_max_in_flight"
  has "policy override: ...listed in override_ignored" "$(jq -c .override_ignored <<< "$out")" "tier3_max_in_flight"
  out="$(MEUTE_NOW="$now" MEUTE_MANIFEST="$root/repos.yaml" "$root/bin/meute" policy show 2>&1)"
  has "policy show: ...marks it IGNORED" "$out" "tier3_max_in_flight=1  IGNORED"
  env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 MEUTE_NOW="$now" "$root/bin/run.sh" daily >/dev/null 2>&1
  has "policy override: ...and the run line names it" "$(tail -1 "$root/state/log")" "policy_ignored=tier3_max_in_flight"

  # (2) nan / inf.
  for bad in nan inf; do
    printf 'community_share\t%s\t%s\tx\n' "$bad" "$fut" > "$f"
    out="$("${E[@]}" 2>"$root/err")"; err="$(cat "$root/err")"
    has "policy override: a $bad value is reported on stderr" "$err" "community_share"
    has "policy override: ...listed in override_ignored" "$(jq -c .override_ignored <<< "$out")" "community_share"
    out="$(MEUTE_NOW="$now" MEUTE_MANIFEST="$root/repos.yaml" "$root/bin/meute" policy show 2>&1)"
    has "policy show: ...a $bad row is marked IGNORED" "$out" "community_share=$bad  IGNORED"
  done

  # (3) an earlier valid tightening row survives a later bad duplicate.
  { printf 'tier3_max_in_flight\t1\t%s\ttighten\n' "$fut"
    printf 'tier3_max_in_flight\tabc\t%s\ttypo\n' "$fut"; } > "$f"
  out="$("${E[@]}" 2>"$root/err")"; err="$(cat "$root/err")"
  is  "policy override: a later bad duplicate does not shadow the valid row" "$(jq -r .tier3_max_in_flight <<< "$out")" "1"
  has "policy override: ...the bad duplicate is reported" "$(jq -c .override_ignored <<< "$out")" "tier3_max_in_flight"
  has "policy override: ...on stderr too" "$err" "tier3_max_in_flight"
  is  "policy override: ...and the key still counts as applied" "$(jq -c .override <<< "$out")" '["tier3_max_in_flight"]'
  out="$(MEUTE_NOW="$now" MEUTE_MANIFEST="$root/repos.yaml" "$root/bin/meute" policy show 2>&1)"
  has "policy show: ...the bad duplicate row is marked IGNORED" "$out" "tier3_max_in_flight=abc  IGNORED"
  hasnt "policy show: ...and is not listed as applied" "$out" "tier3_max_in_flight=abc  until"
  # A later valid duplicate still wins.
  { printf 'tier3_max_in_flight\t1\t%s\ta\n' "$fut"
    printf 'tier3_max_in_flight\t2\t%s\tb\n' "$fut"; } > "$f"
  is  "policy override: a later valid duplicate still wins" "$(jq -r .tier3_max_in_flight <<< "$("${E[@]}" 2>/dev/null)")" "2"
  rm -f "$f" "$root/err"
}

# P2.4 (R21): privacy on a shared host. Credentials in a report or a log line
# are redacted before they reach disk; files meute creates are owner-only;
# doctor names loose permissions and credential-bearing remotes (by repo name
# only, never the URL).
_P24_SECRET="hunter2-p24"
_P24_TOKEN="ghp_$(printf 'Z%.0s' {1..36})"
_P24_HEX="0123456789abcdef0123456789abcdef01234567"
_P24_AZ="abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnop"

test_p24_redact() {
  local red="$REPO/lib/redact.py" out long
  out="$(printf 'clone https://alice:%s@git.example.com/x.git with %s\n' "$_P24_SECRET" "$_P24_TOKEN" \
         | python3 "$red" 2>&1)"
  hasnt "p2.4 redact: a URL password is removed"      "$out" "$_P24_SECRET"
  hasnt "p2.4 redact: a GitHub token is removed"      "$out" "$_P24_TOKEN"
  has   "p2.4 redact: ...the host is kept for triage" "$out" "@git.example.com/x.git"
  out="$(printf 'sk-ant-api03-%s and glpat-%s and xoxb-1-%s\n' "$(printf 'q%.0s' {1..30})" \
         "$(printf 'r%.0s' {1..20})" "$(printf 's%.0s' {1..20})" | python3 "$red")"
  hasnt "p2.4 redact: an Anthropic key is removed" "$out" "qqqqqqqqqq"
  hasnt "p2.4 redact: a GitLab token is removed"   "$out" "rrrrrrrrrr"
  hasnt "p2.4 redact: a Slack token is removed"    "$out" "ssssssssss"
  is    "p2.4 redact: ordinary text passes unchanged" \
        "$(printf 'see https://example.com/a@b and task-sk-1\n' | python3 "$red")" \
        "see https://example.com/a@b and task-sk-1"
  # A token used as the bare username (legacy 40-hex GitHub PAT, Azure DevOps,
  # Bitbucket) is a credential too; a short username such as git@ is not.
  out="$(printf 'https://%s@github.com/o/x.git and https://%s@dev.azure.com/o/p\n' "$_P24_HEX" "$_P24_AZ" \
         | python3 "$red")"
  hasnt "p2.4 redact: a 40-hex token as the URL username is removed" "$out" "$_P24_HEX"
  hasnt "p2.4 redact: an opaque token as the URL username is removed" "$out" "$_P24_AZ"
  has   "p2.4 redact: ...the host is kept"                            "$out" "@github.com/o/x.git"
  is    "p2.4 redact: a short URL username is left alone" \
        "$(printf 'ssh://git@github.com/o/x.git\n' | python3 "$red")" "ssh://git@github.com/o/x.git"
  # The password runs to the last @ of the authority, so an unencoded @ in it
  # does not leave its tail behind.
  hasnt "p2.4 redact: a password containing @ is removed whole" \
        "$(printf 'https://u:p@ss-tail-p24@github.com/x\n' | python3 "$red")" "ss-tail-p24"
  # ...but stops at a query or fragment, so an @ there does not swallow the host.
  has   "p2.4 redact: a password stops before ? and #" \
        "$(printf 'https://u:pw@host?a=b@c\n' | python3 "$red")" "@host?a=b@c"
  out="$(bash -c 'source "$1"; engine_detail_clean "$2"' _ "$REPO/lib/engines.sh" \
         "api 401: https://bob:${_P24_SECRET}@h.example/x")"
  hasnt "p2.4 detail: engine_detail_clean redacts"       "$out" "$_P24_SECRET"
  has   "p2.4 detail: ...and keeps the rest of the line" "$out" "api 401: https://bob:"
  # The redaction runs before the 300-character cut, so a token the cut
  # would split is still recognised whole.
  long="$(printf 'x%.0s' {1..280}) ${_P24_TOKEN}"
  out="$(bash -c 'source "$1"; engine_detail_clean "$2"' _ "$REPO/lib/engines.sh" "$long")"
  hasnt "p2.4 detail: a token straddling the cut is still redacted" "$out" "ZZZZZZZZ"
}

test_p24_report_and_umask() {
  local root="$FIXTURE/p24" repo="$FIXTURE/p24/git-lk" out report
  _runlock_fixture "$root" "$repo" tier2
  cat > "$root/stub/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
jq -n '{is_error:false,result:"## Summary\nremote is https://alice:${_P24_SECRET}@git.example.com/x.git token ${_P24_TOKEN}",total_cost_usd:0.01,num_turns:1}'
STUB
  out="$( (umask 022; env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily --repo lk --task t) 2>&1)"
  has "p2.4 report: the fixture run succeeds" "$out" "status=ok"
  report="$(find "$root/reports" -name '*.md' -type f | head -1)"
  [[ -n "$report" ]] && ok "p2.4 report: a report was written" || bad "p2.4 report: a report was written" "none under reports/"
  hasnt "p2.4 report: write_report redacts a URL password" "$(cat "$report" 2>/dev/null)" "$_P24_SECRET"
  hasnt "p2.4 report: write_report redacts a token"        "$(cat "$report" 2>/dev/null)" "$_P24_TOKEN"
  has   "p2.4 report: ...and keeps the report body"        "$(cat "$report" 2>/dev/null)" "## Summary"
  is "p2.4 umask: run.sh writes the report owner-only" "$(stat -c %a "$report" 2>/dev/null)" "600"
  is "p2.4 umask: run.sh writes state/log owner-only"  "$(stat -c %a "$root/state/log" 2>/dev/null)" "600"
  # mktemp is 0600 whatever the umask, so bin/meute is checked on a directory
  # it creates: doctor makes .worktrees/ when it is missing.
  rm -rf "$root/.worktrees"
  (umask 022; "$root/bin/meute" doctor >/dev/null 2>&1)
  is "p2.4 umask: bin/meute creates directories owner-only" "$(stat -c %a "$root/.worktrees" 2>/dev/null)" "700"
}

test_p24_doctor() {
  local out st rp
  st="$(stat -c %a "$FIXTURE/state")"; rp="$(stat -c %a "$FIXTURE/reports")"
  chmod 755 "$FIXTURE/state"; chmod 700 "$FIXTURE/reports"
  out="$(meute doctor 2>&1)"
  has   "p2.4 doctor: a world-readable state/ is warned about" "$out" "state/ is readable by group or others"
  hasnt "p2.4 doctor: ...an owner-only reports/ is not"        "$out" "reports/ is readable by group or others"
  chmod 700 "$FIXTURE/state"
  out="$(meute doctor 2>&1)"
  hasnt "p2.4 doctor: an owner-only state/ is not warned about" "$out" "state/ is readable by group or others"
  chmod 750 "$FIXTURE/state"
  has   "p2.4 doctor: a group-readable state/ is warned about" "$(meute doctor 2>&1)" "state/ is readable by group or others"
  local m
  for m in 711 701 710 720 702 722; do
    chmod "$m" "$FIXTURE/state"
    has "p2.4 doctor: a ${m} state/ is warned about" "$(meute doctor 2>&1)" "state/ is readable by group or others"
  done
  chmod 700 "$FIXTURE/state"
  hasnt "p2.4 doctor: a 700 state/ is not warned about" "$(meute doctor 2>&1)" "state/ is readable by group or others"
  hasnt "p2.4 doctor: clean remotes raise no credential warning" "$out" "credentials embedded"
  git -C "$FIXTURE/git-alpha" remote add p24 "https://alice:${_P24_SECRET}@git.example.com/a.git"
  git -C "$FIXTURE/git-alpha" remote set-url --push p24 "https://alice:${_P24_SECRET}@git.example.com/a.git"
  out="$(meute doctor 2>&1)"
  has   "p2.4 doctor: a credential in a remote URL is reported" "$out" "alpha: a remote URL has credentials embedded"
  hasnt "p2.4 doctor: ...without printing the secret"           "$out" "$_P24_SECRET"
  hasnt "p2.4 doctor: ...or the URL"                            "$out" "git.example.com"
  hasnt "p2.4 doctor: ...and only for that repository"          "$out" "beta: a remote URL has credentials embedded"
  git -C "$FIXTURE/git-alpha" remote remove p24
  # Each key is checked on its own: a credential in url alone, then in
  # pushurl alone, is still found.
  git -C "$FIXTURE/git-alpha" remote add p24 "https://alice:${_P24_SECRET}@git.example.com/a.git"
  git -C "$FIXTURE/git-alpha" remote set-url --push p24 "https://git.example.com/a.git"
  has "p2.4 doctor: a credential in url alone is reported" "$(meute doctor 2>&1)" "alpha: a remote URL has credentials embedded"
  git -C "$FIXTURE/git-alpha" remote set-url p24 "https://git.example.com/a.git"
  git -C "$FIXTURE/git-alpha" remote set-url --push p24 "https://alice:${_P24_SECRET}@git.example.com/a.git"
  has "p2.4 doctor: a credential in pushurl alone is reported" "$(meute doctor 2>&1)" "alpha: a remote URL has credentials embedded"
  git -C "$FIXTURE/git-alpha" remote remove p24
  git -C "$FIXTURE/git-alpha" remote add p24 "https://${_P24_HEX}@github.com/o/a.git"
  out="$(meute doctor 2>&1)"
  has   "p2.4 doctor: a token as the URL username is reported" "$out" "alpha: a remote URL has credentials embedded"
  hasnt "p2.4 doctor: ...without printing the token"           "$out" "$_P24_HEX"
  git -C "$FIXTURE/git-alpha" remote remove p24
  chmod "$st" "$FIXTURE/state"; chmod "$rp" "$FIXTURE/reports"
}

# The credential check fails closed: when it cannot look, it says so instead
# of reporting every repository clean.
test_p24_doctor_fail_closed() {
  local out cfg="$FIXTURE/git-alpha/.git/config" saved
  out="$(env MEUTE_ROOT="$FIXTURE" MANIFEST_PY=/nonexistent MANIFEST="$FIXTURE/repos.yaml" \
         bash -c 'source "$1/lib/doctor.sh"; source "$1/lib/privacy.sh"; doctor_privacy' _ "$REPO" 2>&1)"
  has   "p2.4 doctor: an unlistable manifest is warned about"   "$out" "could not list enrolled repositories"
  hasnt "p2.4 doctor: ...and is not reported clean"             "$out" "no enrolled repository has a credential"
  saved="$(cat "$cfg")"
  printf '[[[ not a config\n' >> "$cfg"
  out="$(meute doctor 2>&1)"
  printf '%s\n' "$saved" > "$cfg"
  has   "p2.4 doctor: an unreadable git config is warned about" "$out" "alpha: could not read git config"
  hasnt "p2.4 doctor: ...and is not reported clean"             "$out" "no enrolled repository has a credential"
}

# P2.3 (R16): the gate must know how old the pool reading is. A snapshot is
# only as true as its age; policy.quota_max_age_hours turns "old" into
# code=quota-unknown, and `status` says which facts are measured.
_quota_age_snapshot() {
  # $1 root, $2 age in seconds. A window that resets far in the future.
  printf '{"captured_at":%s,"five_hour":{"used_percentage":10,"resets_at":9999999999}}' \
    "$(( $(date +%s) - $2 ))" > "$1/state/rate-limits.json"
}
test_p23_quota_age() {
  local root="$FIXTURE/p23" repo="$FIXTURE/p23/git-lk" out log rc age
  _runlock_fixture "$root" "$repo" tier2
  log="$root/state/log"

  # bin/quota.sh --age: seconds since the snapshot, "-" when the source has none.
  _quota_age_snapshot "$root" 7200
  age="$(MEUTE_ROOT="$root" "$root/bin/quota.sh" --engine claude --age)"
  is "p2.3 quota.sh --age: reports the snapshot age in seconds" "$(( age >= 7200 && age < 7300 ))" "1"
  is "p2.3 quota.sh --with-source: output shape is unchanged" \
     "$(MEUTE_ROOT="$root" "$root/bin/quota.sh" --engine claude --with-source)" "90 quota-subscription.sh"
  rm "$root/state/rate-limits.json"
  is "p2.3 quota.sh --age: a stub has no age" \
     "$(MEUTE_ROOT="$root" MEUTE_QUOTA_STUB=100 "$root/bin/quota.sh" --engine claude --age)" "-"

  # Default (unset) keeps today's behaviour, and the run line records the age.
  _quota_age_snapshot "$root" 7200
  out="$(env PATH="$root/stub:$PATH" "$root/bin/run.sh" daily 2>&1)" || true
  has "p2.3 unset max age: an old snapshot still runs" "$(tail -1 "$log")" "status=ok"
  has "p2.3 the run line carries quota_age=" "$(tail -1 "$log")" "quota_age=7"

  # Set: an older snapshot is quota-unknown; a fresh one runs.
  sed -i 's/^  quota_floor_percent: 30/&\n  quota_max_age_hours: 1/' "$root/repos.yaml"
  rc=0; out="$(env PATH="$root/stub:$PATH" "$root/bin/run.sh" daily 2>&1)" || rc=$?
  has "p2.3 max age 1h, snapshot 2h old: declined as quota-unknown" "$(tail -1 "$log")" "code=quota-unknown"
  has "p2.3 ...and the log says it was stale" "$(tail -1 "$log")" "stale"
  _quota_age_snapshot "$root" 60
  out="$(env PATH="$root/stub:$PATH" "$root/bin/run.sh" daily 2>&1)" || true
  has "p2.3 max age 1h, snapshot 1m old: runs" "$(tail -1 "$log")" "status=ok"

  # A captured_at in the future must not count as fresh forever.
  _quota_age_snapshot "$root" -3600
  is "p2.3 quota.sh --age: a snapshot from the future is unknown, not 0s" \
     "$(MEUTE_ROOT="$root" "$root/bin/quota.sh" --engine claude --age)" "unknown"
  out="$(env PATH="$root/stub:$PATH" "$root/bin/run.sh" daily 2>&1)" || true
  has "p2.3 max age 1h, snapshot dated 1h ahead: declined as quota-unknown" "$(tail -1 "$log")" "code=quota-unknown"
  _quota_age_snapshot "$root" -30
  is "p2.3 quota.sh --age: 30s of clock skew is tolerated" \
     "$(MEUTE_ROOT="$root" "$root/bin/quota.sh" --engine claude --age)" "0"
  _quota_age_snapshot "$root" -3600
  sed -i '/quota_max_age_hours/d' "$root/repos.yaml"
  sed -i 's/^  quota_floor_percent: 30/&\n  quota_max_age_hours: 1/' "$root/repos.yaml"
  out="$("$root/bin/meute" status 2>&1)"
  has "p2.3 status: a future snapshot is flagged as declined" "$out" "the runner declines"
  sed -i '/quota_max_age_hours/d' "$root/repos.yaml"

  # status: three separate facts.
  _quota_age_snapshot "$root" 7200
  sed -i '/quota_max_age_hours/d' "$root/repos.yaml"
  out="$("$root/bin/meute" status 2>&1)"
  has "p2.3 status: pool percentage with its age" "$out" "pool 90% remaining, snapshot 2h old"
  has "p2.3 status: says others are not measured" "$out" "other consumers of this pool are not measured"

  # Validation.
  printf 'version: 1\npolicy:\n  quota_max_age_hours: -3\n' > "$root/bad.yaml"
  is "p2.3 manifest: a negative max age is rejected" \
     "$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" policy "$root/bad.yaml" >/dev/null 2>&1; echo $?)" "2"
}

# P1.7 (a), R5, D7: a finding has an identity across reports. The fingerprint is
# sha1(repo | file path from the location | title), both normalised, so a repeat
# audit that words the location `./src/db.py:90` instead of `src/db.py:88` is
# still the same finding. A dismissal on one occurrence is inherited by later
# occurrences: `findings --new` stops re-raising it, `--all` shows it as
# `dismissed (seen before)`. Only dismissals are inherited (D7), never backwards,
# never across repos, and a finding's own decision always wins.
test_p1_7a_fingerprint_inherit() {
  local root="$FIXTURE/p17a" out py="$REPO/lib/report.py"
  mkdir -p "$root/reports/alpha" "$root/reports/beta" "$root/state" "$root/tasks"
  ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO"/tasks/*.md "$root/tasks/"
  cp "$FIXTURE/repos.yaml" "$root/repos.yaml"
  _p17a_report() {  # repo id started finding-lines...
    local repo="$1" id="$2" started="$3"; shift 3
    { printf -- '---\nrepo: %s\ntask: audit-security\ntier: tier2\nstarted: %s\nstatus: ok\n---\n\n## Summary\nx\n\n## Findings\n\n' "$repo" "$started"
      printf '%b\n' "$@"; } > "$root/reports/$repo/$id.md"
  }
  _p17a_report alpha audit-01 2026-09-01T04:00:00-04:00 \
    '### [HIGH] SQL injection in query\n- **Location:** `src/db.py:88`\n' \
    '### [LOW] Unused import\n- **Location:** `src/util.py:3`\n'
  _p17a_report alpha audit-02 2026-09-08T04:00:00-04:00 \
    '### [HIGH] SQL  Injection in query.\n- **Location:** `./src/db.py:90-94`\n' \
    '### [MEDIUM] Missing timeout\n- **Location:** `src/net.py:12`\n' \
    '### [LOW] Unused import\n- **Location:** src/util.py:4\n'
  _p17a_report beta audit-01 2026-09-08T04:00:00-04:00 \
    '### [HIGH] SQL injection in query\n- **Location:** `src/db.py:88`\n'

  local fp1 fp2 fpb
  fp1="$(python3 "$py" findings "$root/reports/alpha/audit-01.md" | jq -r '.[0].fingerprint')"
  fp2="$(python3 "$py" findings "$root/reports/alpha/audit-02.md" | jq -r '.[0].fingerprint')"
  fpb="$(python3 "$py" findings "$root/reports/beta/audit-01.md" | jq -r '.[0].fingerprint')"
  is  "p1.7a: fingerprint is a sha1" "$(grep -cE '^[0-9a-f]{40}$' <<< "$fp1")" "1"
  is  "p1.7a: same finding reworded and moved has the same fingerprint" "$fp2" "$fp1"
  is  "p1.7a: another finding has another fingerprint" \
      "$(python3 "$py" findings "$root/reports/alpha/audit-02.md" | jq -r '.[1].fingerprint' | grep -c "^${fp1}$")" "0"
  is  "p1.7a: the same finding in another repo has another fingerprint" "$([[ ${#fpb} == 40 && $fpb != "$fp1" ]] && echo distinct)" "distinct"

  # alpha/audit-01#1 dismissed, #2 actioned.
  printf 'alpha/audit-01#1\tdismissed\t2026-09-02\tfalse-positive\nalpha/audit-01#2\tactioned\t2026-09-02\t\n' > "$root/state/reports"
  out="$("$root/bin/meute" findings --new 2>&1)"
  is  "p1.7a: an inherited dismissal is hidden from --new" "$(grep -c 'alpha/audit-02#1' <<< "$out")" "0"
  has "p1.7a: an unrelated new finding is still listed" "$out" "alpha/audit-02#2"
  has "p1.7a: only dismissals are inherited (actioned is not)" "$out" "alpha/audit-02#3"
  has "p1.7a: not across repos" "$out" "beta/audit-01#1"
  out="$("$root/bin/meute" findings --all 2>&1)"
  has "p1.7a: --all shows it as seen before" "$(grep 'alpha/audit-02#1' <<< "$out")" "dismissed (seen before)"
  has "p1.7a: the original keeps its own state" "$(grep 'alpha/audit-01#1' <<< "$out")" "dismissed"
  hasnt "p1.7a: ...not marked seen before" "$(grep 'alpha/audit-01#1' <<< "$out")" "seen before"
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/inbox.py" dump 2>/dev/null)"
  is  "p1.7a: the inbox dump carries the fingerprint" \
      "$(jq -r '.findings[] | select(.report=="alpha/audit-02" and .n==1) | .fingerprint' <<< "$out")" "$fp1"
  is  "p1.7a: ...and the inherited decision" \
      "$(jq -r '.findings[] | select(.report=="alpha/audit-02" and .n==1) | .inherited' <<< "$out")" "dismissed"
  is  "p1.7a: ...and nothing inherited elsewhere" \
      "$(jq -r '[.findings[] | select(.inherited != "")] | length' <<< "$out")" "1"

  # A finding's own decision wins over an inherited one.
  printf 'alpha/audit-02#1\tactioned\t2026-09-09\t\n' >> "$root/state/reports"
  out="$("$root/bin/meute" findings --all 2>&1)"
  has   "p1.7a: an own decision wins" "$(grep 'alpha/audit-02#1' <<< "$out")" "actioned"
  hasnt "p1.7a: ...over the inherited one" "$(grep 'alpha/audit-02#1' <<< "$out")" "seen before"

  # Never backwards: a dismissal on the later report leaves the earlier one new.
  printf 'alpha/audit-02#1\tdismissed\t2026-09-09\tfalse-positive\n' > "$root/state/reports"
  out="$("$root/bin/meute" findings --new 2>&1)"
  has "p1.7a: a later dismissal is not inherited by an earlier report" "$out" "alpha/audit-01#1"
  is  "p1.7a: state/reports is never written by reading" \
      "$(cat "$root/state/reports")" "$(printf 'alpha/audit-02#1\tdismissed\t2026-09-09\tfalse-positive')"

  # The latest earlier decision wins: dismissed, then reversed (actioned), then
  # raised again -- the third occurrence is live and stays new.
  _p17a_report alpha audit-03 2026-09-15T04:00:00-04:00 \
    '### [HIGH] SQL injection in query\n- **Location:** `src/db.py:91`\n'
  printf 'alpha/audit-01#1\tdismissed\t2026-09-02\tfalse-positive\nalpha/audit-02#1\tactioned\t2026-09-09\t\n' > "$root/state/reports"
  out="$("$root/bin/meute" findings --new 2>&1)"
  has "p1.7a: a reversed dismissal is not inherited" "$out" "alpha/audit-03#1"
  printf 'alpha/audit-01#1\tdismissed\t2026-09-02\tfalse-positive\n' > "$root/state/reports"
  out="$("$root/bin/meute" findings --new 2>&1)"
  is  "p1.7a: an undecided middle occurrence does not break inheritance" "$(grep -c 'alpha/audit-0[23]#1' <<< "$out")" "0"
}

# P1.7 (b): `findings verify` (gone/changed/current/unknown against the
# repository's HEAD), superseded by a newer audit, `claim --pr`, `resolve --pr`
# and `findings --json`. D7: hidden rows stay visible under --all.
test_p1_7b_verify_claim() {
  local root="$FIXTURE/p17b" out g="$FIXTURE/p17b/git/alpha" a b url
  local gitc=(git -C "$g" -c user.name=t -c user.email=t@t)
  mkdir -p "$root/reports/alpha" "$root/state" "$root/tasks" "$g/src"
  ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO"/tasks/*.md "$root/tasks/"
  printf 'version: 1\nrepos:\n  - name: alpha\n    path: %s\n' "$g" > "$root/repos.yaml"
  git init -q -b main "$g"
  for f in db net old util; do printf '%s v1\n' "$f" > "$g/src/$f.py"; done
  "${gitc[@]}" add -A; "${gitc[@]}" commit -qm A; a="$(git -C "$g" rev-parse HEAD)"
  "${gitc[@]}" rm -q src/old.py; printf 'net v2\n' > "$g/src/net.py"
  "${gitc[@]}" mv src/util.py src/helpers.py
  "${gitc[@]}" commit -qam B; b="$(git -C "$g" rev-parse HEAD)"

  _p17b_report() {  # id started status lens base finding-lines...
    local id="$1" started="$2" status="$3" lens="$4" base="$5"; shift 5
    { printf -- '---\nrepo: alpha\ntask: audit-security\ntier: tier2\nlens: %s\nbase: %s\nstarted: %s\nstatus: %s\n---\n\n## Summary\nx\n\n' \
        "$lens" "$base" "$started" "$status"
      (( $# )) && printf '## Findings\n\n' && printf '%b\n' "$@"; } > "$root/reports/alpha/$id.md"
  }
  _p17b_report audit-01 2026-09-01T04:00:00-04:00 ok sec "main@$a" \
    '### [HIGH] Hardcoded token\n- **Location:** `src/old.py:3`\n' \
    '### [MEDIUM] Missing timeout\n- **Location:** `src/net.py:12`\n' \
    '### [LOW] Unused import\n- **Location:** `src/db.py:1`\n' \
    '### [LOW] Vague concern\n- **Severity:** low\n' \
    '### [LOW] Shadowed name\n- **Location:** `src/util.py:2`\n' \
    '### [LOW] Imaginary file\n- **Location:** `src/nope.py:2`\n'

  MEUTE_ROOT="$root" "$root/bin/meute" findings verify > "$root/verify.out" 2>&1
  is  "p1.7b verify: exits 0" "$?" "0"
  local st="$root/state/finding-status"
  is  "p1.7b verify: deleted file is gone"       "$(awk -F'\t' '$1=="alpha/audit-01#1"{print $2}' "$st")" "gone"
  is  "p1.7b verify: touched file is changed"    "$(awk -F'\t' '$1=="alpha/audit-01#2"{print $2}' "$st")" "changed"
  is  "p1.7b verify: untouched file is current"  "$(awk -F'\t' '$1=="alpha/audit-01#3"{print $2}' "$st")" "current"
  is  "p1.7b verify: no location is unknown"     "$(awk -F'\t' '$1=="alpha/audit-01#4"{print $2}' "$st")" "unknown"
  is  "p1.7b verify: a renamed file is changed, not gone" "$(awk -F'\t' '$1=="alpha/audit-01#5"{print $2}' "$st")" "changed"
  is  "p1.7b verify: a file in neither commit is unknown" "$(awk -F'\t' '$1=="alpha/audit-01#6"{print $2}' "$st")" "unknown"
  is  "p1.7b verify: records the head it checked against" "$(awk -F'\t' '$1=="alpha/audit-01#1"{print $3}' "$st")" "$b"
  has "p1.7b verify: says what it found" "$(cat "$root/verify.out")" "gone=1"
  [[ ! -e "$root/state/reports" ]] && ok "p1.7b verify: state/reports is not written" \
    || bad "p1.7b verify: state/reports is not written" "it exists"

  out="$("$root/bin/meute" findings --new 2>&1)"
  is  "p1.7b --new: gone is hidden" "$(grep -c 'alpha/audit-01#1 ' <<< "$out")" "0"
  has "p1.7b --new: changed is shown with its badge" "$(grep 'alpha/audit-01#2 ' <<< "$out")" "changed"
  has "p1.7b --new: current stays NEW" "$(grep 'alpha/audit-01#3 ' <<< "$out")" "NEW"
  has "p1.7b --new: unknown stays NEW" "$(grep 'alpha/audit-01#4 ' <<< "$out")" "NEW"
  has "p1.7b --all: gone is listed with its verdict" "$(grep 'alpha/audit-01#1 ' <<< "$("$root/bin/meute" findings --all 2>&1)")" "gone"

  # A failed run newer than the audit (no Findings section) supersedes nothing.
  _p17b_report audit-02 2026-09-08T04:00:00-04:00 error sec "main@$b"
  out="$("$root/bin/meute" findings --new 2>&1)"
  has "p1.7b superseded: a run with no findings supersedes nothing" "$out" "alpha/audit-01#2 "
  # ...nor a run that failed after writing a partial Findings section.
  _p17b_report audit-02b 2026-09-08T04:30:00-04:00 timeout sec "main@$b" \
    '### [LOW] Partial\n- **Location:** `src/db.py:1`\n'
  out="$("$root/bin/meute" findings --new 2>&1)"
  has "p1.7b superseded: a failed run's partial findings supersede nothing" "$out" "alpha/audit-01#2 "
  # Another lens supersedes nothing either.
  _p17b_report audit-03 2026-09-08T05:00:00-04:00 ok quality "main@$b" \
    '### [LOW] Style\n- **Location:** `src/db.py:1`\n'
  out="$("$root/bin/meute" findings --new 2>&1)"
  has "p1.7b superseded: another lens supersedes nothing" "$out" "alpha/audit-01#2 "
  # A newer audit of the same task and lens that no longer raises #2 supersedes it.
  _p17b_report audit-04 2026-09-15T04:00:00-04:00 ok sec "main@$b" \
    '### [LOW] Unused import\n- **Location:** `src/db.py:1`\n' \
    '### [LOW] Shadowed name\n- **Location:** `src/util.py:2`\n'
  out="$("$root/bin/meute" findings --new 2>&1)"
  is  "p1.7b superseded: hidden from --new" "$(grep -c 'alpha/audit-01#2 ' <<< "$out")" "0"
  has "p1.7b superseded: a finding the newer audit repeats stays" "$out" "alpha/audit-01#3 "
  has "p1.7b superseded: the newer audit's own finding is new" "$out" "alpha/audit-04#1 "
  has "p1.7b superseded: --all shows it" "$(grep 'alpha/audit-01#2 ' <<< "$("$root/bin/meute" findings --all 2>&1)")" "superseded"

  # claim: validated, hides the row, keeps the verdict; verify keeps the claim.
  url="https://github.com/o/r/pull/7"
  "$root/bin/meute" claim alpha/audit-01 -f 3 >/dev/null 2>&1
  is  "p1.7b claim: --pr is required" "$?" "1"
  "$root/bin/meute" claim alpha/audit-01 -f 3 --pr 'not a url' >/dev/null 2>&1
  is  "p1.7b claim: --pr must be a URL" "$?" "1"
  "$root/bin/meute" claim alpha/audit-01 -f 99 --pr "$url" >/dev/null 2>&1
  is  "p1.7b claim: the finding must exist" "$?" "1"
  "$root/bin/meute" claim alpha/audit-01 -f 3 --pr "$url" >/dev/null 2>&1
  is  "p1.7b claim: exits 0" "$?" "0"
  is  "p1.7b claim: recorded in finding-status" "$(awk -F'\t' '$1=="alpha/audit-01#3"{print $2"|"$5}' "$st")" "current|$url"
  out="$("$root/bin/meute" findings --new 2>&1)"
  is  "p1.7b claim: hidden from --new" "$(grep -c 'alpha/audit-01#3 ' <<< "$out")" "0"
  has "p1.7b claim: --all shows claimed" "$(grep 'alpha/audit-01#3 ' <<< "$("$root/bin/meute" findings --all 2>&1)")" "claimed"
  "$root/bin/meute" findings verify >/dev/null 2>&1
  is  "p1.7b claim: a later verify keeps the claim" "$(awk -F'\t' '$1=="alpha/audit-01#3"{print $5}' "$st")" "$url"
  [[ ! -e "$root/state/reports" ]] && ok "p1.7b claim: state/reports is not written" \
    || bad "p1.7b claim: state/reports is not written" "it exists"
  "$root/bin/meute" dismiss alpha/audit-01 -f 6 -r false-positive >/dev/null 2>&1
  "$root/bin/meute" claim alpha/audit-01 -f 6 --pr "$url" >/dev/null 2>&1
  is  "p1.7b claim: refuses a decided finding" "$?" "1"

  # resolve --pr: no -m needed, the PR lands in the note.
  "$root/bin/meute" resolve alpha/audit-01 -f 4 --pr "$url" >/dev/null 2>&1
  is  "p1.7b resolve --pr: exits 0 without -m" "$?" "0"
  has "p1.7b resolve --pr: the PR is in the note" "$(grep 'alpha/audit-01#4' "$root/state/reports")" "pr: $url"

  # --json: the contract external fix workflows read.
  out="$("$root/bin/meute" findings --json 2>/dev/null)"
  is  "p1.7b --json: valid JSON array" "$(jq -r 'type' <<< "$out")" "array"
  is  "p1.7b --json: --new excludes hidden rows" "$(jq -r '[.[] | select(.id=="alpha/audit-01#1" or .id=="alpha/audit-01#3")] | length' <<< "$out")" "0"
  is  "p1.7b --json: carries the contract fields" \
      "$(jq -r '.[] | select(.id=="alpha/audit-04#1") | [(.fingerprint|length), .repo, .severity, .location, .base, .state] | join("|")' <<< "$out")" \
      "40|alpha|LOW|src/db.py:1|$b|new"
  out="$("$root/bin/meute" findings --json --all 2>/dev/null)"
  is  "p1.7b --json --all: a claim carries its PR" "$(jq -r '.[] | select(.id=="alpha/audit-01#3") | .state + "|" + .verdict + "|" + .pr' <<< "$out")" "claimed|current|$url"
  is  "p1.7b --json --all: verdicts" "$(jq -r '.[] | select(.id=="alpha/audit-01#1" or .id=="alpha/audit-01#2") | .verdict' <<< "$out" | paste -sd,)" "gone,superseded"
  is  "p1.7b --json --all: a resolve --pr carries its PR" "$(jq -r '.[] | select(.id=="alpha/audit-01#4") | .pr' <<< "$out")" "$url"
  local empty="$FIXTURE/p17b-empty"; mkdir -p "$empty/state"
  ln -sfn "$REPO/bin" "$empty/bin"; ln -sfn "$REPO/lib" "$empty/lib"
  is  "p1.7b --json: no findings is an empty array" "$("$empty/bin/meute" findings --json 2>/dev/null)" "[]"

  # The web inbox joins the same verdicts.
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/inbox.py" dump 2>/dev/null)"
  is  "p1.7b dump: verdict and hidden" \
      "$(jq -r '.findings[] | select(.report=="alpha/audit-01" and (.n==1 or .n==2 or .n==3 or .n==5)) | "\(.n):\(.verdict):\(.hidden)"' <<< "$out" | sort | paste -sd,)" \
      "1:gone:true,2:superseded:true,3:current:true,5:changed:false"

  # A claim landing while verify is still diffing survives verify's write.
  local slow="$root/slowgit" realgit mark="$root/slowgit/in-diff"
  realgit="$(command -v git)"; mkdir -p "$slow"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do [[ $a == diff && ! -e %q ]] && { : > %q; sleep 3; break; }; done\nexec %q "$@"\n' \
    "$mark" "$mark" "$realgit" > "$slow/git"; chmod +x "$slow/git"
  PATH="$slow:$PATH" "$root/bin/meute" findings verify >/dev/null 2>&1 & local vpid=$!
  for _ in $(seq 1 100); do [[ -e "$mark" ]] && break; sleep 0.1; done
  "$root/bin/meute" claim alpha/audit-01 -f 5 --pr "$url" >/dev/null 2>&1
  is  "p1.7b race: claim during verify exits 0" "$?" "0"
  wait "$vpid"
  is  "p1.7b race: verify does not wipe a concurrent claim" "$(awk -F'\t' '$1=="alpha/audit-01#5"{print $5}' "$st")" "$url"
  is  "p1.7b race: verify still records its verdict" "$(awk -F'\t' '$1=="alpha/audit-01#5"{print $2}' "$st")" "changed"
  "$root/bin/meute" findings verify >/dev/null 2>&1
  # The lock: a writer between its re-read and its write makes claim wait.
  rm -f "$mark"
  MEUTE_ROOT="$root" MARK="$mark" python3 - "$REPO/lib" <<'PY' & vpid=$!
import os, sys, time
sys.path.insert(0, sys.argv[1]); import finding_status as fs
root = os.environ["MEUTE_ROOT"]
with fs.locked(root):
    rows = fs.read_status(root)
    open(os.environ["MARK"], "w").close(); time.sleep(2)
    rows["alpha/audit-04#1"] = ["current", "h", "t", ""]
    fs.write_status(root, rows)
PY
  for _ in $(seq 1 100); do [[ -e "$mark" ]] && break; sleep 0.1; done
  "$root/bin/meute" claim alpha/audit-04 -f 2 --pr "$url" >/dev/null 2>&1
  wait "$vpid"
  is  "p1.7b lock: a claim waits for a writer holding the lock" "$(awk -F'\t' '$1=="alpha/audit-04#2"{print $5}' "$st")" "$url"

  # Rollback: deleting state/finding-status drops every verdict and claim.
  rm -f "$st"
  out="$("$root/bin/meute" findings --new 2>&1)"
  has "p1.7b rollback: claimed row returns" "$out" "alpha/audit-01#3 "
  has "p1.7b rollback: a changed row loses its badge" "$(grep 'alpha/audit-01#5 ' <<< "$out")" "NEW"
}

# P1.7 (b): state/finding-status keys rows by <private-repo>/<report>#n and
# its pr column holds PR URLs; the lock beside it shares the name. Both must
# stay off the public harness like every other state/ file.
test_p1_7b_status_ignored() {
  local f
  for f in state/finding-status state/finding-status.lock; do
    is "p1.7b gitignore: ${f} never reaches the public harness" \
      "$(git -C "$REPO" check-ignore -q -- "$f"; echo $?)" "0"
  done
}

# P1.7 (b): verify_report must not let one finding's bad location, or a
# report's front-matter, steer git. A location outside the repository is
# unknown on its own and leaves its neighbours' verdicts intact; a base sha or
# ref that git would parse as an option is never passed to git.
test_p1_7b_verify_hardening() {
  local g="$FIXTURE/p17bh/alpha" a trap="$FIXTURE/p17bh/clobbered" out
  local gitc=(git -C "$g" -c user.name=t -c user.email=t@t)
  mkdir -p "$g/src"; git init -q -b main "$g"
  printf 'db v1\n' > "$g/src/db.py"
  "${gitc[@]}" add -A; "${gitc[@]}" commit -qm A; a="$(git -C "$g" rev-parse HEAD)"
  out="$(python3 - "$REPO/lib" "$g" "$a" "$trap" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); import finding_status as fs
g, a, trap = sys.argv[2:5]
def v(base, files): return ",".join(fs.verify_report(g, base, files)[1])
print("abs=" + v("main@" + a, ["src/db.py", "/etc/passwd"]))
print("up=" + v("main@" + a, ["src/db.py", "../x.py"]))
print("mid=" + v("main@" + a, ["src/db.py", "src/../../x.py"]))
print("optsha=" + v("main@--output=" + trap, ["src/db.py"]))
print("revsha=" + v("main@HEAD", ["src/db.py"]))
print("optref=" + v("--output=" + trap + "@" + a, ["src/db.py"]))
PY
)"
  is  "p1.7b hardening: an absolute location does not void its neighbours" "$(sed -n 's/^abs=//p' <<< "$out")" "current,unknown"
  is  "p1.7b hardening: a ../ location does not void its neighbours" "$(sed -n 's/^up=//p' <<< "$out")" "current,unknown"
  is  "p1.7b hardening: a .. component mid-path is unknown" "$(sed -n 's/^mid=//p' <<< "$out")" "current,unknown"
  is  "p1.7b hardening: a base sha that is a git option is unknown" "$(sed -n 's/^optsha=//p' <<< "$out")" "unknown"
  is  "p1.7b hardening: a base sha that is not hex is unknown" "$(sed -n 's/^revsha=//p' <<< "$out")" "unknown"
  is  "p1.7b hardening: a base ref that is a git option is unknown" "$(sed -n 's/^optref=//p' <<< "$out")" "unknown"
  [[ ! -e "$trap" ]] && ok "p1.7b hardening: base front-matter never reaches git as an option" \
    || bad "p1.7b hardening: base front-matter never reaches git as an option" "$trap was written"

  # A PR URL is one printable token: ESC and other control characters are out.
  local u okv=""
  for u in $'https://x/pull/1\e[31m' $'https://x/\x01y' $'https://x/\x7fy' $'https://x/a\rb' $'https://x/a b'; do
    ( source "$REPO/lib/finding_cmds.sh"; valid_pr_url "$u" ) && okv="$okv accepted"
  done
  is  "p1.7b hardening: a PR URL with a control character is rejected" "$okv" ""
  ( source "$REPO/lib/finding_cmds.sh"; valid_pr_url "https://github.com/o/r/pull/7" ) \
    && ok "p1.7b hardening: a plain PR URL is still accepted" || bad "p1.7b hardening: a plain PR URL is still accepted" "rejected"
}

# A file renamed and heavily rewritten shows as delete + add (below git's
# similarity threshold): it must not read as gone, or it is hidden.
test_p1_7b_rewritten_rename() {
  local g="$FIXTURE/p17br/alpha" a out
  local gitc=(git -C "$g" -c user.name=t -c user.email=t@t)
  mkdir -p "$g/src"; git init -q -b main "$g"
  seq 1 40 | sed 's/^/old line /' > "$g/src/db.py"
  seq 1 5 | sed 's/^/stay /' > "$g/src/keep.py"
  seq 1 5 | sed 's/^/dies /' > "$g/src/dead.py"
  "${gitc[@]}" add -A; "${gitc[@]}" commit -qm A; a="$(git -C "$g" rev-parse HEAD)"
  git -C "$g" rm -q src/db.py
  seq 1 40 | sed 's/^/totally new /' > "$g/src/storage.py"
  "${gitc[@]}" add -A; "${gitc[@]}" commit -qm B
  out="$(python3 - "$REPO/lib" "$g" "$a" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); import finding_status as fs
g, a = sys.argv[2:4]
print(",".join(fs.verify_report(g, "main@" + a, ["src/db.py", "src/keep.py"])[1]))
PY
)"
  is  "p1.7b rename: a rewritten rename is not gone" "$out" "changed,current"
  # A plain deletion with nothing added is still gone.
  git -C "$g" rm -q src/dead.py; "${gitc[@]}" commit -qm C
  a="$(git -C "$g" rev-parse HEAD~1)"
  out="$(python3 - "$REPO/lib" "$g" "$a" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); import finding_status as fs
print(",".join(fs.verify_report(sys.argv[2], "main@" + sys.argv[3], ["src/dead.py"])[1]))
PY
)"
  is  "p1.7b rename: a plain deletion is still gone" "$out" "gone"
}

# P2.6 (R20): a typo under policy: used to fall back to the default silently.
# validate and doctor now name unknown keys; they stay a warning, never an error.
test_p26_unknown_policy_keys() {
  local root="$FIXTURE/p26" out rc
  mkdir -p "$root/state"
  cp "$REPO/repos.yaml" "$root/repos.yaml"
  ln -s "$REPO/tasks" "$root/tasks"
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" validate "$root/repos.yaml" 2>&1)"
  hasnt "p2.6 validate: known keys draw no warning" "$out" "unknown policy key"
  sed -i 's/^  quota_floor_percent: 30.*/&\n  quota_flor_percent: 5/' "$root/repos.yaml"
  rc=0; out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" validate "$root/repos.yaml" 2>&1)" || rc=$?
  is  "p2.6 validate: an unknown policy key is not an error" "$rc" "0"
  has "p2.6 validate: ...it is named in a warning" "$out" "unknown policy key(s): quota_flor_percent"
  has "p2.6 validate: ...and the manifest still validates" "$out" "ok: "
  out="$(MEUTE_ROOT="$root" MEUTE_MANIFEST="$root/repos.yaml" "$REPO/bin/meute" doctor 2>&1)" || true
  has "p2.6 doctor: names the unknown policy key" "$out" "unknown policy key(s): quota_flor_percent"
}

# P1.3 runner half (R11) and P1.4 (R15). A drain loop needs run.sh to wait for
# the lock instead of skipping, to ignore a staged plan when it is draining the
# manifest, and to refuse, under the lock, a forced staged item another fire
# has already finished. The stub engine counts its calls in engine.calls.
_p13_fixture() {
  local root="$1" repo="$2"
  _runlock_fixture "$root" "$repo" tier2
  sed -i "2a printf x >> '$root/engine.calls'" "$root/stub/claude"
}
_p13_calls() { [[ -f "$1/engine.calls" ]] && wc -c < "$1/engine.calls" || echo 0; }
# Two staged items, so marking one done does not retire the plan at startup.
_p13_stage() {
  printf '{"version":1,"scan":"%s","allow_web":false,"entries":[%s,%s]}\n' "$1" \
    "{\"name\":\"plan-001-x\",\"path\":\"$2\",\"task\":\"t\"}" \
    "{\"name\":\"plan-002-y\",\"path\":\"$2\",\"task\":\"t\"}" > "$1/state/plan-queue.json"
}

test_p1_3_source_manifest() {
  local root="$FIXTURE/p13src" repo="$FIXTURE/p13src/git-lk" log rc plan
  _p13_fixture "$root" "$repo"
  log="$root/state/log"
  local run=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily --strict-exit )
  _p13_stage "$root" "$repo"; plan="$(cat "$root/state/plan-queue.json")"

  rc=0; "${run[@]}" --source manifest >/dev/null 2>&1 || rc=$?
  is  "source manifest: the fire runs and exits 0"          "$rc" "0"
  has "source manifest: ...the manifest item, not the plan's" "$(tail -1 "$log")" $'\trepo=lk\t'
  is  "source manifest: the staged plan is untouched"       "$(cat "$root/state/plan-queue.json" 2>/dev/null)" "$plan"
  is  "source manifest: no plan-complete mark is written"   "$([[ -e "$root/state/plan-complete" ]] && echo present || echo absent)" "absent"
  is  "source manifest: no plan cursor is written"          "$(grep -c '^plan-cursor' "$root/state/cursor")" "0"

  rc=0; "${run[@]}" --source bogus >/dev/null 2>&1 || rc=$?
  is  "source manifest: an unknown source is a usage error (2)" "$rc" "2"
  rc=0; "${run[@]}" --source plan >/dev/null 2>&1 || rc=$?
  is  "source manifest: --source plan is the default, the staged item runs" "$rc" "0"
  has "source manifest: ...and it is the plan's"            "$(tail -1 "$log")" $'\trepo=plan-001-x\t'
}

test_p1_4_once() {
  local root="$FIXTURE/p14" repo="$FIXTURE/p14/git-lk" log rc key before
  _p13_fixture "$root" "$repo"
  log="$root/state/log"
  local force=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily
                --repo plan-001-x --task t --strict-exit )
  _p13_stage "$root" "$repo"
  key="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.yaml" "$root/state/plan-queue.json" daily | jq -r 'select(.repo == "plan-001-x") | .key')"
  is "once: the fixture's plan key is readable" "$([[ -n "$key" ]] && echo yes)" "yes"

  # Another fire finished the item between the caller's check and this lock.
  printf '%s\t%s\n' "$key" "2026-11-16T00:00:00+00:00" > "$root/state/plan-complete"
  before="$(_p13_calls "$root")"
  rc=0; "${force[@]}" --once >/dev/null 2>&1 || rc=$?
  is  "once: a finished staged item exits 16 (already-done)" "$rc" "16"
  is  "once: ...without calling the engine"                 "$(_p13_calls "$root")" "$before"
  has "once: ...and logs code=already-done"                 "$(tail -1 "$log")" $'\tcode=already-done\t'
  is  "once: ...the plan is left staged"                    "$([[ -f "$root/state/plan-queue.json" ]] && echo staged)" "staged"
  rc=0; env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily --repo plan-001-x --task t --once >/dev/null 2>&1 || rc=$?
  is  "once: ...and exits 0 without --strict-exit (D1)"      "$rc" "0"

  # Default unchanged: a forced run without --once re-runs the item.
  rc=0; "${force[@]}" >/dev/null 2>&1 || rc=$?
  is  "once: without --once a forced finished item still runs" "$rc" "0"
  is  "once: ...through the engine"                         "$(_p13_calls "$root")" "$(( before + 1 ))"

  # An unfinished staged item runs under --once.
  _p13_stage "$root" "$repo"; rm -f "$root/state/plan-complete"
  rc=0; "${force[@]}" --once >/dev/null 2>&1 || rc=$?
  is  "once: an unfinished staged item runs under --once"   "$rc" "0"
  is  "once: ...through the engine"                         "$(_p13_calls "$root")" "$(( before + 2 ))"
  has "once: ...and logs it"                                "$(tail -1 "$log")" $'\trepo=plan-001-x\t'
}

# _p13_hold_lock <lock-file> <seconds> <ready-file>: hold the lock in the
# background (the sleep does not inherit it, so killing the holder frees it).
_p13_hold_lock() {
  ( exec 8>"$1"; flock 8; : > "$3"; sleep "$2" 8>&- ) &
  P13_HOLDER=$!
  local i; for (( i = 0; i < 100; i++ )); do [[ -e "$3" ]] && return 0; sleep 0.2; done
  return 1
}

test_p1_3_wait_lock() {
  local root="$FIXTURE/p13wl" repo="$FIXTURE/p13wl/git-lk" log rc i
  _p13_fixture "$root" "$repo"
  log="$root/state/log"
  local run=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily --strict-exit )

  # A holder that lets go within the wait: the fire waits, then runs.
  _p13_hold_lock "$root/state/.lock" 4 "$root/ready1" || bad "wait lock: holder 1 took the lock" "no ready file"
  rc=0; "${run[@]}" --wait-lock 120 >/dev/null 2>&1 || rc=$?
  is  "wait lock: a lock released within the wait is waited for (exit 0)" "$rc" "0"
  has "wait lock: ...and the item runs"                    "$(tail -1 "$log")" $'\tstatus=ok\t'
  wait "$P13_HOLDER" 2>/dev/null

  # A holder that outlives the wait: skipped as lock, 11.
  _p13_hold_lock "$root/state/.lock" 120 "$root/ready2" || bad "wait lock: holder 2 took the lock" "no ready file"
  rc=0; "${run[@]}" --wait-lock 1 >/dev/null 2>&1 || rc=$?
  is  "wait lock: a lock held past the wait is skipped (11)" "$rc" "11"
  has "wait lock: ...as code=lock"                         "$(tail -1 "$log")" $'\tcode=lock\t'

  # A hold set while the fire waits is honoured once the lock is taken.
  ( "${run[@]}" --wait-lock 137 >/dev/null 2>&1; echo $? > "$root/held.rc" ) &
  local waiter=$!
  for (( i = 0; i < 300; i++ )); do ps -eo args | grep -q '[f]lock -w 137' && break; sleep 0.2; done
  (( i < 300 )) || bad "wait lock: the waiting fire reached flock -w" "not seen within 60 s"
  printf 'hold\t%s\t%s\n' "$(( $(date +%s) + 3600 ))" "set during the wait" > "$root/state/hold"
  kill "$P13_HOLDER" 2>/dev/null; wait "$P13_HOLDER" 2>/dev/null
  wait "$waiter"
  is  "wait lock: a hold set during the wait still stops the fire (10)" "$(cat "$root/held.rc")" "10"
  rm -f "$root/state/hold"

  rc=0; "${run[@]}" --wait-lock soon >/dev/null 2>&1 || rc=$?
  is  "wait lock: a non-integer wait is a usage error (2)"  "$rc" "2"
  rc=0; "${run[@]}" --wait-lock 09 >/dev/null 2>&1 || rc=$?
  is  "wait lock: a zero-padded wait is a usage error, not an octal crash (2)" "$rc" "2"
}

# P1.3 CLI half (R11): `meute drain` loops run.sh unforced, so the cursor and
# every gate still apply, and ends on a stop-class exit or after one rotation.
# _drain_fixture <root> <n>: the P1.3 fixture with n manifest repos lk1..lkn.
_drain_fixture() {
  local root="$1" n="$2" i
  _p13_fixture "$root" "$root/git-lk1"
  for (( i = 2; i <= n; i++ )); do
    mkdir -p "$root/git-lk$i"; git -C "$root/git-lk$i" init -q -b main
    echo x > "$root/git-lk$i/f.txt"; git -C "$root/git-lk$i" add -A
    git -C "$root/git-lk$i" -c user.email=t@t -c user.name=t commit -qm init
  done
  python3 - "$root" "$n" <<'PY'
import sys, yaml
root, n = sys.argv[1], int(sys.argv[2])
p = f"{root}/repos.yaml"; d = yaml.safe_load(open(p))
d["repos"] = [{"name": f"lk{i}", "path": f"{root}/git-lk{i}", "spec": "drain fixture", "tasks": ["t"]}
              for i in range(1, n + 1)]
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PY
}
# The repos the fires ran, in order, from state/log.
_drain_ran() { grep -o $'\trepo=[^\t]*' "$1/state/log" 2>/dev/null | cut -d= -f2 | paste -sd' ' -; }

test_p1_3_drain_rotation() {
  local root="$FIXTURE/drain-rot" rc key
  _drain_fixture "$root" 3
  local drain=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/meute" drain daily )

  rc=0; "${drain[@]}" >/dev/null 2>&1 || rc=$?
  is "drain: a fresh three-entry fleet drains and exits 0"    "$rc" "0"
  is "drain: ...exactly three engine calls, then it stops"    "$(_p13_calls "$root")" "3"
  is "drain: ...one fire per entry, in rotation order"        "$(_drain_ran "$root")" "lk1 lk2 lk3"

  # A rotation starts after the cursor and ends on the entry it named.
  key="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" daily | jq -r 'select(.repo == "lk1") | .key')"
  printf 'cursor.daily\t%s\n' "$key" > "$root/state/cursor"; : > "$root/state/log"
  rc=0; "${drain[@]}" >/dev/null 2>&1 || rc=$?
  is "drain: from a cursor, one full rotation ending on it"   "$(_drain_ran "$root"):$rc" "lk2 lk3 lk1:0"

  : > "$root/state/log"
  rc=0; "${drain[@]}" --max 2 >/dev/null 2>&1 || rc=$?
  is "drain: --max 2 stops after two fires"                   "$(_drain_ran "$root"):$rc" "lk2 lk3:0"

  # The sentinel entry is stepped over (not a repository): the rotation still
  # ends, at the first entry this drain already ran.
  printf 'cursor.daily\t%s\n' "$key" > "$root/state/cursor"; : > "$root/state/log"
  mv "$root/git-lk1/.git" "$root/git-lk1/.git.off"
  rc=0; "${drain[@]}" >/dev/null 2>&1 || rc=$?
  is "drain: a stepped-over sentinel still ends the rotation" "$(_drain_ran "$root"):$rc" "lk2 lk3 lk2:0"
  mv "$root/git-lk1/.git.off" "$root/git-lk1/.git"
}

test_p1_3_drain_stops() {
  local root="$FIXTURE/drain-stop" rc
  _drain_fixture "$root" 4
  local drain=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/meute" drain daily )
  cp "$root/repos.yaml" "$root/repos.yaml.good"

  # A budget skip is a stop: the loop ends with the runner's status, 12.
  python3 - "$root/repos.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); d["policy"]["weekly_runs"] = 2
yaml.safe_dump(d, open(p, "w"), sort_keys=False)
PY
  rc=0; "${drain[@]}" >/dev/null 2>&1 || rc=$?
  is  "drain: a budget skip ends the loop with exit 12"        "$rc" "12"
  is  "drain: ...after the two runs the budget allowed"        "$(_p13_calls "$root")" "2"
  has "drain: ...and the fire that declined logged code=budget" "$(tail -1 "$root/state/log")" $'\tcode=budget\t'
  cp "$root/repos.yaml.good" "$root/repos.yaml"; : > "$root/state/log"; rm -f "$root/state/cursor"

  # A hold is a stop too, before any engine call.
  printf 'hold\t%s\t%s\n' "$(( $(date +%s) + 3600 ))" "drain test" > "$root/state/hold"
  rc=0; "${drain[@]}" >/dev/null 2>&1 || rc=$?
  is  "drain: a hold ends the loop with exit 10"               "$rc:$(_p13_calls "$root")" "10:2"
  rm -f "$root/state/hold"

  # --repo narrows the queue without forcing: the quota gate still applies.
  : > "$root/state/log"
  rc=0; "${drain[@]}" --repo lk3 >/dev/null 2>&1 || rc=$?
  is  "drain: --repo lk3 runs only lk3"                        "$(_drain_ran "$root"):$rc" "lk3:0"
  : > "$root/state/log"
  rc=0; "${drain[@]}" --repo lk2 --repo lk4 >/dev/null 2>&1 || rc=$?
  is  "drain: --repo is repeatable"                            "$(_drain_ran "$root"):$rc" "lk2 lk4:0"
  local before; before="$(_p13_calls "$root")"
  rc=0; env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=10 "$root/bin/meute" drain daily --repo lk3 >/dev/null 2>&1 || rc=$?
  is  "drain: --repo does not bypass the quota floor (14, no call)" "$rc:$(_p13_calls "$root")" "14:$before"
  rc=0; "${drain[@]}" --repo nope >/dev/null 2>&1 || rc=$?
  is  "drain: --repo naming no queue entry is a usage error (2)" "$rc:$(_p13_calls "$root")" "2:$before"

  # Three failed fires in a row end the loop with 1, before the fourth entry.
  sed -i 's/is_error:false/is_error:true/' "$root/stub/claude"
  rm -f "$root/state/cursor"; : > "$root/state/log"
  rc=0; "${drain[@]}" >/dev/null 2>&1 || rc=$?
  is  "drain: three consecutive failures stop the loop (1)"    "$(_drain_ran "$root"):$rc" "lk1 lk2 lk3:1"
  sed -i 's/is_error:true/is_error:false/' "$root/stub/claude"

  local bad
  for bad in "--max 0" "--max 09" "--max x" "--until 24:00" "--until 7:5" "--source bogus" "--bogus"; do
    rc=0; "${drain[@]}" $bad >/dev/null 2>&1 || rc=$?
    is "drain: '$bad' is a usage error (2)" "$rc" "2"
  done
  rc=0; env PATH="$root/stub:$PATH" "$root/bin/meute" drain hourly >/dev/null 2>&1 || rc=$?
  is "drain: an unknown slot is a usage error (2)" "$rc" "2"
}

test_p1_3_drain_lock_and_source() {
  local root="$FIXTURE/drain-src" rc plan
  _drain_fixture "$root" 1
  local drain=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/meute" drain daily )

  # A held lock is waited for, not skipped.
  _p13_hold_lock "$root/state/.lock" 4 "$root/ready" || bad "drain lock: holder took the lock" "no ready file"
  rc=0; "${drain[@]}" --max 1 >/dev/null 2>&1 || rc=$?
  is  "drain lock: a held lock is waited for (exit 0, one call)" "$rc:$(_p13_calls "$root")" "0:1"
  hasnt "drain lock: ...no fire was skipped as code=lock"       "$(cat "$root/state/log")" $'\tcode=lock\t'
  wait "$P13_HOLDER" 2>/dev/null

  # --source manifest runs the manifest while a plan is staged, untouched.
  _p13_stage "$root" "$root/git-lk1"; plan="$(cat "$root/state/plan-queue.json")"; : > "$root/state/log"
  rc=0; "${drain[@]}" --source manifest >/dev/null 2>&1 || rc=$?
  is  "drain source: --source manifest runs the manifest item"  "$(_drain_ran "$root"):$rc" "lk1:0"
  is  "drain source: ...the staged plan is untouched"           "$(cat "$root/state/plan-queue.json")" "$plan"

  # The default drains the staged plan, every item once, and stops there
  # instead of falling back to the manifest when the plan retires.
  : > "$root/state/log"
  rc=0; "${drain[@]}" >/dev/null 2>&1 || rc=$?
  is  "drain source: the plan drains, then the loop stops"      "$(_drain_ran "$root"):$rc" "plan-001-x plan-002-y:0"
}

# --until HH:MM: the next such wall-clock time, today or tomorrow.
test_p1_3_drain_until() {
  local probe='source "$1/bin/meute"; MEUTE_NOW="$2"; drain_deadline "$3"'
  local noon; noon="$(TZ=UTC date -d '2026-11-16 12:00' +%s)"
  is "drain until: a later time is today"      "$(TZ=UTC bash -c "$probe" _ "$REPO" "$noon" 13:30)" "$(( noon + 5400 ))"
  is "drain until: an earlier time is tomorrow" "$(TZ=UTC bash -c "$probe" _ "$REPO" "$noon" 11:00)" "$(( noon + 82800 ))"
  is "drain until: now itself is tomorrow"     "$(TZ=UTC bash -c "$probe" _ "$REPO" "$noon" 12:00)" "$(( noon + 86400 ))"

  # The loop checks it before each fire: once the clock reaches it, no more.
  local check='source "$1/bin/meute"; DRAIN_DEADLINE="$2"; MEUTE_NOW="$3"; drain_before_deadline'
  local rc=0; bash -c "$check" _ "$REPO" "$noon" "$noon" || rc=$?
  is "drain until: the deadline reached stops the loop"  "$rc" "1"
  rc=0; bash -c "$check" _ "$REPO" "$noon" "$(( noon - 1 ))" || rc=$?
  is "drain until: before the deadline the loop goes on" "$rc" "0"
  rc=0; bash -c "$check" _ "$REPO" "" "$noon" || rc=$?
  is "drain until: no --until never stops it"            "$rc" "0"
}

# A narrowed drain must not move the fleet-wide cursor the timers rotate on:
# `drain --repo` keeps its own cursor, and the next timer fire resumes where
# the timer left off (review of PR #55).
test_p1_3_drain_repo_cursor() {
  local root="$FIXTURE/drain-only" rc shared
  _drain_fixture "$root" 4
  local env=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 )
  for _ in 1 2 3; do "${env[@]}" "$root/bin/run.sh" daily >/dev/null 2>&1 || true; done
  is "drain --repo: three timer fires ran lk1 lk2 lk3" "$(_drain_ran "$root")" "lk1 lk2 lk3"
  shared="$(grep -P '^cursor\.daily\t' "$root/state/cursor")"

  : > "$root/state/log"
  rc=0; "${env[@]}" "$root/bin/meute" drain daily --repo lk1 >/dev/null 2>&1 || rc=$?
  is "drain --repo: the narrowed drain runs lk1 and exits 0" "$(_drain_ran "$root"):$rc" "lk1:0"
  is "drain --repo: ...and leaves the shared cursor alone"   "$(grep -P '^cursor\.daily\t' "$root/state/cursor")" "$shared"

  : > "$root/state/log"
  "${env[@]}" "$root/bin/run.sh" daily >/dev/null 2>&1 || true
  is "drain --repo: the next timer fire resumes at lk4"      "$(_drain_ran "$root")" "lk4"

  # The narrowed cursor is its own rotation: a second narrowed drain over two
  # repos runs each once and stops.
  : > "$root/state/log"
  rc=0; "${env[@]}" "$root/bin/meute" drain daily --repo lk2 --repo lk3 >/dev/null 2>&1 || rc=$?
  is "drain --repo: a narrowed rotation over two repos"      "$(_drain_ran "$root"):$rc" "lk2 lk3:0"
  is "drain --repo: ...still leaves the shared cursor on lk4" "$(grep -P '^cursor\.daily\t' "$root/state/cursor" | grep -c lk4)" "1"
}

# P2.7 (R14): drain starts each run.sh in a transient systemd scope when
# systemd-run works, so an engine straggler dies with the scope; otherwise it
# behaves as before. A stub systemd-run logs its argv and execs the command.
_scope_stub() {
  local root="$1"
  cat > "$root/stub/systemd-run" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> '$root/scope.calls'
# SCOPE_INT: a Ctrl-C on the run: the drain gets INT and its child dies of it.
[[ -n "\${SCOPE_INT:-}" && "\${!#}" != true ]] && { kill -INT \$PPID; kill -INT \$\$; sleep 5; }
[[ "\${!#}" == true && -n "\${SCOPE_PROBE_FAIL:-}" ]] && exit 1
while [[ "\$1" == --* ]]; do shift; done
exec "\$@"
EOF
  chmod +x "$root/stub/systemd-run"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$root/stop.calls" > "$root/stub/systemctl"
  chmod +x "$root/stub/systemctl"
}
# run.sh invocations the stub launched (the probe line ends in "true").
_scope_runs() { local n; n="$(grep -c 'bin/run.sh daily' "$1/scope.calls" 2>/dev/null)"; echo "${n:-0}"; }

test_p2_7_scope_containment() {
  local root="$FIXTURE/p27" rc
  _drain_fixture "$root" 2
  _scope_stub "$root"
  local env=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 MEUTE_SCOPE=on MEUTE_SYSTEMD_RUN="$root/stub/systemd-run" MEUTE_SYSTEMCTL="$root/stub/systemctl" )

  rc=0; "${env[@]}" "$root/bin/meute" drain daily >/dev/null 2>&1 || rc=$?
  is  "scope: the drain still completes and exits 0"          "$rc:$(_drain_ran "$root")" "0:lk1 lk2"
  is  "scope: ...each run.sh went through systemd-run"        "$(_scope_runs "$root")" "2"
  has "scope: ...as a user scope that is collected"           "$(grep 'bin/run.sh daily' "$root/scope.calls" | head -1)" "--user --scope --collect"
  local started stopped
  started="$(grep -o -- '--unit=meute-run-[0-9-]*' "$root/scope.calls" | cut -d= -f2 | sort | paste -sd' ')"
  # The exact stop line: `--user stop <unit>.scope`. A wrong suffix or verb names no unit.
  stopped="$(sed -n 's/^--user stop \(meute-run-[0-9-]*\)\.scope$/\1/p' "$root/stop.calls" 2>/dev/null | sort | paste -sd' ')"
  is  "scope: ...and each named scope is stopped after its run.sh" "$(wc -w <<< "$started"):$stopped" "2:$started"

  rm -f "$root/scope.calls"; : > "$root/state/log"; rm -f "$root/state/cursor"
  rc=0; SCOPE_PROBE_FAIL=1 "${env[@]}" "$root/bin/meute" drain daily >/dev/null 2>&1 || rc=$?
  is  "scope: a failing systemd-run probe falls back, drain works" "$rc:$(_drain_ran "$root")" "0:lk1 lk2"
  is  "scope: ...and no run.sh goes through it"               "$(_scope_runs "$root")" "0"

  rm -f "$root/scope.calls"; : > "$root/state/log"; rm -f "$root/state/cursor"
  rc=0; "${env[@]}" MEUTE_SYSTEMD_RUN="$root/stub/absent" "$root/bin/meute" drain daily >/dev/null 2>&1 || rc=$?
  is  "scope: no systemd-run at all falls back, drain works"  "$rc:$(_drain_ran "$root")" "0:lk1 lk2"

  rm -f "$root/scope.calls"; : > "$root/state/log"; rm -f "$root/state/cursor"
  rc=0; "${env[@]}" MEUTE_SCOPE=off "$root/bin/meute" drain daily >/dev/null 2>&1 || rc=$?
  is  "scope: MEUTE_SCOPE=off never calls systemd-run"        "$rc:$(_scope_runs "$root"):$([[ -e $root/scope.calls ]] && echo called || echo none)" "0:0:none"
}

# An INT or TERM to the drain, mid run.sh, must still stop that run's scope and
# then end the drain by that signal (a TERM aimed at the drain alone is deferred
# by bash until run.sh returns, so the item in flight finishes; either way no
# further fire starts).
_scope_signal_case() {
  local sig="$1" root="$FIXTURE/p27sig$1" rc started stopped
  _drain_fixture "$root" 2
  _scope_stub "$root"
  sed -i "2a printf x >> '$root/engine.started'; while [[ ! -e '$root/release' ]]; do sleep 0.1; done" "$root/stub/claude"
  rc=0
  python3 - "$sig" "$root" <<'PY' || rc=$?
import os, signal, subprocess, sys, time
sig, root = getattr(signal, "SIG" + sys.argv[1]), sys.argv[2]
env = dict(os.environ, SCOPE_INT="1" if sig == signal.SIGINT else "", PATH=f"{root}/stub:" + os.environ["PATH"], MEUTE_QUOTA_STUB="100", MEUTE_SCOPE="on",
           MEUTE_SYSTEMD_RUN=f"{root}/stub/systemd-run", MEUTE_SYSTEMCTL=f"{root}/stub/systemctl")
p = subprocess.Popen([f"{root}/bin/meute", "drain", "daily"], env=env,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))  # an ambient ignore would hide INT
for _ in range(100):
    if sig == signal.SIGINT or os.path.exists(f"{root}/engine.started"):
        break
    time.sleep(0.1)
if sig == signal.SIGTERM:  # the web Stop: TERM to the drain alone, run.sh still going
    os.kill(p.pid, sig)
    open(f"{root}/release", "w").close()
try:
    sys.exit(abs(p.wait(timeout=30)) % 256)  # -N: ended by signal N
except subprocess.TimeoutExpired:
    p.kill(); sys.exit(99)
PY
  started="$(grep -o -- '--unit=meute-run-[0-9-]*' "$root/scope.calls" | cut -d= -f2 | sort | paste -sd' ')"
  stopped="$(sed -n 's/^--user stop \(meute-run-[0-9-]*\)\.scope$/\1/p' "$root/stop.calls" 2>/dev/null | sort | paste -sd' ')"
  is "scope $sig: the drain ends by the signal"  "$rc" "$(kill -l "$sig")"
  is "scope $sig: ...the run in flight had its scope stopped" "$(wc -w <<< "$started"):$stopped" "1:$started"
  is "scope $sig: ...and no second fire started"   "$(cat "$root/engine.started" 2>/dev/null | wc -c)" "$([[ $sig == TERM ]] && echo 1 || echo 0)"
}
test_p2_7_scope_signals() { _scope_signal_case TERM; _scope_signal_case INT; }

# scope_run is library code a caller's shell shares: it must leave the caller's
# own INT/TERM traps alone, keep ITS traps until the scope is stopped, and a
# nested call must not clear the outer call's trap or unit.
_scope_lib_case() {
  local root="$FIXTURE/p27lib" out
  mkdir -p "$root"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\nwhile [[ "$1" == --* ]]; do shift; done\nexec "$@"\n' "$root/run.calls" > "$root/systemd-run"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$root/stop.calls" > "$root/systemctl"
  chmod +x "$root/systemd-run" "$root/systemctl"
  out="$(MEUTE_SYSTEMD_RUN="$root/systemd-run" MEUTE_SYSTEMCTL="$root/systemctl" ROOT="$root" LIB="$REPO/lib/scope.sh" bash -c '
    source "$LIB"; SCOPE_CMD=("$MEUTE_SYSTEMD_RUN" --user --scope)
    trap "echo caller-int" INT; trap "echo caller-term" TERM
    scope_run true
    echo "after:$(trap -p INT | grep -c caller-int)$(trap -p TERM | grep -c caller-term)"
    trap - INT TERM
    scope_run true
    echo "none:$(trap -p INT TERM | wc -l)"
    scope_stop() { echo "during:$(trap -p TERM | grep -c scope_on_signal)"; }
    scope_run true
    source "$LIB"; SCOPE_CMD=("$MEUTE_SYSTEMD_RUN" --user --scope)
    : > "$ROOT/run.calls"
    trap "scope_on_signal TERM" TERM; SCOPE_UNIT=outer   # as if an outer scope_run were live
    scope_run true
    echo "outer-unit:$SCOPE_UNIT"
    echo "outer-trap:$(trap -p TERM | grep -c scope_on_signal)"
    echo "runs:$(grep -c -- --unit "$ROOT/run.calls")"
  ' 2>&1)"
  has "scope lib: a caller's INT/TERM traps survive scope_run" "$out" "after:11"
  has "scope lib: no caller trap stays none after scope_run" "$out" "none:0"
  has "scope lib: our traps are still set while the scope is stopped" "$out" "during:1"
  has "scope lib: a nested scope_run keeps the outer unit" "$out" "outer-unit:outer"
  has "scope lib: ...and the outer trap" "$out" "outer-trap:1"
  has "scope lib: ...and starts no second scope" "$out" "runs:0"
}
test_p2_7_scope_lib() { _scope_lib_case; }

# P2.7 for real: an engine straggler left by a drain run.sh must be gone once
# that run.sh returns. A scope is not stopped when its main process exits, so
# this needs a real transient unit; skipped where systemd-run --user is absent.
test_p2_7_scope_reaps_stragglers() {
  local root="$FIXTURE/p27real" rc pid alive=""
  if ! timeout 20 systemd-run --user --scope --collect --quiet true >/dev/null 2>&1; then
    skip "scope reaps: systemd-run --user --scope is not usable here" "real-unit test only"
    return 0
  fi
  _drain_fixture "$root" 2
  sed -i "3a setsid sleep 600 </dev/null >/dev/null 2>&1 & echo \$! >> '$root/stragglers'" "$root/stub/claude"
  rc=0; env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 MEUTE_SCOPE=on \
    "$root/bin/meute" drain daily >/dev/null 2>&1 || rc=$?
  is "scope reaps: the drain completes with two fires"        "$rc:$(_drain_ran "$root")" "0:lk1 lk2"
  is "scope reaps: ...each engine call left a straggler"      "$(wc -l < "$root/stragglers" 2>/dev/null)" "2"
  sleep 1
  while read -r pid; do kill -0 "$pid" 2>/dev/null && alive+="$pid "; done < "$root/stragglers"
  is "scope reaps: ...and none outlives its run.sh"           "$alive" ""
  for pid in $alive; do kill "$pid" 2>/dev/null; done
}

# An empty --repo value is a usage error (exit 2), not a drain that matches no
# entry and exits 14 on every fire.
test_p1_3_drain_empty_repo() {
  local root="$FIXTURE/drain-emptyrepo" rc out
  _drain_fixture "$root" 2
  local env=( env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 )
  rc=0; out="$("${env[@]}" "$root/bin/meute" drain daily --repo "" 2>&1 >/dev/null)" || rc=$?
  is "drain --repo '': usage error exit 2" "$rc" "2"
  is "drain --repo '': names the empty value" "$(grep -c 'needs a non-empty' <<<"$out")" "1"
  : > "$root/state/log"
  rc=0; "${env[@]}" "$root/bin/meute" drain daily --repo lk1 --repo "" >/dev/null 2>&1 || rc=$?
  is "drain --repo lk1 --repo '': also a usage error" "$rc:$(_drain_ran "$root")" "2:"
}

# P2.2 (R18): state/reports is a read-modify-write with no lock, and the web
# server is threaded, so two triage decisions landing together kept only one.
# Twenty parallel dismissals of different findings must leave twenty rows,
# every round; kv_set and kv_del take the same lock as kv_set_row.
test_kv_writes_locked() {
  local root="$FIXTURE/kvlock" id="alpha/kvlock-2026-01-01" round n rows lost=0
  mkdir -p "$root/state" "$root/reports/alpha"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"
  printf '# kvlock\n' > "$root/reports/${id}.md"
  for (( round = 1; round <= 10; round++ )); do
    rm -f "$root/state/reports"
    for (( n = 1; n <= 20; n++ )); do
      "$root/bin/meute" dismiss "$id" -f "$n" -r other -m "round $round" >/dev/null 2>&1 &
    done
    wait
    rows="$(grep -c "^${id}#" "$root/state/reports" 2>/dev/null || true)"
    [[ "$rows" == 20 ]] || lost=$(( lost + 1 ))
  done
  is "p2.2 kv lock: 20 parallel dismissals keep 20 rows in each of 10 rounds" "$lost rounds lost rows" "0 rounds lost rows"

  local f="$root/state/kv"
  rm -f "$f"
  for (( n = 1; n <= 20; n++ )); do ( source "$REPO/lib/state.sh"; kv_set "$f" "k$n" "v$n" ) & done
  wait
  is "p2.2 kv lock: 20 parallel kv_set calls keep 20 rows" "$(wc -l < "$f")" "20"
  for (( n = 1; n <= 20; n++ )); do ( source "$REPO/lib/state.sh"; kv_del "$f" "k$n" ) & done
  wait
  is "p2.2 kv lock: 20 parallel kv_del calls leave no row" "$(wc -l < "$f")" "0"
  is "p2.2 kv lock: no scratch file is left beside the store" "$(ls -A "$root/state" | grep -c '^\.kv\.')" "0"
  is "p2.2 kv lock: the lock file never reaches the public harness" \
     "$(git -C "$REPO" check-ignore -q -- state/reports.lock; echo $?)" "0"
}
