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
