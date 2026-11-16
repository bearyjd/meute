# Resilience tests (meute-resilience-plan.md, Phase 0 onward). Sourced from
# tests/test_meute.sh, which supplies REPO, FIXTURE and the ok/bad/is/has
# helpers; nothing here runs on its own.

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
  _strict "a death no die() reports is 70" 70 env TMPDIR=/nonexistent "${run[@]}" daily --strict-exit
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
