# Resilience tests (docs plan: .omc/plans/meute-resilience-plan.md). Sourced
# from tests/test_meute.sh, which supplies ok/bad/is/has, $REPO and $FIXTURE.

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

  # A crashing inbox.py: stderr is shown, a warning is printed, exit is non-zero.
  printf 'import sys\nsys.stderr.write("boom-from-inbox\\n")\nsys.exit(3)\n' > "$root/lib/inbox.py"
  rc=0; out="$("$root/bin/meute" findings --new 2>&1)" || rc=$?
  is  "p0.5: findings exits non-zero when inbox.py crashes" "$(( rc != 0 ))" "1"
  has "p0.5: findings shows the inbox.py error" "$out" "boom-from-inbox"
  has "p0.5: findings warns instead of 'no new findings'" "$out" "meute: findings failed"
  is  "p0.5: no false 'no new findings' on crash" "$(grep -c 'no new findings' <<< "$out")" "0"
}
