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
