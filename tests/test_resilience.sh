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
