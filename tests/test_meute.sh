#!/usr/bin/env bash
#
# Tests for bin/meute and its helpers.
#
#   bash tests/test_meute.sh
#
# Builds a throwaway MEUTE_ROOT in a temp dir: bin/ and lib/ are symlinked back
# to the real ones, so MEUTE_ROOT resolves to the fixture via BASH_SOURCE and no
# code needs an environment override to be testable. The real state/ and
# reports/ are never touched; the last assertion proves it.
#
set -uo pipefail

# Hermetic against an ambient MEUTE_ROOT. bin/meute is documented as sourceable
# (that is how the timer helpers are tested) and sourcing it exports MEUTE_ROOT;
# contrib/quota-self-budget.sh then deliberately prefers the inherited value
# over deriving its own. So a shell that has sourced bin/meute makes the budget
# tests read the REAL state/log instead of the fixture's, and five of them fail
# with nothing to indicate why. Found exactly that way.
unset MEUTE_ROOT

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAILED=0
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

ok()   { printf '  ok    %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAILED=$(( FAILED + 1 )); }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$3], got [$2]"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "[$2] does not contain [$3]"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "[$2] unexpectedly contains [$3]"; }
# A skip is visible and counts as neither: a test that cannot run here must not
# read as a pass, and must not fail a suite on a host that lacks the facility.
skip() { printf '  skip  %s\n        %s\n' "$1" "$2"; }

meute() { "$FIXTURE/bin/meute" "$@"; }
report() { python3 "$REPO/lib/report.py" "$@"; }

# One manifest, many single-field mutations: the PRP-004 schema tests each
# break exactly one rule of a manifest that otherwise validates, so the message
# they see is that rule's and not a bystander's. `d` is the loaded document.
yaml_edit() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
src, dst, code = sys.argv[1:4]
d = yaml.safe_load(open(src))
exec(code)
yaml.safe_dump(d, open(dst, "w"), sort_keys=False)
PY
}
validate() { MEUTE_ROOT="${2:-$(dirname "$1")}" python3 "$REPO/lib/manifest.py" validate "$1" 2>&1 || true; }

# ---------------------------------------------------------------- fixture ---
setup() {
  mkdir -p "$FIXTURE"/{state,tasks,reports/alpha,reports/beta}
  ln -s "$REPO/bin" "$FIXTURE/bin"
  ln -s "$REPO/lib" "$FIXTURE/lib"
  cp "$REPO"/tasks/*.md "$FIXTURE/tasks/"
  printf 'Ticket {{TICKET_ID}} {{TICKET_TITLE}} {{TICKET_NOTES}} {{REPO_NAME}} {{REPO_SPEC}} {{REPO_PATH}} {{TASK}} {{TIER}} {{DATE}} {{BRANCH}} {{FILE_BUDGET}} {{LENS}} {{REPORT_PATH}} {{DEFAULT_BRANCH}} {{ALLOWED_COMMANDS}} {{UPSTREAM}} {{ETIQUETTE}}\n' \
    > "$FIXTURE/tasks/draft-ticket.md"

  local repo
  for repo in alpha beta; do
    mkdir -p "$FIXTURE/git-$repo"
    git -C "$FIXTURE/git-$repo" init -q -b main
    echo x > "$FIXTURE/git-$repo/f.txt"
    git -C "$FIXTURE/git-$repo" add -A
    git -C "$FIXTURE/git-$repo" -c user.email=t@t -c user.name=t commit -qm init
  done

  python3 - "$FIXTURE" <<'PY'
import sys, pathlib, yaml
fx = pathlib.Path(sys.argv[1])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.20,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {
        "tier1": {"tools": "Read", "permission_mode": "acceptEdits", "writes_code": True, "network": "proxied"},
        "tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"},
        "tier3": {"tools": "Read", "permission_mode": "acceptEdits", "writes_code": True, "network": "proxied"},
    },
    "tasks": {
        "audit-security": {"tier": "tier2", "template": "tasks/audit-security.md",
                           "slots": ["daily"], "lenses": ["injection", "auth"]},
        "gen-tests": {"tier": "tier1", "template": "tasks/gen-tests.md", "slots": ["weekly"]},
        "draft-ticket": {"tier": "tier3", "template": "tasks/draft-ticket.md",
                         "slots": ["weekly"], "requires_specced_ticket": True},
    },
    "repos": [
        {"name": "alpha", "path": str(fx / "git-alpha"), "spec": "fixture alpha",
         "tasks": ["audit-security", "draft-ticket"]},
        {"name": "beta", "path": str(fx / "git-beta"), "spec": "fixture beta",
         "tasks": ["gen-tests"]},
    ],
    "community": [],
}, open(fx / "repos.yaml", "w"), sort_keys=False)
PY

  cat > "$FIXTURE/reports/alpha/audit-security-2026-08-28.md" <<'MD'
---
repo: alpha
task: audit-security
tier: tier2
lens: injection
started: 2026-08-28T03:00:00-04:00
status: ok
---

## Summary
Findings present.

## Findings

### [CRITICAL] SQL injection in lookup
- **Location:** `src/db.py:88`

### [HIGH] Path traversal in export
- **Location:** `src/export.py:22`

### [HIGH] Unvalidated header
- **Location:** `src/web.py:14`
MD

  # beta has no draft-ticket task wired (tasks: [gen-tests] only) -- promoting
  # a finding here must warn, not silently write a ticket nothing will draft.
  cat > "$FIXTURE/reports/beta/audit-security-2026-08-28.md" <<'MD'
---
repo: beta
task: audit-security
tier: tier2
lens: injection
started: 2026-08-28T03:00:00-04:00
status: ok
---

## Summary
Findings present.

## Findings

### [HIGH] Unvalidated redirect
- **Location:** `src/web.py:40`
MD

  cat > "$FIXTURE/reports/beta/gen-tests-2026-08-27.md" <<'MD'
---
repo: beta
task: gen-tests
tier: tier1
started: 2026-08-27T04:00:00-04:00
status: ok
---

## Summary
Coverage added.

## Environment
- Suite status when I left: green, 4 passed.

## Tests added
### 1. `test_a`
### 2. `test_b`
### 3. `test_c`
### 4. `test_d`
MD

  cat > "$FIXTURE/reports/alpha/audit-security-2026-08-20.md" <<'MD'
---
repo: alpha
task: audit-security
lens: auth
started: 2026-08-20T03:00:00-04:00
status: ok
---

## Summary
Clean.

## Findings

No findings under the auth lens within this run's budget.
MD

  cat > "$FIXTURE/reports/beta/gen-tests-2026-08-10.md" <<'MD'
---
repo: beta
task: gen-tests
started: 2026-08-10T04:00:00-04:00
status: error
---

# Run produced no report

**Status:** error — engine exited 124
MD

  # Dedicated to test_resolve -- its own report/finding, untouched by anything
  # else, so marking it doesn't disturb test_finding_level_triage's assumption
  # that alpha/audit-security-2026-08-28's own findings stay untouched by
  # other tests until it runs.
  cat > "$FIXTURE/reports/alpha/audit-security-2026-08-30.md" <<'MD'
---
repo: alpha
task: audit-security
tier: tier2
lens: input-parsing
started: 2026-08-30T03:00:00-04:00
status: ok
---

## Summary
Findings present.

## Findings

### [HIGH] Unescaped notes field corrupts the section parser
- **Location:** `src/journal.py:130`
MD

  : > "$FIXTURE/state/log"
}

# ------------------------------------------------------------------ tests ---
test_summaries() {
  is "summary: audit with findings"  "$(report summary "$FIXTURE/reports/alpha/audit-security-2026-08-28.md")" "CRIT×1 HIGH×2"
  is "summary: audit with none"      "$(report summary "$FIXTURE/reports/alpha/audit-security-2026-08-20.md")" "no findings"
  is "summary: gen-tests green"      "$(report summary "$FIXTURE/reports/beta/gen-tests-2026-08-27.md")"       "+4 tests, green"
  is "summary: failed run"           "$(report summary "$FIXTURE/reports/beta/gen-tests-2026-08-10.md")"       "run failed (error)"

  local findings; findings="$(report findings "$FIXTURE/reports/alpha/audit-security-2026-08-28.md")"
  is "findings: count"    "$(jq 'length' <<< "$findings")" "3"
  is "findings: severity" "$(jq -r '.[0].severity' <<< "$findings")" "CRITICAL"
  is "findings: location" "$(jq -r '.[0].location' <<< "$findings")" "src/db.py:88"

  report findings "$FIXTURE/reports/beta/gen-tests-2026-08-27.md" >/dev/null 2>&1
  is "findings: refused on gen-tests" "$?" "2"
}

test_listing() {
  local out; out="$(meute reports --new 2>&1)"
  has "reports: lists new audit"  "$out" "alpha"
  has "reports: lists new tests"  "$out" "beta"
  is  "reports: 6 unread"         "$(meute reports --new 2>/dev/null | grep -c '^NEW')" "6"
}

test_show_marks_read() {
  local out; out="$(meute show alpha/audit-security-2026-08-28 2>/dev/null)"
  is   "show: stdout starts with front-matter" "$(head -1 <<< "$out")" "---"
  hasnt "show: stdout carries no chatter"      "$out" "meute:"
  has  "show: marks read" "$(meute reports --all 2>/dev/null | grep 'audit-security   2026-08-28')" "read"
  is   "show: unknown id fails" "$(meute show alpha/nope >/dev/null 2>&1; echo $?)" "1"
}

test_promote() {
  local before after ticket
  before="$(md5sum "$FIXTURE/repos.yaml" | cut -d' ' -f1)"
  local promote_out
  promote_out="$(meute promote alpha/audit-security-2026-08-28 -f 1 2>&1)"
  after="$(md5sum "$FIXTURE/repos.yaml" | cut -d' ' -f1)"
  is "promote: repos.yaml never written" "$after" "$before"
  # alpha DOES have draft-ticket wired -- pins the other side of the branch the
  # beta case below exercises. Without this, inverting the condition only
  # trips the beta assertion; alpha would silently get the wrong message too.
  has "promote: a repo with a drafting task gets the real message, not the warning" \
      "$promote_out" "tier-3 will pick it up next weekly slot"
  hasnt "promote: ...and not the warning" "$promote_out" "no task wired to draft"

  ticket="$(python3 -c "
import yaml; d = yaml.safe_load(open('$FIXTURE/state/tickets.yaml'))
t = d['tickets']['alpha'][0]; print(t['id'], t['specced'], t['source'])")"
  is  "promote: ticket id derived"  "$(cut -d' ' -f1 <<< "$ticket")" "AL-1"
  is  "promote: specced is true"    "$(cut -d' ' -f2 <<< "$ticket")" "True"
  has "promote: records its source" "$ticket" "alpha/audit-security-2026-08-28"
  # The FINDING is actioned; the report is not, because two findings in it still
  # await a decision. Closing the report here is what used to hide them.
  has "promote: the finding is actioned" \
      "$(grep 'audit-security-2026-08-28#1' "$FIXTURE/state/reports")" "actioned"
  has "promote: the report stays open while siblings await a decision" \
      "$(meute reports --all 2>/dev/null | grep '2026-08-28')" "read"

  local queued
  queued="$(MEUTE_ROOT="$FIXTURE" python3 "$REPO/lib/manifest.py" queue "$FIXTURE/repos.yaml" weekly \
            | jq -r 'select(.tier=="tier3") | .key')"
  is "promote: ticket reaches the tier-3 queue" "$queued" "alpha/draft-ticket/AL-1"

  is "promote: bad finding number fails" \
     "$(meute promote alpha/audit-security-2026-08-28 -f 99 >/dev/null 2>&1; echo $?)" "1"

  # beta has no task wired to consume specced tickets (tasks: [gen-tests] only).
  # Writing BT-1 there is a real ticket that will sit unpicked forever -- this
  # is the exact shape of gap that let BB-1 (bascule-bluetooth) silently stall.
  local out
  out="$(meute promote beta/audit-security-2026-08-28 -f 1 2>&1)"
  has "promote: warns when the repo has no drafting task" "$out" "no task wired to draft"
  has "promote: still writes the ticket"                  "$out" "written to state/tickets.yaml"
  local be1_queued
  be1_queued="$(MEUTE_ROOT="$FIXTURE" python3 "$REPO/lib/manifest.py" queue "$FIXTURE/repos.yaml" weekly \
                | jq -r 'select(.ticket_id=="BE-1") | .key')"
  is "promote: and indeed it never reaches any queue" "$be1_queued" ""
}

test_cap() {
  git -C "$FIXTURE/git-alpha" branch meute/draft-ticket-2026-08-01 >/dev/null 2>&1
  git -C "$FIXTURE/git-alpha" branch meute/draft-ticket-2026-08-02 >/dev/null 2>&1
  git -C "$FIXTURE/git-alpha" branch meute/draft-ticket-2026-08-03 >/dev/null 2>&1
  local count_before out
  count_before="$(python3 -c "
import yaml; print(len(yaml.safe_load(open('$FIXTURE/state/tickets.yaml'))['tickets']['alpha']))")"
  out="$(meute promote alpha/audit-security-2026-08-28 -f 2 2>&1)"
  has "cap: promote refused at the cap" "$out" "already in flight"
  is  "cap: nothing was written" "$(python3 -c "
import yaml; print(len(yaml.safe_load(open('$FIXTURE/state/tickets.yaml'))['tickets']['alpha']))")" "$count_before"
  has "branches: lists drafts in flight" "$(meute branches 2>&1)" "meute/draft-ticket-2026-08-01"
}

test_dismiss_and_edges() {
  local rc
  meute dismiss beta/gen-tests-2026-08-27 -m "not worth it" >/dev/null 2>&1; rc=$?
  is "dismiss: refuses without a reason"  "$rc" "1"
  meute dismiss beta/gen-tests-2026-08-27 -r nonsense >/dev/null 2>&1; rc=$?
  is "dismiss: refuses an unknown reason" "$rc" "1"
  meute dismiss beta/gen-tests-2026-08-27 -r wont-fix -m "not worth it" >/dev/null 2>&1
  has "dismiss: state recorded" "$(meute reports --all 2>/dev/null | grep 'gen-tests        2026-08-27')" "dismissed"
  has "dismiss: enum reason kept" "$(cat "$FIXTURE/state/reports")" "wont-fix"
  has "dismiss: free text kept"   "$(cat "$FIXTURE/state/reports")" "not worth it"

  rm "$FIXTURE/reports/alpha/audit-security-2026-08-20.md"
  local out; out="$(meute reports --all 2>&1)"
  hasnt "stale row for a deleted report is skipped" "$out" "2026-08-20"

  local status; status="$(meute status 2>&1)"
  has "status: runs without error" "$status" "tier-3 in flight"
  has "status: labels the displayed balance Claude-only" "$status" "Claude quota"
  has "status: says unwired Codex is unavailable" "$status" "Codex quota unavailable"
  is  "unknown command exits 1"    "$(meute frobnicate >/dev/null 2>&1; echo $?)" "1"
}

# resolve is for a finding fixed directly (a PR against the target repo), not
# routed through promote's tier-3 ticket flow. The outcome must be "actioned",
# distinct from dismiss's "dismissed" -- dismissing something that was
# actually fixed would record the opposite of what happened.
test_resolve() {
  local rc
  meute resolve alpha/audit-security-2026-08-30 -f 1 >/dev/null 2>&1; rc=$?
  is "resolve: refuses without -m" "$rc" "1"

  meute resolve alpha/audit-security-2026-08-30 -f 1 -m "fixed in owner/repo#2" >/dev/null 2>&1
  local row; row="$(grep 'alpha/audit-security-2026-08-30#1' "$FIXTURE/state/reports")"
  is  "resolve: recorded as actioned, not dismissed" "$(awk -F'\t' '{print $2}' <<< "$row")" "actioned"
  has "resolve: the message is kept"                  "$row" "fixed in owner/repo#2"

  has "resolve: report closes (single finding, now settled)" \
      "$(meute reports --all 2>/dev/null | grep '2026-08-30')" "actioned"
}

# Compares against a snapshot taken before the suite ran, rather than demanding a
# clean tree: the operator may legitimately have uncommitted state, and this must
# still catch the suite itself writing outside its fixture.
# Nearly everything under the real state/ and reports/ is gitignored, so a
# porcelain listing alone is blind to exactly the files a test must never
# write there (state/plan-queue.json, a report). List every file as well;
# --ignored would collapse an already-ignored report directory to one line.
real_state_snapshot() {
  { git -C "$REPO" status --porcelain -- state reports
    find "$REPO/state" "$REPO/reports" -type f; } | sort | tr -d ' \n'
}

test_real_repo_untouched() {
  is "the real state/ and reports/ were never touched" "$(real_state_snapshot)" "$REAL_STATE_BEFORE"
}

# repos.yaml is the tracked schema documentation (repos: [] / community: [] --
# no live projects), which is exactly why nothing else in this suite exercises
# it: every other test builds its own throwaway manifest. Nothing previously
# caught a broken edit to the real file itself.
test_public_manifest_valid() {
  local out; out="$(python3 "$REPO/lib/manifest.py" validate "$REPO/repos.yaml" 2>&1)"
  is  "repos.yaml: the tracked schema doc stays valid" "$?" "0"
  has "repos.yaml: confirms which file"                "$out" "repos.yaml"
}

# Found live: veille-finance's lint-sweep hit `cargo: command not found` and
# could report nothing beyond that, because no command on the list could
# resolve a binary at all -- so the report dead-ended exactly where an
# operator needed a diagnosis.
#
# Asserted on the resolved queue entry rather than on repos.yaml's text: what
# protects a run is the allowlist that actually reaches run.sh, and the two
# lists here arrive by different routes -- lint-sweep inherits its tier's
# verify_commands, while dep-audit overrides allowed_tools with the separate
# audit_commands anchor. Fixing one says nothing about the other, so both are
# pinned. The fixture starts from the real tracked manifest (repos.yaml ships
# `repos: []`, so it only needs a repo to schedule) to keep this testing the
# shipped anchors and not a copy that can drift away from them.
test_binary_probe_allowlisted() {
  local root="$FIXTURE/binary-probe"; mkdir -p "$root"
  python3 - "$REPO/repos.yaml" "$root" <<'PY'
import sys, pathlib, yaml
d = yaml.safe_load(open(sys.argv[1]))
root = pathlib.Path(sys.argv[2])
d["repos"] = [{"name": "probe", "path": str(root), "spec": "fixture probe",
               "tasks": ["lint-sweep", "dep-audit"]}]
yaml.safe_dump(d, open(root / "repos.yaml", "w"), sort_keys=False)
PY

  # MEUTE_ROOT stays the real repo so the task templates resolve; the fixture
  # supplies only the repo entry that repos.yaml deliberately ships without.
  local daily weekly lint audit
  daily="$(MEUTE_ROOT="$REPO" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" daily)"
  weekly="$(MEUTE_ROOT="$REPO" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly)"
  lint="$(jq -r 'select(.task=="lint-sweep").allowed_tools' <<< "$daily")"
  audit="$(jq -r 'select(.task=="dep-audit").allowed_tools' <<< "$weekly")"

  # Anchor the negative assertions below: every `hasnt` here would pass on an
  # empty string, so a fixture that silently queued nothing would look clean.
  is "binary probe: the fixture really did queue a tier-1 entry" \
     "$(jq -r 'select(.task=="lint-sweep").tier' <<< "$daily")" "tier1"
  is "binary probe: ...and the dep-audit entry too" \
     "$(jq -r 'select(.task=="dep-audit").task' <<< "$weekly")" "dep-audit"

  has "binary probe: a tier-1 run can resolve a name against PATH" \
      "$lint"  "Bash(command -v:*)"
  has "binary probe: ...and through which as well" \
      "$lint"  "Bash(which:*)"
  has "binary probe: dep-audit's scanner list can resolve one too" \
      "$audit" "Bash(command -v:*)"
  has "binary probe: ...and through which as well (dep-audit)" \
      "$audit" "Bash(which:*)"

  # Resolving a name is not the same as gaining a shell. The exclusions the
  # comment block above these anchors promises must survive the addition --
  # `echo $PATH` in particular would need the expansion an interpreter gives.
  hasnt "binary probe: still no interpreter on the list" "$lint" "Bash(bash -c"
  hasnt "binary probe: still no echo on the list"        "$lint" "Bash(echo"
  hasnt "binary probe: still no source on the list"      "$lint" "Bash(source"
}

# architecture-review is wired the same way audit-security already is (tier2,
# lens rotation via the generic queue mechanism) -- this pins that the new
# task definition itself is shaped correctly, not the rotation mechanism,
# which audit-security's own fixtures already exercise.
test_architecture_review_queued() {
  local root="$FIXTURE/arch-review"
  mkdir -p "$root"/{state,tasks}
  ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO/tasks/architecture-review.md" "$root/tasks/"
  mkdir -p "$root/git-gamma"
  git -C "$root/git-gamma" init -q -b main
  echo x > "$root/git-gamma/f.txt"
  git -C "$root/git-gamma" add -A
  git -C "$root/git-gamma" -c user.email=t@t -c user.name=t commit -qm init

  python3 - "$root" <<'PY'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read,Grep,Glob", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {
        "architecture-review": {
            "tier": "tier2", "template": "tasks/architecture-review.md",
            "slots": ["weekly"], "model": "opus",
            "lenses": ["coupling", "layering", "duplication", "boundaries"],
        },
    },
    "repos": [{"name": "gamma", "path": str(root / "git-gamma"), "spec": "fixture gamma",
               "tasks": ["architecture-review"]}],
    "community": [],
}, open(root / "repos.yaml", "w"), sort_keys=False)
PY

  local entry
  entry="$(python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -c 'select(.repo=="gamma")')"
  is  "architecture-review: reaches the weekly queue" "$(jq -r '.task' <<< "$entry")" "architecture-review"
  is  "architecture-review: runs at tier2, read-only" "$(jq -r '.tier' <<< "$entry")" "tier2"
  is  "architecture-review: writes_code is false"     "$(jq -r '.writes_code' <<< "$entry")" "false"
  is  "architecture-review: uses the model set for it" "$(jq -r '.model' <<< "$entry")" "opus"
  has "architecture-review: the lens rotation is wired" "$(jq -c '.lenses' <<< "$entry")" "coupling"
}

# market-comparison is the one task that needs the public web, so it gets its
# own tier (tier2-web) rather than adding WebSearch/WebFetch to plain tier2 --
# the assertion that matters here is that audit-security and
# architecture-review, sharing this same fixture manifest, do NOT pick up
# network tools just because a sibling task's tier gained them.
test_market_comparison_queued() {
  local root="$FIXTURE/market-comparison"
  mkdir -p "$root"/{state,tasks}
  ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO/tasks/market-comparison.md" "$REPO/tasks/architecture-review.md" "$root/tasks/"
  mkdir -p "$root/git-delta"
  git -C "$root/git-delta" init -q -b main
  echo x > "$root/git-delta/f.txt"
  git -C "$root/git-delta" add -A
  git -C "$root/git-delta" -c user.email=t@t -c user.name=t commit -qm init

  python3 - "$root" <<'PY'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {
        "tier2": {"tools": "Read,Grep,Glob", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"},
        "tier2-web": {"tools": "Read,Grep,Glob,WebSearch,WebFetch", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"},
    },
    "tasks": {
        "architecture-review": {
            "tier": "tier2", "template": "tasks/architecture-review.md",
            "slots": ["weekly"], "lenses": ["coupling"],
        },
        "market-comparison": {
            "tier": "tier2-web", "template": "tasks/market-comparison.md",
            "slots": ["weekly"], "model": "opus",
            "lenses": ["direct-alternatives", "feature-gap", "approach-divergence"],
        },
    },
    "repos": [{"name": "delta", "path": str(root / "git-delta"), "spec": "fixture delta",
               "tasks": ["architecture-review", "market-comparison"]}],
    "community": [],
}, open(root / "repos.yaml", "w"), sort_keys=False)
PY

  local mc_entry ar_entry
  mc_entry="$(python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -c 'select(.task=="market-comparison")')"
  ar_entry="$(python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -c 'select(.task=="architecture-review")')"

  is  "market-comparison: runs at tier2-web"          "$(jq -r '.tier' <<< "$mc_entry")" "tier2-web"
  is  "market-comparison: writes_code is false"       "$(jq -r '.writes_code' <<< "$mc_entry")" "false"
  is  "market-comparison: uses the model set for it"  "$(jq -r '.model' <<< "$mc_entry")" "opus"
  has "market-comparison: gets WebSearch"              "$(jq -r '.tools' <<< "$mc_entry")" "WebSearch"
  has "market-comparison: gets WebFetch"                "$(jq -r '.tools' <<< "$mc_entry")" "WebFetch"
  has "market-comparison: the lens rotation is wired"  "$(jq -c '.lenses' <<< "$mc_entry")" "direct-alternatives"
  hasnt "market-comparison: no Bash, can't act on fetched content" "$(jq -r '.tools' <<< "$mc_entry")" "Bash"

  hasnt "architecture-review: does NOT inherit WebSearch from a sibling task" \
        "$(jq -r '.tools' <<< "$ar_entry")" "WebSearch"

  # `tools` makes a tool exist; dontAsk denies anything that would have asked,
  # and the web tools ask. The first real run had all three lookups refused.
  # The public manifest is the schema doc, so pin the fix there, at the point
  # the runner reads it -- the resolved queue entry, not the YAML text.
  local pub_entry
  pub_entry="$(python3 - "$REPO/repos.yaml" <<'PY2'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(d["tiers"]["tier2-web"].get("allowed_tools", ""))
PY2
)"
  has "tier2-web: allows WebSearch, not merely offers it"  "$pub_entry" "WebSearch"
  has "tier2-web: allows WebFetch on every domain"          "$pub_entry" "WebFetch(domain:*)"
}

# lib/manifest.py add-repo is the mechanism `meute discover` writes through.
# Tested directly (no stdin plumbing) so the invariants that matter -- refuses
# repos.yaml, dedups, validates before ever touching disk -- are pinned at the
# unit that actually enforces them.
test_add_repo() {
  local root="$FIXTURE/add-repo"
  mkdir -p "$root"/tasks
  cp "$REPO/tasks/audit-security.md" "$root/tasks/"
  local g
  for g in git-existing git-newcomer; do
    mkdir -p "$root/$g"
    git -C "$root/$g" init -q -b main
    echo x > "$root/$g/f.txt"
    git -C "$root/$g" add -A
    git -C "$root/$g" -c user.email=t@t -c user.name=t commit -qm init
  done

  python3 - "$root" <<'PY'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read,Grep,Glob", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"audit-security": {"tier": "tier2", "template": "tasks/audit-security.md", "slots": ["daily"]}},
    "repos": [{"name": "existing", "path": str(root / "git-existing"), "spec": "already here",
               "tasks": ["audit-security"]}],
    "community": [],
}, open(root / "repos.local.yaml", "w"), sort_keys=False)
PY
  local manifest="$root/repos.local.yaml"
  export MEUTE_ROOT="$root"

  local before after out
  before="$(cat "$manifest")"

  out="$(python3 "$REPO/lib/manifest.py" add-repo "$REPO/repos.yaml" '{"name":"x","path":"/tmp","spec":"s"}' 2>&1)"
  has  "add-repo: refuses to write the tracked repos.yaml" "$out" "refusing to write repos.yaml"

  out="$(python3 "$REPO/lib/manifest.py" add-repo "$manifest" '{"name":"existing","path":"/tmp/y","spec":"s"}' 2>&1)"
  has  "add-repo: rejects a duplicate name"                "$out" "already configured"
  after="$(cat "$manifest")"
  is   "add-repo: duplicate-name rejection touches nothing" "$after" "$before"

  out="$(python3 "$REPO/lib/manifest.py" add-repo "$manifest" \
        "$(printf '{"name":"other","path":"%s","spec":"s"}' "$root/git-existing")" 2>&1)"
  has  "add-repo: rejects a duplicate path under a new name" "$out" "already configured"

  out="$(python3 "$REPO/lib/manifest.py" add-repo "$manifest" '{"name":"Not Valid","path":"/tmp/z","spec":"s"}' 2>&1)"
  has  "add-repo: rejects an invalid name"                 "$out" "must match"

  before="$(cat "$manifest")"
  out="$(python3 "$REPO/lib/manifest.py" add-repo "$manifest" \
        '{"name":"bad-task","path":"/tmp/z","spec":"s","tasks":["nonexistent-task"]}' 2>&1)"
  has  "add-repo: an unknown task fails validation"        "$out" "undeclared task"
  after="$(cat "$manifest")"
  is   "add-repo: validation runs before any write, not after" "$after" "$before"

  local added
  added="$(python3 "$REPO/lib/manifest.py" add-repo "$manifest" \
        "$(printf '{"name":"newcomer","path":"%s","spec":"a new one","tasks":["audit-security"]}' "$root/git-newcomer")")"
  is   "add-repo: happy path returns the new name"          "$added" "newcomer"
  [[ -f "${manifest}.bak" ]] && ok "add-repo: backs up the manifest before writing" \
    || bad "add-repo: backs up the manifest before writing" "no .bak file found"

  local entry
  entry="$(python3 "$REPO/lib/manifest.py" queue "$manifest" daily | jq -c 'select(.repo=="newcomer")')"
  is   "add-repo: the new repo actually reaches the queue" "$(jq -r '.repo' <<< "$entry")" "newcomer"

  unset MEUTE_ROOT
}

# The interactive picker itself: excludes the manifest's own checkout and
# already-configured paths, cancels cleanly, and honors both the default task
# preselection and an explicit override.
#
# `universe` is the directory `discover` scans; `root` (one of its own
# children) stands in for meute-ai-trader's own checkout -- exactly the real
# layout, where meute-ai-trader lives inside the same ~/Documents/vibe-code
# it's asked to scan. repo-alpha/repo-beta/already-configured are its siblings.
test_discover() {
  local universe="$FIXTURE/discover-universe"
  local root="$universe/meute-stand-in"
  mkdir -p "$root"/{state,tasks}
  ln -sfn "$REPO/bin" "$root/bin"
  ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO/tasks/audit-security.md" "$REPO/tasks/architecture-review.md" "$root/tasks/"
  git -C "$root" init -q -b main
  echo x > "$root/f.txt"; git -C "$root" add -A
  git -C "$root" -c user.email=t@t -c user.name=t commit -qm init

  local r
  for r in repo-alpha repo-beta already-configured; do
    mkdir -p "$universe/$r"
    git -C "$universe/$r" init -q -b main
    echo x > "$universe/$r/f.txt"
    git -C "$universe/$r" add -A
    git -C "$universe/$r" -c user.email=t@t -c user.name=t commit -qm init
  done

  python3 - "$root" "$universe" <<'PY'
import sys, pathlib, yaml
root, universe = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read,Grep,Glob", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {
        "audit-security": {"tier": "tier2", "template": "tasks/audit-security.md", "slots": ["daily"]},
        "architecture-review": {"tier": "tier2", "template": "tasks/architecture-review.md", "slots": ["weekly"]},
    },
    "repos": [{"name": "already-configured", "path": str(universe / "already-configured"),
               "spec": "already here", "tasks": ["audit-security"]}],
    "community": [],
}, open(root / "repos.local.yaml", "w"), sort_keys=False)
PY

  local out before after
  out="$(printf '\n' | "$root/bin/meute" discover "$universe" 2>&1)"
  has   "discover: lists an undiscovered repo"          "$out" "repo-alpha"
  has   "discover: lists the other undiscovered repo"   "$out" "repo-beta"
  hasnt "discover: excludes the meute checkout itself"  "$out" "meute-stand-in"
  hasnt "discover: excludes an already-configured path" "$out" "already-configured"

  before="$(cat "$root/repos.local.yaml")"
  printf '\n' | "$root/bin/meute" discover "$universe" >/dev/null 2>&1
  after="$(cat "$root/repos.local.yaml")"
  is    "discover: blank input cancels, manifest untouched" "$after" "$before"

  # repo-alpha and repo-beta are the only two real candidates; select the
  # first (alphabetically first in scan order), accept the default task
  # preselection, then supply the required spec.
  printf '1\n\nfixture alpha spec\n' | "$root/bin/meute" discover "$universe" >/dev/null 2>&1
  has "discover: default selection picks up both read-only tasks" \
      "$(python3 -c "
import yaml
data = yaml.safe_load(open('$root/repos.local.yaml'))
for p in data['repos']:
    if p['spec'] == 'fixture alpha spec':
        print(sorted(p.get('tasks') or []))
")" "audit-security"

  # With repo-alpha now configured, only repo-beta remains -- pick it
  # (now index 1), override tasks to just one, and confirm the pre-existing
  # entry and manifest scaffolding survive untouched.
  printf '1\n2\nfixture beta spec\n' | "$root/bin/meute" discover "$universe" >/dev/null 2>&1
  local check
  check="$(python3 - "$root/repos.local.yaml" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
print("names", sorted(p["name"] for p in data["repos"]))
print("version", data["version"])
print("tiers", sorted(data["tiers"]))
for p in data["repos"]:
    if p["name"] == "already-configured":
        print("preserved-spec", p["spec"])
    if p["spec"] == "fixture beta spec":
        print("beta-tasks", sorted(p.get("tasks") or []))
PY
)"
  has "discover: custom task selection overrides the default" "$check" "beta-tasks ['architecture-review']"
  has "discover: leaves the pre-existing entry intact"         "$check" "preserved-spec already here"
  has "discover: leaves manifest scaffolding intact"           "$check" "tiers ['tier2']"
}

# Everything a staged plan writes under state/ names private repositories by
# absolute path; the ignore rules are the only thing keeping it off a public
# remote, so every file the plan can create has to be covered by them.
# The runner appends `.$$` to an archive name on a same-second collision, so
# the archive pattern is anchored on the prefix only. kv_set's mktemp scratch
# (lib/state.sh) lands beside plan-complete and carries the same content.
test_plan_state_ignored() {
  local f
  for f in state/plan-queue.json state/plan-complete \
           state/plan-queue.completed-20260918T000000.json \
           state/plan-queue.completed-20260918T000000.json.123 \
           state/.plan-entries.abc state/.plan-queue.abc state/.kv.abc123; do
    is "gitignore: ${f} never reaches the public harness" \
      "$(git -C "$REPO" check-ignore -q -- "$f"; echo $?)" "0"
  done
}

# `repos.local.yaml` and one exact backup name were listed individually, so
# any other copy of the fleet config -- a dated backup taken before a schema
# migration, the one a human makes before an edit -- was untracked and
# visible. It is the same list of private repositories as the manifest, and
# the harness is public. The rule is anchored on the prefix so every copy is
# covered by the name it already has.
# The temp name is the one lib/state.sh's convention would produce, not an
# invented one, so the assertion exercises the rule it defends. `-v` names the
# file the match came from: a global core.excludesFile with *.bak or *.orig in
# it would otherwise let two of these pass without .gitignore doing any work.
test_private_manifest_copies_ignored() {
  local f
  for f in repos.local.yaml repos.local.yaml.bak \
           repos.local.yaml.pre-prp004-20260922 \
           repos.local.yaml.2026-09-22 repos.local.yaml.orig \
           .repos.local.yaml.Xa3Kd9 docs/repos.local.yaml; do
    is "gitignore: ${f} never reaches the public harness" \
      "$(git -C "$REPO" check-ignore -v -- "$f" | cut -d: -f1)" ".gitignore"
  done
  # The negative control: the rule is unanchored and matches at every depth,
  # which is right for a private list but would silently swallow the tracked
  # schema doc if the prefix ever slipped.
  is "gitignore: repos.yaml stays tracked" \
    "$(git -C "$REPO" check-ignore -q -- repos.yaml; echo $?)" "1"
  is "gitignore: state/tickets.yaml.bak never reaches the public harness" \
    "$(git -C "$REPO" check-ignore -v -- state/tickets.yaml.bak | cut -d: -f1)" ".gitignore"
}

# The web gate reads a tier's `tools` as a comma-separated string. A YAML
# list would read as "no web tools" and let a web entry through a plan that
# never allowed one, so the shape is checked where every command validates.
test_tier_tools_must_be_string() {
  local root="$FIXTURE/tier-tools"
  mkdir -p "$root"/{state,tasks}
  cp "$REPO/tasks/market-comparison.md" "$root/tasks/"
  python3 - "$root" <<'PY2'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2-web": {"tools": ["Read", "WebSearch"], "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"market-comparison": {"tier": "tier2-web", "template": "tasks/market-comparison.md", "slots": ["weekly"]}},
    "repos": [], "community": [],
}, open(root / "repos.local.yaml", "w"), sort_keys=False)
PY2
  printf '{"version":1,"scan":"%s","allow_web":false,"entries":[{"name":"plan-001-x","path":"%s","task":"market-comparison"}]}\n' \
    "$root" "$root" > "$root/state/plan-queue.json"

  local out
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" validate "$root/repos.local.yaml" 2>&1; echo "rc=$?")"
  has "tiers: list-form tools fail validation" "$out" "tiers.tier2-web.tools: must be a comma-separated string"
  has "tiers: list-form tools are an error"    "$out" "rc=2"
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.local.yaml" "$root/state/plan-queue.json" all 2>&1; echo "rc=$?")"
  has   "tiers: plan-queue rejects the manifest before expanding" "$out" "tiers.tier2-web.tools: must be a comma-separated string"
  hasnt "tiers: no web entry slips out under list-form tools"     "$out" '"key": "plan/'
}

# What a plan may stage is decided by the tier's tool list alone: local
# (Read/Grep/Glob), web (those plus WebSearch/WebFetch, an opt-in), other
# (anything else -- Bash, Edit, an MCP server, a tool this code has never
# heard of -- which only enrollment can wire up). Tool names are compared by
# the prefix before "(", the same rule the CLI's allowlist grammar uses, so
# a domain-scoped WebFetch still reads as web.
test_plan_tier_class() {
  local root="$FIXTURE/tier-class"
  mkdir -p "$root"
  python3 - "$root" <<'PY2'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
tiers = {
    "local":   "Read, Grep ,Glob",
    "web":     "Read,Grep,Glob,WebSearch,WebFetch(domain:x)",
    "webonly": "WebFetch",
    "bash":    "Read,Grep,Glob,Bash",
    "edit":    "Read,Edit",
    "mcp":     "Read,mcp__github__search",
    "unknown": "Read,Frobnicate",
    "empty":   "",
}
yaml.safe_dump({
    "version": 1,
    "tiers": {name: {"tools": tools, "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}
              for name, tools in tiers.items()},
    "tasks": {f"t-{name}": {"tier": name, "template": "tasks/x.md"} for name in tiers},
    "repos": [], "community": [],
}, open(root / "repos.yaml", "w"), sort_keys=False)
PY2
  local listing
  listing="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" list-tasks "$root/repos.yaml")"
  class_of() { jq -r --arg n "t-$1" 'select(.name == $n) | .plan_class' <<< "$listing"; }
  is "tier class: Read/Grep/Glob is local, whitespace ignored" "$(class_of local)"   "local"
  is "tier class: WebFetch(domain:x) is web"                    "$(class_of web)"     "web"
  is "tier class: web tools alone are web"                      "$(class_of webonly)" "web"
  is "tier class: Bash is other"                                "$(class_of bash)"    "other"
  is "tier class: Edit is other"                                "$(class_of edit)"    "other"
  is "tier class: an MCP tool is other"                         "$(class_of mcp)"     "other"
  is "tier class: an unknown tool is other"                     "$(class_of unknown)" "other"
  is "tier class: no tools at all reads nothing, so local"      "$(class_of empty)"   "local"
}

# On some hosts /home/<you> and /var/home/<you> are one directory via a bind
# mount, and neither `pwd -P` nor `readlink -f` unifies them. The manifest
# stores one spelling, MEUTE_ROOT takes whichever the script was invoked
# through, and a string-keyed lookup then reports every enrolled repo as
# unconfigured -- or proposes meute's own checkout. Only device+inode identity
# survives that, so the fixture builds a real bind mount in a user namespace.
# A symlinked alias covers the cheaper case the same way: the link spelling
# goes in the manifest (find will not descend a symlinked start point), and
# the scan runs on the real directory.
test_plan_identity() {
  local universe="$FIXTURE/plan-identity"
  local root="$universe/meute-stand-in"
  mkdir -p "$root"/{state,tasks}
  ln -sfn "$REPO/bin" "$root/bin"
  ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO/tasks/audit-security.md" "$root/tasks/"
  local r
  for r in meute-stand-in already-configured repo-alpha; do
    mkdir -p "$universe/$r"
    git -C "$universe/$r" init -q -b main
    echo x > "$universe/$r/f.txt"
    git -C "$universe/$r" add -A
    git -C "$universe/$r" -c user.email=t@t -c user.name=t commit -qm init
  done

  # The manifest names already-configured under whichever spelling the
  # variant under test wants; everything else is fixed.
  identity_manifest() {
    python3 - "$root" "$1" <<'PY2'
import sys, pathlib, yaml
root, configured = pathlib.Path(sys.argv[1]), sys.argv[2]
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"audit-security": {"tier": "tier2", "template": "tasks/audit-security.md", "slots": ["daily"]}},
    "repos": [{"name": "already-configured", "path": configured,
               "spec": "already here", "tasks": ["audit-security"]}],
    "community": [],
}, open(root / "repos.local.yaml", "w"), sort_keys=False)
PY2
  }

  local out
  # (b) first, since it needs no facility: manifest and MEUTE_ROOT through the
  # link, scan through the real path.
  local link="$FIXTURE/plan-link"
  ln -sfn "$universe" "$link"
  identity_manifest "$link/already-configured"
  out="$("$link/meute-stand-in/bin/meute" plan "$universe" 2>&1)"
  has   "identity: symlink spelling still matches the manifest"  "$out" "configured    already-configured"
  hasnt "identity: symlink spelling still excludes own checkout" "$out" "meute-stand-in"
  has   "identity: symlink spelling counts one configured repo"  "$out" "configured: 1"

  # And the other way round: the scan itself is asked through the link. find
  # does not descend a symlinked start point unless told to, so this found
  # nothing at all before -H.
  identity_manifest "$universe/already-configured"
  out="$("$root/bin/meute" plan "$link" 2>&1)"
  has   "identity: a symlinked scan dir is descended"              "$out" "discovered: 2 "
  has   "identity: a symlinked scan dir still matches the manifest" "$out" "configured: 1"
  hasnt "identity: a symlinked scan dir still excludes own checkout" "$out" "meute-stand-in"

  # The synthetic name is the repository's, whichever spelling found it: a
  # plan staged through a link or a bind mount must mark and retire the same
  # keys as one staged through the real path.
  staged_name() { jq -r '.entries[] | select(.path | endswith("/repo-alpha")) | .name' "$root/state/plan-queue.json" | sort -u; }
  local real_name link_name
  "$root/bin/meute" plan --enqueue "$universe" >/dev/null 2>&1; real_name="$(staged_name)"
  "$root/bin/meute" plan --enqueue "$link" >/dev/null 2>&1;     link_name="$(staged_name)"
  is "identity: a symlinked spelling stages the same synthetic name" "$link_name" "$real_name"
  is "identity: ...and it is a plan-<stem>-<hash> name" "$(grep -cE '^plan-repo-alpha-[0-9a-f]{6}$' <<< "$real_name")" "1"

  # (a) and (c): a genuine bind mount, as on the host that found this.
  local alias="$FIXTURE/plan-alias"
  mkdir -p "$alias"
  if unshare -Urm true 2>/dev/null; then
    identity_manifest "$alias/already-configured"
    out="$(unshare -Urm bash -c 'mount --bind "$1" "$2" && exec "$2/meute-stand-in/bin/meute" plan "$1"' \
             _ "$universe" "$alias" 2>&1)"
    has   "identity: bind-mount spelling still matches the manifest"  "$out" "configured    already-configured"
    hasnt "identity: bind-mount spelling still excludes own checkout" "$out" "meute-stand-in"
    has   "identity: bind-mount spelling counts one configured repo"  "$out" "configured: 1"
    unshare -Urm bash -c 'mount --bind "$1" "$2" && exec "$2/meute-stand-in/bin/meute" plan --enqueue "$2"' \
      _ "$universe" "$alias" >/dev/null 2>&1
    is "identity: a bind-mounted spelling stages the same synthetic name" "$(staged_name)" "$real_name"

    out="$(unshare -Urm bash -c 'mount --bind "$1" "$2" && exec "$2/meute-stand-in/bin/meute" discover "$1"' \
             _ "$universe" "$alias" 2>&1 </dev/null)"
    has   "identity: discover under the alias still finds the new repo"   "$out" "repo-alpha"
    hasnt "identity: discover under the alias does not re-offer a configured repo" "$out" "already-configured"
    hasnt "identity: discover under the alias does not offer own checkout" "$out" "meute-stand-in"
  else
    skip "identity: bind-mount variants" "unshare -Urm is unavailable on this host"
  fi
}

# A `.git` *file* marks a linked worktree or a vendored submodule as readily
# as a checkout. Found live: six ephemeral agent worktrees and five third-party
# submodules of already-enrolled repos, each proposed for four audits on the
# operator's quota. git itself tells the three apart.
test_plan_worktrees() {
  local universe="$FIXTURE/plan-worktrees"
  local root="$universe/meute-stand-in"
  mkdir -p "$root"/{state,tasks}
  ln -sfn "$REPO/bin" "$root/bin"
  ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO/tasks/audit-security.md" "$root/tasks/"
  local r
  for r in meute-stand-in repo-alpha repo-beta; do
    mkdir -p "$universe/$r"
    git -C "$universe/$r" init -q -b main
    echo x > "$universe/$r/f.txt"
    git -C "$universe/$r" add -A
    git -C "$universe/$r" -c user.email=t@t -c user.name=t commit -qm init
  done
  git -C "$universe/repo-alpha" worktree add -q "$universe/repo-alpha/.claude/worktrees/agent-x" -b agent-x
  git -C "$universe/repo-beta" -c protocol.file.allow=always submodule add -q "$universe/repo-alpha" vendor/alpha
  git -C "$universe/repo-beta" -c user.email=t@t -c user.name=t commit -qm vendored
  python3 - "$root" <<'PY2'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"audit-security": {"tier": "tier2", "template": "tasks/audit-security.md", "slots": ["daily"]}},
    "repos": [], "community": [],
}, open(root / "repos.local.yaml", "w"), sort_keys=False)
PY2

  local out
  out="$("$root/bin/meute" plan "$universe" 2>&1)"
  has   "worktrees: the main checkouts are still proposed"      "$out" "unconfigured  repo-alpha"
  has   "worktrees: the submodule's host is still proposed"     "$out" "unconfigured  repo-beta"
  hasnt "worktrees: a linked worktree is not a repository"      "$out" "agent-x"
  hasnt "worktrees: a vendored submodule is not a repository"   "$out" "vendor/alpha"
  hasnt "worktrees: the submodule is not proposed by basename"  "$out" "unconfigured  alpha "
  has   "worktrees: discovered counts only true repositories"   "$out" "discovered: 2 "

  # A `.git` file can point anywhere. A checkout under the scan root whose
  # repository lives outside it would have the plan audit -- and cut scratch
  # branches in -- a repository the operator never asked to scan.
  mkdir -p "$FIXTURE/elsewhere-repo" "$universe/repo-elsewhere"
  git -C "$FIXTURE/elsewhere-repo" init -q -b main
  echo x > "$FIXTURE/elsewhere-repo/f.txt"; git -C "$FIXTURE/elsewhere-repo" add -A
  git -C "$FIXTURE/elsewhere-repo" -c user.email=t@t -c user.name=t commit -qm init
  printf 'gitdir: %s/.git\n' "$FIXTURE/elsewhere-repo" > "$universe/repo-elsewhere/.git"
  out="$("$root/bin/meute" plan "$universe" 2>&1)"
  hasnt "worktrees: a checkout of a repository outside the scan root is not proposed" "$out" "unconfigured  repo-elsewhere"
  has   "worktrees: ...and the scan says why" "$out" "repo-elsewhere: git dir outside the scan root"
  has   "worktrees: the true repositories are still counted" "$out" "discovered: 2 "
}

# `plan` is the non-interactive counterpart to `discover`: it inventories the
# checkout's parent by default, recursively spots normal nested repositories,
# compares them to the manifest, and must never enroll or otherwise write one.
test_plan() {
  local universe="$FIXTURE/plan-universe"
  local root="$universe/meute-stand-in"
  mkdir -p "$root"/{state,tasks}
  ln -sfn "$REPO/bin" "$root/bin"
  ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO/tasks/audit-security.md" "$REPO/tasks/architecture-review.md" \
     "$REPO/tasks/market-comparison.md" "$REPO/tasks/scout.md" "$root/tasks/"
  git -C "$root" init -q -b main
  echo x > "$root/f.txt"; git -C "$root" add -A
  git -C "$root" -c user.email=t@t -c user.name=t commit -qm init

  local r
  for r in repo-alpha repo-beta already-configured nested/repo-gamma; do
    mkdir -p "$universe/$r"
    git -C "$universe/$r" init -q -b main
    echo x > "$universe/$r/f.txt"
    git -C "$universe/$r" add -A
    git -C "$universe/$r" -c user.email=t@t -c user.name=t commit -qm init
  done

  python3 - "$root" "$universe" <<'PY'
import sys, pathlib, yaml
root, universe = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read,Grep,Glob", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"},
              "tier2-web": {"tools": "Read,Grep,Glob,WebSearch,WebFetch", "permission_mode": "dontAsk",
                            "writes_code": False, "network": "proxied"},
              "tier2-scout": {"tools": "Read,Grep,Glob,Bash", "permission_mode": "dontAsk",
                              "allowed_tools": "Bash(gh issue list:*)", "writes_code": False, "network": "proxied"}},
    "tasks": {
        "audit-security": {"tier": "tier2", "template": "tasks/audit-security.md", "slots": ["daily"]},
        "architecture-review": {"tier": "tier2", "template": "tasks/architecture-review.md", "slots": ["weekly"]},
        "market-comparison": {"tier": "tier2-web", "template": "tasks/market-comparison.md", "slots": ["weekly"]},
        "scout": {"tier": "tier2-scout", "template": "tasks/scout.md", "slots": ["weekly"]},
    },
    "repos": [{"name": "already-configured", "path": str(universe / "already-configured"),
               "spec": "already here", "tasks": ["audit-security", "architecture-review"]}],
    "community": [],
}, open(root / "repos.local.yaml", "w"), sort_keys=False)
PY

  local before after out
  before="$(md5sum "$root/repos.local.yaml" | cut -d' ' -f1)"
  out="$("$root/bin/meute" plan 2>&1)"
  after="$(md5sum "$root/repos.local.yaml" | cut -d' ' -f1)"
  is  "plan: defaults to the meute checkout's parent" "$after" "$before"
  has "plan: identifies the manifest match" "$out" "configured    already-configured"
  has "plan: identifies unconfigured direct children" "$out" "unconfigured  repo-alpha"
  has "plan: recursively identifies nested repositories" "$out" "unconfigured  repo-gamma"
  hasnt "plan: excludes its own checkout" "$out" "meute-stand-in"
  has "plan: explains deterministic ranking" "$out" "security, architecture, features, market; path breaks ties"
  # Canonical path is the tie-breaker, so nested/repo-gamma sorts before the
  # direct children; task priority remains security then architecture.
  has "plan: ranks security before architecture for a repo" "$out" $'1. repo-gamma               audit-security'
  has "plan: follows with architecture" "$out" $'2. repo-gamma               architecture-review'
  has "plan: keeps planning read-only" "$out" "No manifest, repository, or state files were changed."
  has "plan: the preview says what staging will still create" "$out" "scratch branch and a worktree"
  out="$(MEUTE_PLAN_MAX_DEPTH=17 "$root/bin/meute" plan 2>&1; echo "rc=$?")"
  has "plan: a scan deeper than 16 is refused" "$out" "MEUTE_PLAN_MAX_DEPTH"
  has "plan: ...as an error"                   "$out" "rc=1"
  out="$(MEUTE_PLAN_MAX_DEPTH=16 "$root/bin/meute" plan 2>&1)"
  has "plan: depth 16 is the ceiling, not past it" "$out" "max depth: 16"
  # A manifest the runner would refuse is not one to plan against.
  python3 - "$root" <<'PY3'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
d = yaml.safe_load((root / "repos.local.yaml").read_text())
d["tasks"]["broken"] = {"tier": "tier2", "template": "tasks/missing.md"}
yaml.safe_dump(d, open(root / "bad.yaml", "w"), sort_keys=False)
PY3
  out="$(MEUTE_MANIFEST="$root/bad.yaml" "$root/bin/meute" plan 2>&1; echo "rc=$?")"
  has "plan: validates the manifest first" "$out" "failed validation"
  has "plan: ...and stops there"           "$out" "rc=1"
  out="$("$root/bin/meute" plan 2>&1)"

  # A read-only tier that reaches the public web would send what it learned
  # about a private, never-enrolled repository to third parties. That is an
  # explicit decision, not a default: the ranking omits it and says how to
  # opt in. The manifest reports each tier's tools so the planner can tell.
  is  "plan: list-tasks reports the tier's tools" \
    "$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" list-tasks "$root/repos.local.yaml" | jq -r 'select(.name == "market-comparison") | .tools')" \
    "Read,Grep,Glob,WebSearch,WebFetch"
  is  "plan: list-tasks classifies the web tier for the planner" \
    "$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" list-tasks "$root/repos.local.yaml" | jq -r 'select(.name == "market-comparison") | .plan_class')" \
    "web"
  hasnt "plan: a web-research task is not ranked by default" "$(grep -E '^ +[0-9]+\. ' <<< "$out")" "market-comparison"
  has   "plan: the omission is visible"   "$out" "excluded 1 web-research task(s): market-comparison"
  has   "plan: the omission says how to opt in" "$out" "pass --allow-web"
  # A read-only tier that can shell out (scout: Read,Grep,Glob,Bash behind a
  # gh allowlist) is not a plan's to stage against a never-enrolled repo:
  # the allowlist was reviewed for enrolled projects. Enrollment is the path,
  # and no flag opens it.
  hasnt "plan: a Bash tier is never ranked"          "$(grep -E '^ +[0-9]+\. ' <<< "$out")" "scout"
  has   "plan: the Bash-tier omission is visible"    "$out" "excluded 1 task(s) whose tier needs enrollment (Bash or other tools): scout"
  out="$("$root/bin/meute" plan --allow-web 2>&1)"
  has   "plan: --allow-web ranks the web-research task" "$(grep -E '^ +[0-9]+\. ' <<< "$out")" "market-comparison"
  hasnt "plan: --allow-web has no web task left to exclude" "$out" "excluded 1 web-research"
  hasnt "plan: --allow-web still does not rank a Bash tier" "$(grep -E '^ +[0-9]+\. ' <<< "$out")" "scout"
  has   "plan: --allow-web still reports the Bash-tier omission" "$out" "whose tier needs enrollment (Bash or other tools): scout"

  # A plan intentionally gives one discovered repository several distinct
  # read-only tasks.  The validator must key entries by repository *and* task,
  # not reject the second task merely because its synthetic repository name is
  # shared.
  printf 'stale\tattempted\n' > "$root/state/plan-complete"
  out="$("$root/bin/meute" plan --enqueue "$universe" 2>&1)"
  has "plan: stages several tasks for the same repository" "$out" "Staged 6 read-only analysis item(s)"
  has "plan: staging says what each run still creates in the repo" "$out" "scratch branch and a worktree"
  # Nothing to stage is an error, and one that leaves the previous plan's
  # bookkeeping alone.
  mkdir -p "$FIXTURE/plan-nothing"
  printf 'sentinel\tattempted\n' > "$root/state/plan-complete"
  out="$("$root/bin/meute" plan --enqueue "$FIXTURE/plan-nothing" 2>&1; echo "rc=$?")"
  has "plan: --enqueue with no candidates refuses" "$out" "plan: nothing to stage"
  has "plan: ...as an error"                       "$out" "rc=1"
  is  "plan: ...and leaves the previous plan's marks alone" "$(cat "$root/state/plan-complete")" $'sentinel\tattempted'
  rm -f "$root/state/plan-complete"
  is "plan: all staged entries have distinct executable keys" \
    "$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.local.yaml" "$root/state/plan-queue.json" all | jq -r .key | sort -u | wc -l)" "6"
  is "plan: enqueue clears completion marks from a prior plan" \
    "$(test -e "$root/state/plan-complete"; echo $?)" "1"
  is "plan: a default plan records that the web was not allowed" \
    "$(jq -r .allow_web "$root/state/plan-queue.json")" "false"

  # A real queue contains all six entries even though this daily timer sees
  # only the daily tasks.  A stubbed subscription preflight lets dry-run prove
  # that the staged entry reaches selection without touching a repository.
  mkdir -p "$root/stub"
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then
  printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'
  exit 0
fi
exit 1
STUB
  chmod +x "$root/stub/claude"
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily --dry-run 2>&1)"
  has "plan: multi-task staged queue is selected by the runner" "$out" "would run: key=plan/"

  # Mark every staged item attempted, as completed real runs would.  The next
  # fire archives the finite plan and selects the ordinary manifest queue
  # instead of perpetually finding an ineligible staged item.
  while IFS= read -r r; do
    printf '%s\tattempted\n' "$r" >> "$root/state/plan-complete"
  done < <(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.local.yaml" "$root/state/plan-queue.json" all | jq -r .key)
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily --dry-run 2>&1)"
  has "plan: completed queue is archived before selection" "$out" "archived queue"
  has "plan: completed queue falls back to the manifest" "$out" "would run: key=already-configured/audit-security"
  is "plan: completed queue no longer blocks future slots" "$(test -e "$root/state/plan-queue.json"; echo $?)" "1"
  is "plan: one archived record is retained" "$(find "$root/state" -name 'plan-queue.completed-*.json' | wc -l)" "1"

  # The opt-in is recorded in the plan itself, and the runner-side validator
  # holds the same line: a hand-edited plan cannot smuggle a web tier past a
  # plan that never allowed one.
  out="$("$root/bin/meute" plan --enqueue --allow-web "$universe" 2>&1)"
  has "plan: --allow-web stages the web-research task too" "$out" "Staged 9 read-only analysis item(s)"
  is  "plan: --allow-web is recorded in the staged plan" "$(jq -r .allow_web "$root/state/plan-queue.json")" "true"
  is  "plan: the runner accepts a web entry the plan allowed" \
    "$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.local.yaml" "$root/state/plan-queue.json" all >/dev/null 2>&1; echo $?)" "0"
  jq '.allow_web = false' "$root/state/plan-queue.json" > "$root/state/plan-queue.json.edit"
  mv "$root/state/plan-queue.json.edit" "$root/state/plan-queue.json"
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.local.yaml" "$root/state/plan-queue.json" all 2>&1 >/dev/null; echo "rc=$?")"
  has "plan: the runner refuses a web entry the plan did not allow" "$out" "uses web tools"
  has "plan: the refusal is an error, not a skip" "$out" "rc=2"
  jq '.allow_web = "yes"' "$root/state/plan-queue.json" > "$root/state/plan-queue.json.edit"
  mv "$root/state/plan-queue.json.edit" "$root/state/plan-queue.json"
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.local.yaml" "$root/state/plan-queue.json" all 2>&1 >/dev/null; echo "rc=$?")"
  has "plan: allow_web must be a boolean" "$out" "allow_web"
  has "plan: a non-boolean allow_web is an error" "$out" "rc=2"
  printf '{"version":1,"scan":"%s","allow_web":true,"entries":[{"name":"plan-x-000000","path":"%s","task":"scout"}]}\n' \
    "$universe" "$universe/repo-alpha" > "$root/state/plan-queue.json"
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.local.yaml" "$root/state/plan-queue.json" all 2>&1 >/dev/null; echo "rc=$?")"
  has "plan: a hand-staged Bash tier is refused even when the web was allowed" "$out" "entries[1].task 'scout' uses tools plan cannot stage"
  has "plan: ...as an error, not a skip" "$out" "rc=2"
  printf '{"version":1,"scan":"%s","allow_web":false,"entries":[{"name":"plan-x-000000","path":"%s","task":["audit-security"]}]}\n' \
    "$universe" "$universe/repo-alpha" > "$root/state/plan-queue.json"
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.local.yaml" "$root/state/plan-queue.json" all 2>&1 >/dev/null; echo "rc=$?")"
  has   "plan: a list-valued task is refused as a manifest error" "$out" "entries[1].task is not declared"
  hasnt "plan: ...not as a traceback"                             "$out" "Traceback"
  has   "plan: ...with the validator's exit code"                 "$out" "rc=2"

  # A plan's daily items drain in days while its weekly items take weeks.
  # In between, a daily slot that finds nothing eligible in the plan must
  # fall through to the manifest rather than skip until the plan retires.
  "$root/bin/meute" plan --enqueue "$universe" >/dev/null 2>&1
  while IFS= read -r r; do
    printf '%s\tattempted\n' "$r" >> "$root/state/plan-complete"
  done < <(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.local.yaml" "$root/state/plan-queue.json" daily | jq -r .key)
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily --dry-run 2>&1)"
  has "plan: a slot with no eligible staged item falls back to the manifest" "$out" "would run: key=already-configured/audit-security"
  is  "plan: the fallback keeps the plan staged for its other slot" "$(test -e "$root/state/plan-queue.json"; echo $?)" "0"
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" weekly --dry-run 2>&1)"
  has "plan: the other slot still prefers the staged plan" "$out" "would run: key=plan/"

  # A staged path that stops being a repository (an agent worktree torn down
  # between staging and its turn) can never be attempted. Left unmarked it
  # would hold the plan open forever; marked missing, the plan can retire.
  # Destructive to the universe, so it is the last thing this test does.
  "$root/bin/meute" plan --enqueue "$universe" >/dev/null 2>&1
  rm -rf "$universe/repo-alpha"
  while IFS= read -r r; do
    printf '%s\tattempted\n' "$r" >> "$root/state/plan-complete"
  done < <(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" plan-queue "$root/repos.local.yaml" "$root/state/plan-queue.json" all \
             | jq -r 'select(.path | endswith("/repo-alpha") | not) | .key')
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily --dry-run 2>&1)"
  has "plan: a vanished staged repo does not wedge the daily slot" "$out" "would run: key=already-configured/audit-security"
  is  "plan: a vanished staged repo is marked missing" \
    "$(grep -cE $'^plan/plan-repo-alpha-[0-9a-f]{6}/audit-security\tmissing$' "$root/state/plan-complete")" "1"
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" weekly --dry-run 2>&1)"
  has "plan: a vanished staged repo does not wedge the weekly slot" "$out" "would run: key=already-configured/architecture-review"
  is  "plan: a plan whose last item vanished retires" "$(test -e "$root/state/plan-queue.json"; echo $?)" "1"
  is  "plan: the retired plan is archived alongside the first" "$(find "$root/state" -name 'plan-queue.completed-*' | wc -l)" "2"
}

# A staged plan end to end: the runner cuts a worktree in an unenrolled
# repository, the stub engine runs in it, the report lands under the synthetic
# name, and nothing is left behind -- no worktree, no branch, no commit in
# meute's own checkout. Also where the plan-vs-manifest bookkeeping (separate
# cursors, forced re-runs, `meute status`) is pinned, since it needs real
# attempts rather than dry runs.
test_plan_run() {
  local universe="$FIXTURE/plan-run"
  local root="$universe/meute-stand-in"
  mkdir -p "$root"/{state,tasks,stub}
  ln -sfn "$REPO/bin" "$root/bin"
  ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO/tasks/audit-security.md" "$root/tasks/"
  # The stand-in is itself a git repo with nothing ignored: a runner that
  # committed its own state would show up as a second commit here.
  git -C "$root" init -q -b main
  echo x > "$root/f.txt"; git -C "$root" add -A
  git -C "$root" -c user.email=t@t -c user.name=t commit -qm init
  local r
  for r in repo-alpha alpha-cfg beta-cfg; do
    mkdir -p "$universe/$r"
    git -C "$universe/$r" init -q -b main
    echo x > "$universe/$r/f.txt"
    git -C "$universe/$r" add -A
    git -C "$universe/$r" -c user.email=t@t -c user.name=t commit -qm init
  done
  # `git init` and nothing else: an unborn HEAD, no tree to audit and nothing
  # to cut a worktree from. One unenrolled (for the scan), one enrolled as
  # `nohead` (for the runner).
  for r in repo-unborn nohead-cfg; do
    mkdir -p "$universe/$r"
    git -C "$universe/$r" init -q -b main
  done
  python3 - "$root" "$universe" <<'PY2'
import sys, pathlib, yaml
root, universe = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read,Grep,Glob", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"audit-security": {"tier": "tier2", "template": "tasks/audit-security.md", "slots": ["daily"]}},
    "repos": [{"name": "alpha-cfg", "path": str(universe / "alpha-cfg"), "spec": "enrolled", "tasks": ["audit-security"]},
              {"name": "beta-cfg", "path": str(universe / "beta-cfg"), "spec": "enrolled", "tasks": ["audit-security"]},
              {"name": "nohead", "path": str(universe / "nohead-cfg"), "spec": "enrolled, empty", "tasks": ["audit-security"]}],
    "community": [],
}, open(root / "repos.local.yaml", "w"), sort_keys=False)
PY2
  # The stub engine records where it ran and answers with a minimal envelope.
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
printf '%s\n' "$PWD" > "$(dirname "${BASH_SOURCE[0]}")/last-cwd"
jq -n '{is_error:false,result:"## Summary\nstub ran",total_cost_usd:0.01,num_turns:1}'
STUB
  chmod +x "$root/stub/claude"
  run() { PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" "$@" 2>&1; }

  # Synthetic names come from the repository's identity, not its position in
  # the list, so a plan re-staged after another repo appears keeps the same
  # name -- and the same plan-complete key -- for repo-alpha.
  local out alpha_name alpha_again aaa_name
  "$root/bin/meute" plan --enqueue "$universe" >/dev/null 2>&1
  alpha_name="$(jq -r '.entries[] | select(.path | endswith("/repo-alpha")) | .name' "$root/state/plan-queue.json" | sort -u)"
  is "plan run: a synthetic name is plan-<stem>-<6 hex>" \
    "$(grep -cE '^plan-repo-alpha-[0-9a-f]{6}$' <<< "$alpha_name")" "1"
  mkdir -p "$universe/repo-aaa"
  git -C "$universe/repo-aaa" init -q -b main
  echo x > "$universe/repo-aaa/f.txt"; git -C "$universe/repo-aaa" add -A
  git -C "$universe/repo-aaa" -c user.email=t@t -c user.name=t commit -qm init
  "$root/bin/meute" plan --enqueue "$universe" >/dev/null 2>&1
  alpha_again="$(jq -r '.entries[] | select(.path | endswith("/repo-alpha")) | .name' "$root/state/plan-queue.json" | sort -u)"
  is "plan run: the name survives a change in the unconfigured set" "$alpha_again" "$alpha_name"
  aaa_name="$(jq -r '.entries[] | select(.path | endswith("/repo-aaa")) | .name' "$root/state/plan-queue.json" | sort -u)"

  # A repository with no commits yet cannot be audited; staged, it would fail
  # every fire. The scan leaves it out and says so.
  out="$("$root/bin/meute" plan "$universe" 2>&1)"
  hasnt "plan run: a repository with no commits is not proposed" "$out" "unconfigured  repo-unborn"
  has   "plan run: ...and the scan says why"                     "$out" "repo-unborn: no commits yet"
  is    "plan run: only the two real repositories are staged" "$(jq '.entries | length' "$root/state/plan-queue.json")" "2"

  # The manifest rotation had reached alpha-cfg before the plan was staged.
  printf 'cursor.daily\talpha-cfg/audit-security\n' > "$root/state/cursor"
  out="$("$root/bin/meute" status 2>&1)"
  has "status: reports the staged plan"        "$out" "staged plan: 0 of 2 attempted"
  has "status: next daily is the staged item"  "$out" "next daily   plan/${aaa_name}/audit-security"

  # One real attempt through the stub engine.
  out="$(run daily)"
  has "plan run: completes through the stub engine"     "$out" "status=ok"
  has "plan run: ...under the synthetic name"           "$out" "repo=${aaa_name}"
  local cwd; cwd="$(cat "$root/stub/last-cwd")"
  has "plan run: the engine ran in a worktree under meute's own tree" "$cwd" "$root/.worktrees/${aaa_name}-audit-security-"
  is  "plan run: the worktree is removed afterwards"    "$(test -d "$cwd"; echo $?)" "1"
  is  "plan run: the scratch branch is removed from the unenrolled repo" \
      "$(git -C "$universe/repo-aaa" branch --list 'meute/*' | wc -l)" "0"
  is  "plan run: the unenrolled repo lists no worktree but its own" \
      "$(git -C "$universe/repo-aaa" worktree list | wc -l)" "1"
  is  "plan run: the report lands under the synthetic name" \
      "$(ls "$root/reports/${aaa_name}/" 2>/dev/null | grep -c '^audit-security-')" "1"
  is  "plan run: the attempt is marked" \
      "$(awk -F'\t' -v k="plan/${aaa_name}/audit-security" '$1 == k { print "marked" }' "$root/state/plan-complete")" "marked"
  is  "plan run: meute's own checkout gained no commit" "$(git -C "$root" rev-list --count HEAD)" "1"
  is  "plan run: a plan keeps its own cursor" \
      "$(awk -F'\t' '$1 == "plan-cursor.daily" { print $2 }' "$root/state/cursor")" "plan/${aaa_name}/audit-security"
  is  "plan run: the manifest cursor is untouched" \
      "$(awk -F'\t' '$1 == "cursor.daily" { print $2 }' "$root/state/cursor")" "alpha-cfg/audit-security"
  out="$("$root/bin/meute" status 2>&1)"
  has "status: counts the attempt"                     "$out" "staged plan: 1 of 2 attempted"
  has "status: next daily moves to the next staged item" "$out" "next daily   plan/${alpha_name}/audit-security"

  # --repo is an explicit human decision, and re-running an attempted staged
  # item is a legitimate one.
  out="$(run daily --dry-run --repo "$aaa_name")"
  has "plan run: --repo re-runs an attempted staged item" "$out" "would run: key=plan/${aaa_name}/audit-security"

  out="$(run daily)"
  has "plan run: the second item runs"      "$out" "repo=${alpha_name}"
  has "plan run: the finished plan retires" "$out" "archived queue"
  out="$(run daily --dry-run)"
  has "plan run: a retired plan hands the rotation back where the manifest left it" \
      "$out" "would run: key=beta-cfg/audit-security"

  # An enrolled repository with no commits: the runner cannot cut a worktree
  # from it. Logged as an error and stepped over, like a failed worktree add,
  # rather than dying before the cursor moves -- which would pin the slot on
  # it forever, silently.
  printf 'cursor.daily\tbeta-cfg/audit-security\n' > "$root/state/cursor"
  out="$(run daily --dry-run; echo "rc=$?")"
  has "plan run: an unborn HEAD is logged as an error" "$out" "status=error"
  has "plan run: ...naming the cause"                  "$out" "detail=no-head"
  has "plan run: ...and the entry"                     "$out" "repo=nohead"
  has "plan run: ...with a non-zero exit"              "$out" "rc=1"
  is  "plan run: the cursor steps over the unborn repository" \
      "$(awk -F'\t' '$1 == "cursor.daily" { print $2 }' "$root/state/cursor")" "nohead/audit-security"
  out="$(run daily --dry-run)"
  has "plan run: the next fire moves on" "$out" "would run: key=alpha-cfg/audit-security"

  # The name follows the repository, not its path: a fresh clone dropped in
  # at the same spelling is a different repository and gets a different name,
  # so nothing attempted against the old one is mistaken for it.
  "$root/bin/meute" plan --enqueue "$universe" >/dev/null 2>&1
  alpha_name="$(jq -r '.entries[] | select(.path | endswith("/repo-alpha")) | .name' "$root/state/plan-queue.json" | sort -u)"
  git clone -q "$universe/repo-alpha" "$universe/repo-alpha.fresh"
  rm -rf "$universe/repo-alpha"; mv "$universe/repo-alpha.fresh" "$universe/repo-alpha"
  "$root/bin/meute" plan --enqueue "$universe" >/dev/null 2>&1
  alpha_again="$(jq -r '.entries[] | select(.path | endswith("/repo-alpha")) | .name' "$root/state/plan-queue.json" | sort -u)"
  is "plan run: a fresh clone at the same path is a new name" "$([[ "$alpha_again" != "$alpha_name" ]] && echo differs || echo same)" "differs"
  is "plan run: ...of the same shape" "$(grep -cE '^plan-repo-alpha-[0-9a-f]{6}$' <<< "$alpha_again")" "1"

  # A plan file the runner would refuse is not "0 of 0 attempted".
  printf '{broken\n' > "$root/state/plan-queue.json"
  out="$("$root/bin/meute" status 2>&1)"
  has   "status: a plan the runner refuses is reported as invalid" "$out" "staged plan: invalid — "
  has   "status: ...with the validator's reason"                    "$out" "invalid plan queue JSON"
  hasnt "status: ...never as an empty plan"                         "$out" "0 of 0 attempted"
  has   "status: ...and next says the runner is blocked on it"      "$out" "next daily   - (staged plan invalid; the runner refuses to run)"
  rm -f "$root/state/plan-queue.json"
}


# The community track's gates: no etiquette file means no contribution, and the
# reproduce/draft stages sit on opposite sides of the human specced: true gate.
test_community_gates() {
  local root="$FIXTURE/community"
  mkdir -p "$root"/{etiquette,tasks,state}
  ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO"/tasks/*.md "$root/tasks/"
  cp "$REPO/etiquette/example-project.yaml" "$root/etiquette/upstream.yaml"
  mkdir -p "$root/clone"; git -C "$root/clone" init -q -b main
  echo x > "$root/clone/f.txt"; git -C "$root/clone" add -A
  git -C "$root/clone" -c user.email=t@t -c user.name=t commit -qm init

  python3 - "$root" <<'PY'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
base = yaml.safe_load(pathlib.Path(sys.argv[1], "..", "repos.yaml").read_text()) \
       if (root/".."/"repos.yaml").exists() else {}
doc = {
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.20,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {
        "tier1": {"tools": "Read", "permission_mode": "acceptEdits", "writes_code": True, "network": "proxied"},
        "tier2-scout": {"tools": "Read,Bash", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"},
        "tier3": {"tools": "Read", "permission_mode": "acceptEdits", "writes_code": True, "network": "proxied"},
    },
    "tasks": {
        "scout": {"tier": "tier2-scout", "template": "tasks/scout.md", "slots": ["weekly"]},
        "reproduce": {"tier": "tier1", "template": "tasks/reproduce.md",
                      "slots": ["weekly"], "requires_candidate_ticket": True},
        "draft": {"tier": "tier3", "template": "tasks/draft.md",
                  "slots": ["weekly"], "requires_specced_ticket": True},
    },
    "repos": [],
    "community": [{
        "name": "upstream", "repo": "owner/upstream", "path": str(root/"clone"),
        "spec": "fixture upstream", "etiquette": "etiquette/upstream.yaml",
        "tasks": ["scout", "reproduce", "draft"],
        "tickets": [{"id": "101", "title": "candidate, not yet reproduced", "specced": False},
                    {"id": "202", "title": "reproduced and cleared", "specced": True}],
    }],
}
yaml.safe_dump(doc, open(root/"repos.yaml", "w"), sort_keys=False)
PY

  local keys
  keys="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -r .key | sort | tr '\n' ' ')"
  has "community: scout is ticket-independent"      "$keys" "upstream/scout"
  has "community: reproduce takes the candidate"    "$keys" "upstream/reproduce/101"
  hasnt "community: reproduce skips the specced one" "$keys" "upstream/reproduce/202"
  has "community: draft takes the specced one"      "$keys" "upstream/draft/202"
  hasnt "community: draft skips the candidate"      "$keys" "upstream/draft/101"

  # scout must not be able to write to the project
  local scout_tools
  scout_tools="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly \
                 | jq -r 'select(.task=="scout") | "\(.writes_code) \(.tools)"')"
  has "community: scout is writes_code=false" "$scout_tools" "false"

  # the etiquette gate
  python3 - "$root" <<'PY'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
d = yaml.safe_load((root/"repos.yaml").read_text())
d["community"][0].pop("etiquette")
yaml.safe_dump(d, open(root/"no-etiquette.yaml", "w"), sort_keys=False)
PY
  local err
  err="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" validate "$root/no-etiquette.yaml" 2>&1 || true)"
  has "community: no etiquette file, no contribution" "$err" "etiquette: required"

  python3 - "$root" <<'PY'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
(root/"state").mkdir(exist_ok=True)
yaml.safe_dump({"tickets": {"upstream": [
    {"id": "303", "title": "machine ticket", "specced": True}]}},
    open(root/"state"/"tickets.yaml", "w"), sort_keys=False)
PY
  local q1
  q1="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -r .key | tr '\n' ' ')"
  has "machine ticket reaches the tier-3 queue" "$q1" "upstream/draft/303"
  MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" mark-delivered \
    "$root/repos.yaml" upstream 303 meute/draft-ticket-test >/dev/null 2>&1
  local q2
  q2="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -r .key | tr '\n' ' ')"
  hasnt "delivered ticket retires from the tier-3 queue" "$q2" "upstream/draft/303"

  # A project that bans autonomous agents keeps scouting but loses every
  # contribution stage -- enforced by the queue builder, not by prompt text.
  python3 - "$root" <<'PY'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
e = yaml.safe_load((root/"etiquette"/"upstream.yaml").read_text())
e["autonomous_agents"] = "banned"
yaml.safe_dump(e, open(root/"etiquette"/"banned.yaml", "w"), sort_keys=False)
d = yaml.safe_load((root/"repos.yaml").read_text())
d["community"][0]["etiquette"] = "etiquette/banned.yaml"
yaml.safe_dump(d, open(root/"banned.yaml", "w"), sort_keys=False)
PY
  local banned
  banned="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/banned.yaml" weekly | jq -r .key | sort | tr '\n' ' ')"
  has   "agent ban: scouting still allowed"      "$banned" "upstream/scout"
  hasnt "agent ban: reproduce refused"           "$banned" "upstream/reproduce"
  hasnt "agent ban: draft refused"               "$banned" "upstream/draft"

  # the policy must travel in the prompt, not as an unreachable path
  local rendered
  rendered="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" render "$root/tasks/scout.md" \
      REPO_NAME=x REPO_SPEC=x REPO_PATH=x TASK=x TIER=x DATE=x BRANCH=x FILE_BUDGET=5 \
      LENS=none REPORT_PATH=x DEFAULT_BRANCH=main ALLOWED_COMMANDS=x UPSTREAM=x \
      ETIQUETTE=etiquette/upstream.yaml \
      "ETIQUETTE_CONTENT=$(cat "$root/etiquette/upstream.yaml")" \
      TICKET_ID= TICKET_TITLE= TICKET_NOTES=)"
  has "etiquette content is injected into the prompt" "$rendered" "ai_policy: required"
  has "etiquette content carries the agent axis"      "$rendered" "autonomous_agents"
}


# The quota gate is the promise that scheduled work never starves interactive
# work. A broken probe must stop the fleet, not silently unlock it.
test_quota_gate() {
  local out rc
  # A fixture root: quota.sh resolves state/ relative to itself, and the real
  # checkout's state/rate-limits.json (a live snapshot, once install-statusline
  # has run) would otherwise answer these instead of the stub.
  local root="$FIXTURE/quota"; mkdir -p "$root/state"
  ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  local q="$root/bin/quota.sh"

  out="$(MEUTE_QUOTA_STUB=55 "$q")"
  is "quota: stub value is reported" "$out" "55"

  out="$(MEUTE_QUOTA_STUB=55 "$q" --with-source)"
  is "quota: --with-source names the source" "$out" "55 stub"

  out="$(MEUTE_QUOTA_CMD='echo 42' "$q" --with-source)"
  # The source is the probe's basename, not the variable name: state/log should
  # say WHICH probe answered (quota-self-budget.sh vs a real pool reader).
  is "quota: configured probe wins, named by its command" "$out" "42 echo"

  # the safety property: a configured probe that fails must NOT fall back
  MEUTE_QUOTA_CMD='exit 3' "$q" >/dev/null 2>&1; rc=$?
  is "quota: broken probe fails closed, never falls back to the stub" "$rc" "1"

  out="$(MEUTE_QUOTA_CMD='exit 3' "$q" 2>&1 || true)"
  hasnt "quota: broken probe emits no number at all" "$out" "100"

  # non-numeric output is a broken source too
  MEUTE_QUOTA_CMD='echo banana' "$q" >/dev/null 2>&1; rc=$?
  is "quota: non-numeric probe output is rejected" "$rc" "1"

  MEUTE_QUOTA_CMD='echo 250' "$q" >/dev/null 2>&1; rc=$?
  is "quota: out-of-range probe output is rejected" "$rc" "1"

  out="$(MEUTE_CLAUDE_QUOTA_CMD='echo 63' MEUTE_QUOTA_CMD='echo 42' "$q" --engine claude --with-source)"
  is "quota: Claude-specific command outranks its legacy alias" "$out" "63 echo"

  env -u MEUTE_CODEX_QUOTA_CMD MEUTE_QUOTA_CMD='echo 42' "$q" --engine codex >/dev/null 2>&1; rc=$?
  is "quota: Codex never reuses the legacy Claude probe" "$rc" "1"
  out="$(env -u MEUTE_CODEX_QUOTA_CMD "$q" --engine codex 2>&1 || true)"
  has "quota: an unwired Codex probe explains the safe refusal" "$out" "no Codex quota probe is configured"

  out="$(MEUTE_CODEX_QUOTA_CMD='echo 73' "$q" --engine codex --with-source)"
  is "quota: Codex accepts only its dedicated probe" "$out" "73 echo"

  # the adapter must fail cleanly when its backend is absent
  LUT_URL='http://127.0.0.1:9' "$REPO/contrib/quota-llm-usage-tracker.sh" >/dev/null 2>&1; rc=$?
  is "quota: llm-usage-tracker adapter fails closed when unreachable" "$rc" "1"

  # The default used to be :8000 -- plausible, and wrong: the tracker's own
  # `serve` command (backend/cli.py) binds :48372. Pin it against the error
  # message rather than the source line, so a future edit that changes the
  # literal without checking it against the tracker's real default still fails
  # this test instead of silently drifting again.
  local out
  out="$(env -u LUT_URL "$REPO/contrib/quota-llm-usage-tracker.sh" 2>&1 || true)"
  has "quota: llm-usage-tracker adapter defaults to the tracker's real port" "$out" "127.0.0.1:48372"
}


# A manifest can mix engines. The runner must select an entry before it probes,
# so a Codex job cannot accidentally consume a Claude status-line reading.
test_runner_uses_selected_engine_quota() {
  local root="$FIXTURE/codex-quota" repo="$FIXTURE/codex-quota/git-r"
  mkdir -p "$root"/{state,tasks,stub} "$repo"
  ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO/tasks/audit-security.md" "$root/tasks/"
  git -C "$repo" init -q -b main
  echo x > "$repo/f"; git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init
  python3 - "$root" "$repo" <<'PY'
import pathlib, sys, yaml
root, repo = map(pathlib.Path, sys.argv[1:])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "codex", "model": "unused", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"audit-security": {"tier": "tier2", "template": "tasks/audit-security.md", "slots": ["daily"]}},
    "repos": [{"name": "r", "path": str(repo), "spec": "fixture", "tasks": ["audit-security"]}],
    "community": [],
}, open(root / "repos.yaml", "w"), sort_keys=False)
PY
  # A tempting Claude reading must not unlock the Codex queue item.
  printf '{"captured_at":1,"seven_day":{"used_percentage":1,"resets_at":9999999999}}' > "$root/state/rate-limits.json"
  local out
  out="$(env -u MEUTE_CODEX_QUOTA_CMD -u MEUTE_CLAUDE_QUOTA_CMD -u MEUTE_QUOTA_CMD \
    MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily --dry-run 2>&1)"
  has "runner quota: unwired Codex entry declines despite Claude snapshot" "$out" "codex quota probe failed"
  has "runner quota: ...and the skip reason names the engine" "$out" "reason=no eligible entry for slot daily (codex quota probe failed)"

  cat > "$root/stub/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "login" && "$2" == "status" ]]; then
  printf 'Logged in with ChatGPT\n'
  exit 0
fi
exit 1
STUB
  chmod +x "$root/stub/codex"
  out="$(env -u MEUTE_CLAUDE_QUOTA_CMD -u MEUTE_QUOTA_CMD \
    PATH="$root/stub:$PATH" MEUTE_CODEX_QUOTA_CMD='echo 88' "$root/bin/run.sh" daily --dry-run 2>&1)"
  has "runner quota: configured Codex probe permits Codex entry" "$out" "would run: key=r/audit-security"
  has "runner quota: selected Codex engine reaches the dry run" "$out" "engine=codex"
}


# A fleet that mixes engines must not wedge on the one whose probe is
# unwired. Found by probe: alpha(claude) -> beta(codex) -> gamma(claude) with
# no MEUTE_CODEX_QUOTA_CMD selected beta, failed its probe as a global skip,
# and never advanced the cursor -- exit 0, every fire, forever. The pool is
# per engine, so it is checked per candidate, once per engine per fire.
test_mixed_engine_quota() {
  local root="$FIXTURE/mixed-quota"
  mkdir -p "$root"/{state,tasks,stub}
  ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO/tasks/audit-security.md" "$root/tasks/"
  local r
  for r in alpha beta gamma; do
    mkdir -p "$root/git-$r"; git -C "$root/git-$r" init -q -b main
    echo x > "$root/git-$r/f"; git -C "$root/git-$r" add -A
    git -C "$root/git-$r" -c user.email=t@t -c user.name=t commit -qm init
  done
  python3 - "$root" <<'PY2'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"audit-security": {"tier": "tier2", "template": "tasks/audit-security.md", "slots": ["daily"]}},
    "repos": [
        {"name": "alpha", "path": str(root / "git-alpha"), "spec": "claude repo", "tasks": ["audit-security"]},
        {"name": "beta",  "path": str(root / "git-beta"),  "spec": "codex repo", "engine": "codex", "tasks": ["audit-security"]},
        {"name": "gamma", "path": str(root / "git-gamma"), "spec": "claude repo", "tasks": ["audit-security"]},
    ],
    "community": [],
}, open(root / "repos.yaml", "w"), sort_keys=False)
PY2
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
jq -n '{is_error:false,result:"## Summary\nstub ran",total_cost_usd:0.01,num_turns:1}'
STUB
  # A Claude probe that counts how often it is asked.
  printf '#!/usr/bin/env bash\necho p >> "%s/stub/probes"\necho 100\n' "$root" > "$root/stub/qprobe"
  chmod +x "$root/stub/claude" "$root/stub/qprobe"
  fire() {
    env -u MEUTE_CODEX_QUOTA_CMD -u MEUTE_QUOTA_CMD MEUTE_CLAUDE_QUOTA_CMD="$root/stub/qprobe" \
      PATH="$root/stub:$PATH" "$root/bin/run.sh" daily "$@" 2>&1
  }

  # As after a real alpha run: the rotation is about to reach beta.
  printf 'cursor.daily\talpha/audit-security\n' > "$root/state/cursor"
  local out
  out="$(fire --dry-run)"
  has "mixed quota: the codex entry is skipped, naming the engine" "$out" "skipping beta/audit-security: codex quota unavailable"
  has "mixed quota: the rotation moves on to the next claude entry" "$out" "would run: key=gamma/audit-security"
  has "mixed quota: the selected engine is the one that reaches the run" "$out" "engine=claude"
  is  "mixed quota: one Claude probe per fire, however many candidates" "$(wc -l < "$root/stub/probes")" "1"

  # Three real fires: the cursor walks alpha -> gamma -> alpha -> gamma,
  # never pinned on beta.
  : > "$root/state/log"
  local i
  for i in 1 2 3; do fire >/dev/null; done
  is  "mixed quota: three fires ran three claude entries" "$(grep -c 'status=ok' "$root/state/log")" "3"
  is  "mixed quota: ...in rotation past beta" \
      "$(grep -o 'repo=[a-z]*' "$root/state/log" | paste -sd,)" "repo=gamma,repo=alpha,repo=gamma"
  is  "mixed quota: the log attributes each reading to its engine" "$(grep -c 'quota=100:qprobe' "$root/state/log")" "3"
  is  "mixed quota: the cursor advanced" "$(awk -F'\t' '$1 == "cursor.daily" { print $2 }' "$root/state/cursor")" "gamma/audit-security"

  # `meute status` must not name an entry the runner would step over.
  printf 'cursor.daily\talpha/audit-security\n' > "$root/state/cursor"
  out="$(env -u MEUTE_CODEX_QUOTA_CMD -u MEUTE_QUOTA_CMD MEUTE_CLAUDE_QUOTA_CMD="$root/stub/qprobe" \
           PATH="$root/stub:$PATH" "$root/bin/meute" status 2>&1)"
  has "mixed quota: status skips the gated codex entry too" "$out" "next daily   gamma/audit-security"

  # A pool below the floor gates its own engine's entries the same way, and
  # a fleet with nothing eligible says which pools, with their readings.
  printf '#!/usr/bin/env bash\necho 10\n' > "$root/stub/qprobe"
  out="$(env -u MEUTE_CODEX_QUOTA_CMD -u MEUTE_QUOTA_CMD MEUTE_CLAUDE_QUOTA_CMD="$root/stub/qprobe" \
           PATH="$root/stub:$PATH" "$root/bin/meute" status 2>&1)"
  has "mixed quota: status names nothing when every pool is gated" "$out" "next daily   -"
  out="$(fire --dry-run)"
  has "mixed quota: a scarce pool skips that engine's entries" "$out" "skipping alpha/audit-security: claude quota 10% below floor 30%"
  has "mixed quota: nothing eligible names every gated engine"  "$out" "reason=no eligible entry for slot daily (claude quota 10% below floor 30%; codex quota probe failed)"
  has "mixed quota: ...with the readings, in the same order"     "$out" $'\tquota=10:qprobe,fail\tengine=claude,codex'
  has "mixed quota: ...as a skip, not an error"                  "$out" "status=skipped"
}


# --help is the header comment, however long it grows: a hardcoded line window
# silently truncates the next option someone documents.
test_help() {
  local out
  out="$(meute help)"
  is    "help: starts with the tool's own name"   "$(grep -m1 . <<< "$out")" "meute — review and triage what the fleet produced."
  is    "help: ends on the last header line"      "$(tail -n1 <<< "$out")" "add-repo and set-image-digest both refuse to touch it."
  hasnt "help: prints no code"                    "$out" "set -"
  out="$("$FIXTURE/bin/run.sh" --help)"
  is    "help: run.sh starts with its own name"   "$(grep -m1 . <<< "$out")" "meute — autonomous fleet runner."
  is    "help: run.sh ends on its last header line" "$(tail -n1 <<< "$out")" "  MEUTE_QUOTA_CMD        legacy alias for MEUTE_CLAUDE_QUOTA_CMD"
  hasnt "help: run.sh prints no code"             "$out" "set -"
}

test_doctor() {
  local out rc
  out="$(meute doctor 2>&1)"; rc=$?
  is  "doctor: exits 0 on a healthy checkout" "$rc" "0"
  has "doctor: checks binaries"               "$out" "binaries"
  has "doctor: probes auth"                   "$out" "auth"
  has "doctor: reports the quota source"      "$out" "quota gate"
  has "doctor: reports scheduling"            "$out" "scheduling"
  # The guidance must match the machine. A crontab block on a host without cron
  # is instructions that silently never fire, which is how this was found.
  if command -v crontab >/dev/null 2>&1; then
    has "doctor: cron host gets a crontab block" "$out" "crontab -e"
    has "doctor: the block sets PATH"            "$out" "PATH="
  else
    has "doctor: cron-less host is told so"      "$out" "no cron on this machine"
    # Either state is correct: not yet installed and pointed at the installer, or
    # installed and reported as such.
    if [[ "$out" == *"units installed"* ]]; then
      has "doctor: installed timers are reported" "$out" "units installed"
    else
      has "doctor: uninstalled timers point at the installer" "$out" "install-timers"
    fi
  fi
  has "doctor: warns an unwired quota gate"   "$out" "measures NOTHING yet"
  has "doctor: says how to wire it"           "$out" "meute install-statusline"
  has "doctor: says unwired Codex is unavailable" "$out" "subscription (Codex): unavailable"
}

# install-timers used to hardcode ~/.local/bin:~/.npm-global/bin into the unit's
# PATH — right on the machine this was written on, silently wrong on the next
# one. unit_path_line derives it from where the binaries actually resolve.
# Deterministic regardless of what this test machine happens to have on PATH.
test_unit_path_line() {
  local stub="$FIXTURE/unitpath"; mkdir -p "$stub"
  local b
  for b in git jq python3 claude codex; do : > "$stub/$b"; chmod +x "$stub/$b"; done

  local out
  out="$(PATH="$stub:/usr/bin:/bin" bash -c 'source "$1"; unit_path_line' _ "$REPO/bin/meute")"
  has "unit_path_line: includes where a binary actually resolves from" "$out" "$stub"
  has "unit_path_line: keeps the /usr/bin:/bin fallback tail"          "$out" "/usr/bin:/bin"

  # cargo lives in ~/.cargo/bin, nowhere near git/jq/python3/claude/codex --
  # the only way its directory gets in is by reading what a tier's
  # allowed_tools actually declares (Bash(cargo test:*), ...), same as
  # veille-finance's real manifest does. A second stub dir stands in for
  # ~/.cargo/bin so this is deterministic regardless of what's really
  # installed on the machine running the suite.
  local toolchain_dir="$FIXTURE/unitpath-toolchain"; mkdir -p "$toolchain_dir"
  : > "$toolchain_dir/toolchain-probe"; chmod +x "$toolchain_dir/toolchain-probe"
  local tiny_manifest="$FIXTURE/unitpath/tiny-manifest.yaml"
  cat > "$tiny_manifest" <<'YAML'
version: 1
tiers:
  tier1:
    allowed_tools: Bash(toolchain-probe:*) Bash(git:*)
tasks: {}
repos: []
community: []
YAML
  # Real python3 must resolve here (not the empty stub above) to actually
  # parse the YAML, so $stub is deliberately left out of this PATH.
  out="$(PATH="$toolchain_dir:/usr/bin:/bin" MEUTE_MANIFEST="$tiny_manifest" \
         bash -c 'source "$1"; unit_path_line' _ "$REPO/bin/meute")"
  has "unit_path_line: also includes a directory a tier's allowed_tools names" \
      "$out" "$toolchain_dir"

  # install-timers must not fail closed just because the manifest scan can't
  # run -- a broken or absent manifest still leaves the fixed five working.
  local rc
  out="$(MEUTE_MANIFEST="$FIXTURE/unitpath/nope.yaml" bash -c 'source "$1"; unit_path_line' _ "$REPO/bin/meute")"; rc=$?
  is  "unit_path_line: a missing manifest does not abort" "$rc" "0"
  has "unit_path_line: ...and still yields the fallback tail" "$out" "/usr/bin:/bin"

  printf 'not: valid: yaml: [[[\n' > "$FIXTURE/unitpath/broken.yaml"
  out="$(MEUTE_MANIFEST="$FIXTURE/unitpath/broken.yaml" bash -c 'source "$1"; unit_path_line' _ "$REPO/bin/meute")"; rc=$?
  is  "unit_path_line: an unparseable manifest does not abort" "$rc" "0"
  has "unit_path_line: ...and still yields the fallback tail (broken)" "$out" "/usr/bin:/bin"

  # Real-world trigger: this machine has two real cargos (a distro package in
  # /usr/bin, rustup's in ~/.cargo/bin) at different versions. Building the
  # derived PATH in name-iteration order rather than the caller's own PATH
  # order let the unit silently resolve to a *different* cargo, and therefore
  # different clippy lints, than both the caller and the repo's own CI use.
  # Synthetic stand-in for that split, deterministic regardless of what's
  # really installed on the machine running the suite.
  local dir_a="$FIXTURE/precedence-a" dir_b="$FIXTURE/precedence-b"
  mkdir -p "$dir_a" "$dir_b"
  printf '#!/bin/sh\necho from-a\n' > "$dir_a/toolchain-dup"; chmod +x "$dir_a/toolchain-dup"
  printf '#!/bin/sh\necho from-b\n' > "$dir_b/toolchain-dup"; chmod +x "$dir_b/toolchain-dup"
  local precedence_manifest="$FIXTURE/unitpath/precedence-manifest.yaml"
  cat > "$precedence_manifest" <<'YAML'
version: 1
tiers:
  tier1:
    allowed_tools: Bash(toolchain-dup:*)
tasks: {}
repos: []
community: []
YAML

  local derived_a_wins derived_b_wins resolved
  derived_a_wins="$(PATH="$dir_a:$dir_b:/usr/bin:/bin" MEUTE_MANIFEST="$precedence_manifest" \
             bash -c 'source "$1"; unit_path_line' _ "$REPO/bin/meute")"
  resolved="$(env -i PATH="$derived_a_wins" sh -c 'toolchain-dup')"
  is "unit_path_line: preserves which duplicate binary wins, same as the caller's PATH" \
     "$resolved" "from-a"

  derived_b_wins="$(PATH="$dir_b:$dir_a:/usr/bin:/bin" MEUTE_MANIFEST="$precedence_manifest" \
             bash -c 'source "$1"; unit_path_line' _ "$REPO/bin/meute")"
  resolved="$(env -i PATH="$derived_b_wins" sh -c 'toolchain-dup')"
  is "unit_path_line: ...and flips when the caller's own PATH does" \
     "$resolved" "from-b"

  # dir_a is only ever "needed" when it's the one that actually wins (it's a
  # fully shadowed loser in the second case above, so it correctly does not
  # appear there at all) -- check the case where it legitimately belongs,
  # exactly once, not duplicated.
  local occurrences; occurrences="$(grep -o "$dir_a" <<< "$derived_a_wins" | wc -l)"
  is "unit_path_line: no duplicate directory entries" "$occurrences" "1"

  # The real trigger for the dedup guard: this machine's actual interactive
  # PATH has the same directory listed several times over (shell init files
  # each prepending their own copy). A needed directory appearing twice in
  # the caller's own $PATH must not appear twice in the derived one either.
  derived_a_wins="$(PATH="$dir_a:$dir_a:$dir_b:/usr/bin:/bin" MEUTE_MANIFEST="$precedence_manifest" \
             bash -c 'source "$1"; unit_path_line' _ "$REPO/bin/meute")"
  occurrences="$(grep -o "$dir_a" <<< "$derived_a_wins" | wc -l)"
  is "unit_path_line: a directory repeated in \$PATH itself is still deduped" "$occurrences" "1"

  # The actual mechanism of the real bug wasn't one binary name resolving two
  # ways -- it was TWO DIFFERENT binaries (git -> /usr/bin, cargo ->
  # ~/.cargo/bin) whose directories get combined, in whatever order they were
  # looked up rather than the order $PATH itself puts them in. zzz-tool sorts
  # (and is therefore scanned) after aaa-tool, so old insertion-order code
  # always placed aaa-tool's directory first regardless of $PATH; putting
  # zzz-tool's directory ahead of aaa-tool's in $PATH makes that distinction
  # visible without relying on any specific binary actually existing twice.
  local dir_early="$FIXTURE/precedence-early" dir_late="$FIXTURE/precedence-late"
  mkdir -p "$dir_early" "$dir_late"
  : > "$dir_early/zzz-tool"; chmod +x "$dir_early/zzz-tool"
  : > "$dir_late/aaa-tool";  chmod +x "$dir_late/aaa-tool"
  local cross_manifest="$FIXTURE/unitpath/cross-manifest.yaml"
  cat > "$cross_manifest" <<'YAML'
version: 1
tiers:
  tier1:
    allowed_tools: Bash(aaa-tool:*) Bash(zzz-tool:*)
tasks: {}
repos: []
community: []
YAML
  local cross_derived before_late
  cross_derived="$(PATH="$dir_early:$dir_late:/usr/bin:/bin" MEUTE_MANIFEST="$cross_manifest" \
             bash -c 'source "$1"; unit_path_line' _ "$REPO/bin/meute")"
  before_late="${cross_derived%%"$dir_late"*}"
  has "unit_path_line: two different binaries' directories keep \$PATH's own relative order" \
      "$before_late" "$dir_early"

  # Every name derived from allowed_tools used to be a real binary. The list
  # now carries Bash(command -v:*), whose first word is the shell builtin
  # `command`, and `command -v command` answers with the bare word rather than
  # a path -- dirname turns that into ".", which the caller's own PATH here
  # then admits. A relative entry in a unit's PATH resolves against the unit's
  # working directory, a worktree of the repo being worked on, so on the
  # community track a third party's planted ./git would win.
  #
  # Compared field-by-field on purpose: "." is a substring of no directory and
  # a regex matching every character, so both `has` and a grep here would pass
  # without proving anything. Same class of silent-no-match bug the colon-join
  # dedup above was written for.
  local builtin_manifest="$FIXTURE/unitpath/builtin-manifest.yaml"
  cat > "$builtin_manifest" <<'YAML'
version: 1
tiers:
  tier1:
    allowed_tools: Bash(command -v:*) Bash(which:*)
tasks: {}
repos: []
community: []
YAML
  local derived field found_dot=0
  derived="$(PATH=".:/usr/bin:/bin" MEUTE_MANIFEST="$builtin_manifest" \
             bash -c 'source "$1"; unit_path_line' _ "$REPO/bin/meute")"
  local -a derived_fields; IFS=':' read -ra derived_fields <<< "$derived"
  for field in "${derived_fields[@]}"; do
    [[ "$field" == "." ]] && found_dot=1
  done
  is "unit_path_line: a builtin's non-path answer never becomes a PATH entry" \
     "$found_dot" "0"
  # The guard must reject only the relative answer, not the whole scan: the
  # real binary named alongside it still has to land.
  has "unit_path_line: ...while a real binary on the same list still resolves" \
      "$derived" "/usr/bin"

  # build_entry resolves allowed_tools as the FIRST non-empty of
  # (task, project, tier) -- a task-level list REPLACES the tier's, so a task
  # can need a binary no tier ever names. dep-audit is exactly that in the
  # real manifest: osv-scanner/pip-audit/grype/govulncheck appear only under
  # its own allowed_tools. Scanning tiers alone left them off the unit's PATH.
  local task_dir="$FIXTURE/unitpath-task" proj_dir="$FIXTURE/unitpath-proj"
  mkdir -p "$task_dir" "$proj_dir"
  : > "$task_dir/task-only-probe"; chmod +x "$task_dir/task-only-probe"
  : > "$proj_dir/project-only-probe"; chmod +x "$proj_dir/project-only-probe"
  local levels_manifest="$FIXTURE/unitpath/levels-manifest.yaml"
  cat > "$levels_manifest" <<'YAML'
version: 1
tiers:
  tier1:
    allowed_tools: Bash(git:*)
tasks:
  dep-audit-ish:
    allowed_tools: Bash(task-only-probe:*) Bash(git:*)
repos:
- name: alpha
  allowed_tools: Bash(project-only-probe:*)
community: []
YAML
  out="$(PATH="$task_dir:$proj_dir:/usr/bin:/bin" MEUTE_MANIFEST="$levels_manifest" \
         bash -c 'source "$1"; unit_path_line' _ "$REPO/bin/meute")"
  has "unit_path_line: includes a dir only a TASK's allowed_tools names" \
      "$out" "$task_dir"
  has "unit_path_line: includes a dir only a PROJECT's allowed_tools names" \
      "$out" "$proj_dir"
}

# dedup_dirs backs the one line in `doctor` that used to crash it: `grep -v`
# exits 1 when it selects zero lines, exactly what an empty missing-binaries
# list produces, and a plain (non-`local`) assignment takes on that as its own
# exit status -- which under `set -e` killed `doctor` with no message on the
# one machine state (nothing missing) that should be the easiest to report.
# Exercises the real function, not a copy, so a regression here is caught
# regardless of what this test machine happens to have on PATH or in cron.
test_dedup_dirs() {
  local out rc
  out="$(bash -c 'set -Eeuo pipefail; source "$1"; dedup_dirs' _ "$REPO/bin/meute")"; rc=$?
  is "dedup_dirs: no args does not abort under set -e" "$rc" "0"
  is "dedup_dirs: no args joins to nothing"             "$out" ""

  out="$(bash -c 'set -Eeuo pipefail; source "$1"; dedup_dirs "" ""' _ "$REPO/bin/meute")"; rc=$?
  is "dedup_dirs: all-blank args do not abort under set -e" "$rc" "0"
  is "dedup_dirs: all-blank args join to nothing"            "$out" ""

  out="$(bash -c 'set -Eeuo pipefail; source "$1"; dedup_dirs /b /a /a' _ "$REPO/bin/meute")"
  is "dedup_dirs: sorts and de-duplicates" "$out" "/a:/b"
}


# A timer can be `enabled` and inert at the same time. The doctor used to assert
# `is-enabled`, which reads the on-disk symlink, so it printed "ok" over two
# timers with no next firing — the fleet reported itself deployable and would
# never have run. These pin the distinction, driven by recorded `systemctl show`
# output so they hold on a machine with no systemd at all.
test_timer_arming() {
  local stub="$FIXTURE/stub"; mkdir -p "$stub"
  cat > "$stub/systemctl" <<'SH'
#!/usr/bin/env bash
[[ "${STUB_SYSTEMCTL_FAIL:-}" == 1 ]] && { echo "Failed to connect to user scope bus" >&2; exit 1; }
printf '%s\n' "${STUB_SHOW:-}"
SH
  cat > "$stub/loginctl" <<'SH'
#!/usr/bin/env bash
[[ "${STUB_LOGINCTL_FAIL:-}" == 1 ]] && { echo "Host is down" >&2; exit 1; }
printf '%s\n' "${STUB_LINGER:-}"
SH
  chmod +x "$stub/systemctl" "$stub/loginctl"

  # Sourced, not run: the helpers are the unit under test.
  local call='source "$1"; shift; "$@"'
  probe() { PATH="$stub:$PATH" bash -c "$call" _ "$FIXTURE/bin/meute" "$@"; }

  local out
  out="$(STUB_SHOW='LoadState=loaded
ActiveState=active
UnitFileState=enabled
NextElapseUSecRealtime=Sun 2026-08-30 02:02:03 EDT' probe timer_state meute-daily.timer)"
  is "timer: a unit with a next elapse is armed" "$out" "$(printf 'armed\tSun 2026-08-30 02:02:03 EDT')"

  # The regression. `is-enabled` answers "enabled" for exactly this state.
  out="$(STUB_SHOW='LoadState=loaded
ActiveState=inactive
UnitFileState=enabled
NextElapseUSecRealtime=' probe timer_state meute-daily.timer)"
  is "timer: enabled with no next elapse is idle, not armed" "$out" "$(printf 'idle\tenabled')"

  # Not every systemd leaves this empty for an inert timer; "0" and "n/a" are
  # the other spellings, and reading either as a time is the false positive
  # this whole helper exists to prevent.
  local spelling
  for spelling in 0 n/a; do
    out="$(STUB_SHOW="LoadState=loaded
ActiveState=inactive
UnitFileState=enabled
NextElapseUSecRealtime=${spelling}" probe timer_state meute-daily.timer)"
    is "timer: a next elapse of '${spelling}' is idle, not armed" "$out" "$(printf 'idle\tenabled')"
  done

  out="$(STUB_SHOW='LoadState=not-found
ActiveState=inactive
UnitFileState=
NextElapseUSecRealtime=' probe timer_state meute-daily.timer)"
  is "timer: an unknown unit is absent" "$out" "$(printf 'absent\t')"

  out="$(STUB_SYSTEMCTL_FAIL=1 probe timer_state meute-daily.timer)"
  is "timer: an unreachable systemd is nobus, not a verdict" "$out" "$(printf 'nobus\t')"

  # `loginctl` needs the system bus, which a container lacks even when the user
  # bus works. A failed query is not a "no": it sent you to a remedy that errors.
  is "linger: yes is reported"      "$(STUB_LINGER=yes probe linger_state)" "yes"
  is "linger: no is reported"       "$(STUB_LINGER=no  probe linger_state)" "no"
  is "linger: an unreachable system bus is unknown, not off" \
     "$(STUB_LOGINCTL_FAIL=1 probe linger_state)" "unknown"
  is "linger: an unparseable answer is unknown" \
     "$(STUB_LINGER='Host is down' probe linger_state)" "unknown"

  # Whatever the doctor says about a timer, it must be a claim about firing.
  local d; d="$(meute doctor 2>&1)"
  if [[ "$d" == *"meute-daily.timer"* ]]; then
    [[ "$d" == *"armed"* ]] && ok "doctor: speaks about arming, not about symlinks" \
      || bad "doctor: speaks about arming, not about symlinks" "[$d] never says armed"
  else
    ok "doctor: speaks about arming, not about symlinks (no units on this machine)"
  fi
}


# install-timers used to pipe its own verification to /dev/null: it printed
# "0 timers listed" and reported success over two timers it had not started.
# Driven entirely by a stubbed systemctl and a throwaway HOME, so the real
# units on the machine running the suite are never touched.
test_install_timers() {
  local home="$FIXTURE/fakehome" stub="$FIXTURE/stub2"
  mkdir -p "$home" "$stub"
  cat > "$stub/systemctl" <<'SH'
#!/usr/bin/env bash
[[ "$*" == *show* ]] && printf '%s\n' "${STUB_SHOW:-}"
exit 0
SH
  printf '#!/usr/bin/env bash\nprintf "yes\\n"\n' > "$stub/loginctl"
  chmod +x "$stub/systemctl" "$stub/loginctl"

  # XDG_CONFIG_HOME rather than HOME: systemd's own rule for where user units
  # live, and overriding HOME hides the user-site PyYAML from python3, which
  # install-timers now needs to read the cadence from the manifest.
  install_with() {
    XDG_CONFIG_HOME="$home/.config" PATH="$stub:$PATH" STUB_SHOW="$1" \
      "$FIXTURE/bin/meute" install-timers 2>&1
  }

  local out rc
  out="$(install_with 'LoadState=loaded
UnitFileState=enabled
ActiveState=active
NextElapseUSecRealtime=Sun 2026-08-30 03:17:00 EDT')"; rc=$?
  is  "install-timers: exits 0 when both timers are armed" "$rc" "0"
  has "install-timers: reports the next firing"            "$out" "armed - next Sun 2026-08-30 03:17:00 EDT"
  [[ -f "$home/.config/systemd/user/meute-daily.timer" ]] \
    && ok "install-timers: writes the unit files" \
    || bad "install-timers: writes the unit files" "no meute-daily.timer under $home"
  # The fixture manifest declares no cadence, so the timers carry the defaults.
  has "install-timers: default daily cadence reaches the timer"  \
      "$(grep OnCalendar "$home/.config/systemd/user/meute-daily.timer")"  "*-*-* 03:17:00"
  has "install-timers: default weekly cadence reaches the timer" \
      "$(grep OnCalendar "$home/.config/systemd/user/meute-weekly.timer")" "Sat *-*-* 04:41:00"

  # A cadence declared in the manifest is what gets written, and a bad one
  # is refused before any unit is touched.
  python3 - "$FIXTURE" <<'PY2'
import sys, pathlib, yaml
fx = pathlib.Path(sys.argv[1]); d = yaml.safe_load((fx/"repos.yaml").read_text())
d["policy"]["daily_calendar"] = "*-*-* 03/4:17:00"
yaml.safe_dump(d, open(fx/"cadence.yaml", "w"), sort_keys=False)
d["policy"]["daily_calendar"] = "every other tuesday"
yaml.safe_dump(d, open(fx/"badcadence.yaml", "w"), sort_keys=False)
PY2
  MEUTE_MANIFEST="$FIXTURE/cadence.yaml" install_with 'LoadState=loaded
UnitFileState=enabled
ActiveState=active
NextElapseUSecRealtime=Sun 2026-08-30 03:17:00 EDT' >/dev/null
  has "install-timers: a declared cadence reaches the timer" \
      "$(grep OnCalendar "$home/.config/systemd/user/meute-daily.timer")" "*-*-* 03/4:17:00"
  local before; before="$(cat "$home/.config/systemd/user/meute-daily.timer")"
  out="$(MEUTE_MANIFEST="$FIXTURE/badcadence.yaml" install_with '' )"; rc=$?
  is  "install-timers: refuses an invalid OnCalendar spec" "$rc" "1"
  has "install-timers: ...and names the policy key"        "$out" "policy.daily_calendar"
  is  "install-timers: ...without touching the units"      "$(cat "$home/.config/systemd/user/meute-daily.timer")" "$before"

  # The regression: enabled, and nothing scheduled.
  out="$(install_with 'LoadState=loaded
UnitFileState=enabled
ActiveState=inactive
NextElapseUSecRealtime=')"; rc=$?
  is  "install-timers: fails when the timers were never armed" "$rc" "1"
  has "install-timers: names the inert units"                  "$out" "meute-daily.timer is NOT armed"
  has "install-timers: says how to arm them"                   "$out" "systemctl --user start meute-daily.timer meute-weekly.timer"
}


# The quota gate measures meute's own spend, not yours: `meute status` can read
# 100% while your subscription pool is nearly gone, and the next slot then
# spends the window you wanted for your own work. `pause` is the only thing that
# stops it. A hold carries an expiry so a fleet cannot be paused into silence.
test_pause() {
  local root="$FIXTURE/hold"
  mkdir -p "$root/state"
  ln -sfn "$REPO/bin" "$root/bin"
  ln -sfn "$REPO/lib" "$root/lib"
  cp "$FIXTURE/repos.yaml" "$root/repos.yaml"
  local M=( env MEUTE_MANIFEST="$root/repos.yaml" )

  # hold_active is read by both binaries, so test it where they read it.
  held() {  # $1 = MEUTE_NOW; echoes "yes"/"no"
    MEUTE_NOW="$1" bash -c '
      source "$1/lib/state.sh"; source "$1/lib/fleet.sh"
      HOLD_FILE="$1/state/hold"
      hold_active && echo yes || echo no' _ "$root"
  }

  local out rc
  out="$("${M[@]}" MEUTE_NOW=1000000 "$root/bin/meute" pause --for 3d -r "saving quota" 2>&1)"; rc=$?
  is  "pause: exits 0"                    "$rc" "0"
  has "pause: names the expiry"           "$out" "fleet paused until"
  has "pause: repeats the reason"         "$out" "saving quota"
  has "pause: says the hold is not fleet config" "$out" "local to this machine"
  is  "pause: the hold is in force"       "$(held 1000001)" "yes"

  out="$("${M[@]}" MEUTE_NOW=1000001 "$root/bin/meute" status 2>&1)"
  has "pause: status leads with the pause, not the quota" "$out" "PAUSED until"
  has "pause: status says how to lift it"                 "$out" "meute resume"

  # 3d from 1000000. One second before it lapses, and one second after.
  is "pause: the hold holds right up to its expiry" "$(held $(( 1000000 + 259199 )))" "yes"
  is "pause: an expired hold lifts itself"          "$(held $(( 1000000 + 259201 )))" "no"

  # A run declines before it needs a lock, a manifest or a quota probe.
  rm -f "$root/state/log"
  out="$(MEUTE_NOW=1000001 "$root/bin/run.sh" daily 2>&1)"; rc=$?
  is  "pause: a paused run exits 0 - declining is not a failure" "$rc" "0"
  has "pause: the run is logged as skipped"   "$out" "status=skipped"
  has "pause: the log says why"               "$out" "reason=paused until"
  hasnt "pause: it never reached the engine"  "$out" "auth="

  # A paused week must not eat the budget it was declared to protect.
  local pct
  pct="$(MEUTE_ROOT="$root" MEUTE_WEEKLY_COST_USD=15 "$REPO/contrib/quota-self-budget.sh")"
  is "pause: a declined run consumes no budget" "$pct" "100"

  # Bounded on purpose: no spelling of "forever".
  for bad in banana 0h 500d 3 '' ; do
    "${M[@]}" "$root/bin/meute" pause --for "$bad" >/dev/null 2>&1
    is "pause: rejects --for '${bad}'" "$?" "1"
  done
  is "pause: a rejected duration left the hold alone" "$(held 1000001)" "yes"

  out="$("${M[@]}" MEUTE_NOW=1000001 "$root/bin/meute" resume 2>&1)"; rc=$?
  is  "resume: exits 0"                "$rc" "0"
  has "resume: says the fleet is free" "$out" "hold lifted"
  is  "resume: the hold is gone"       "$(held 1000001)" "no"
  out="$("${M[@]}" MEUTE_NOW=1000001 "$root/bin/meute" resume 2>&1)"
  has "resume: is idempotent"          "$out" "no hold in force"
  [[ ! -e "$root/state/hold" ]] \
    && ok "resume: leaves nothing behind" \
    || bad "resume: leaves nothing behind" "$root/state/hold still exists"

  # The help text promises a hold is local to this machine. state/ is ignored
  # file by file, so a new file there is committed unless someone says otherwise.
  git -C "$REPO" check-ignore -q state/hold \
    && ok "pause: the hold is gitignored, as the help text promises" \
    || bad "pause: the hold is gitignored, as the help text promises" "state/hold is tracked"
}

# hold_extend is what an automatic hold (a provider rate limit) goes through
# instead of hold_set directly -- a manual pause the user set on purpose must
# never be shortened by one.
test_hold_extend() {
  local root="$FIXTURE/hold_extend"
  mkdir -p "$root/state"
  ln -sfn "$REPO/lib" "$root/lib"

  hx() {  # $1=MEUTE_NOW $2=seconds $3=reason -> resulting epoch, on stdout
    MEUTE_NOW="$1" bash -c '
      source "$1/lib/state.sh"; source "$1/lib/fleet.sh"
      HOLD_FILE="$1/state/hold"
      hold_extend "$2" "$3"' _ "$root" "$2" "$3"
  }
  row() { cat "$root/state/hold" 2>/dev/null; }

  is  "hold_extend: sets a hold when none is active" "$(hx 1000000 3600 'auto: first')" "1003600"
  has "hold_extend: records the reason"              "$(row)" "auto: first"

  is    "hold_extend: a shorter candidate does not shrink an active hold" \
        "$(hx 1000001 60 'auto: shorter')" "1003600"
  hasnt "hold_extend: the reason is untouched" "$(row)" "auto: shorter"

  is  "hold_extend: a longer candidate does extend it" \
      "$(hx 1000001 86400 'auto: longer')" "1086401"
  has "hold_extend: the reason updates with it" "$(row)" "auto: longer"
}

# The claude CLI's own event name (subtype) reads "success" even when
# is_error is true and the real cause was an HTTP 429 -- the fix was to check
# api_error_status instead of trusting subtype, discovered from a real
# unattended run that hit the account's weekly limit.
test_engines() {
  local root="$FIXTURE/engines" out
  mkdir -p "$root"
  source "$REPO/lib/engines.sh"

  out="$root/ok.json"
  printf '%s' '{"result":"all clear","total_cost_usd":0.01,"num_turns":3,"is_error":false}' > "$out"
  extract_claude "$out"
  is "engines: ok clears ENGINE_DETAIL" "$ENGINE_STATUS:$ENGINE_DETAIL" "ok:"
  is "engines: ok is not rate-limited"  "$RATE_LIMITED" "0"

  out="$root/other-error.json"
  printf '%s' '{"result":"","is_error":true,"subtype":"error_max_turns"}' > "$out"
  extract_claude "$out" || true
  is "engines: a non-429 error keeps its own subtype" "$ENGINE_STATUS:$ENGINE_DETAIL" "error:error_max_turns"
  is "engines: a non-429 error is not rate-limited"    "$RATE_LIMITED" "0"

  out="$root/rate-limited.json"
  printf '%s' '{"result":"You have hit your weekly limit - resets 3pm (America/New_York)","is_error":true,"subtype":"success","api_error_status":429}' > "$out"
  extract_claude "$out" || true
  is  "engines: a 429 is flagged rate-limited" "$RATE_LIMITED" "1"
  is  "engines: a 429 status is still error"   "$ENGINE_STATUS" "error"
  has "engines: detail says what happened, not the misleading subtype" "$ENGINE_DETAIL" "rate-limited:"
  has "engines: detail carries the provider's own message"             "$ENGINE_DETAIL" "hit your weekly limit"
}


# The self-budget source: a cap on meute's own footprint, computed from its own
# log. This is the first quota source that actually makes the gate fire.
test_self_budget() {
  local log="$FIXTURE/budget/state/log" adapter="$REPO/contrib/quota-self-budget.sh"
  mkdir -p "$FIXTURE/budget/state" "$FIXTURE/budget/bin" "$FIXTURE/budget/contrib"
  ln -sfn "$REPO/contrib/quota-self-budget.sh" "$FIXTURE/budget/contrib/q.sh"
  local run="$FIXTURE/budget/contrib/q.sh" wk; wk="$(date +%G-%V)"
  : > "$log"

  is "budget: empty log is 100%" "$(MEUTE_WEEKLY_RUNS=10 "$run")" "100"

  local i
  for i in 1 2 3 4 5; do printf 'ts\tweek=%s\tstatus=ok\tcost=0.20\n' "$wk" >> "$log"; done
  is "budget: 5 of 10 runs leaves 50%"  "$(MEUTE_WEEKLY_RUNS=10 "$run")" "50"
  is "budget: 5 of 5 runs leaves 0%"    "$(MEUTE_WEEKLY_RUNS=5 "$run")"  "0"
  is "budget: \$1.00 of \$2.00 leaves 50%" "$(MEUTE_WEEKLY_COST_USD=2.00 "$run")" "50"

  # skips consumed nothing and must not count
  printf 'ts\tweek=%s\tstatus=skipped\treason=x\n' "$wk" >> "$log"
  is "budget: skipped runs do not consume budget" "$(MEUTE_WEEKLY_RUNS=10 "$run")" "50"

  # a different ISO week must not count
  printf 'ts\tweek=1999-01\tstatus=ok\tcost=9.00\n' >> "$log"
  is "budget: other weeks are excluded" "$(MEUTE_WEEKLY_RUNS=10 "$run")" "50"

  local rc
  "$run" >/dev/null 2>&1; rc=$?
  is "budget: refuses to guess when unconfigured" "$rc" "1"
  MEUTE_WEEKLY_RUNS=5 MEUTE_WEEKLY_COST_USD=5 "$run" >/dev/null 2>&1; rc=$?
  is "budget: refuses two budgets at once" "$rc" "1"
}


# A ceiling declared in the manifest must apply with no env vars, or it silently
# reverts to the stub the moment someone forgets a line in their crontab.
test_manifest_ceiling() {
  local root="$FIXTURE/ceiling"
  mkdir -p "$root/state" "$root/tasks"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"
  ln -sfn "$REPO/contrib" "$root/contrib"
  cp "$REPO"/tasks/*.md "$root/tasks/"
  python3 - "$root" <<'PY'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.20,
               "tier3_max_in_flight": 3, "branch_prefix": "meute",
               "weekly_cost_usd": 10.0},
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"audit-security": {"tier": "tier2", "template": "tasks/audit-security.md",
                                 "slots": ["daily"]}},
    "repos": [], "community": [],
}, open(root/"repos.yaml", "w"), sort_keys=False)
PY
  local wk; wk="$(date +%G-%V)"; : > "$root/state/log"

  # the ceiling must be readable as policy, and reject a double ceiling
  is "ceiling: parsed from the manifest" \
     "$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" policy "$root/repos.yaml" | jq -r .weekly_cost_usd)" "10.0"

  python3 - "$root" <<'PY'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1]); d = yaml.safe_load((root/"repos.yaml").read_text())
d["policy"]["weekly_runs"] = 5
yaml.safe_dump(d, open(root/"both.yaml", "w"), sort_keys=False)
PY
  local err; err="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" validate "$root/both.yaml" 2>&1 || true)"
  has "ceiling: refuses two ceilings at once" "$err" "not both"

  # the self-budget adapter must compute against the declared ceiling
  local i
  for i in 1 2 3; do printf 'ts\tweek=%s\tstatus=ok\tcost=2.00\n' "$wk" >> "$root/state/log"; done
  is "ceiling: \$6 of \$10 leaves 40%" \
     "$(MEUTE_WEEKLY_COST_USD=10.0 MEUTE_ROOT="$root" "$REPO/contrib/quota-self-budget.sh")" "40"
  for i in 1 2; do printf 'ts\tweek=%s\tstatus=ok\tcost=2.00\n' "$wk" >> "$root/state/log"; done
  is "ceiling: exhausted reads 0%" \
     "$(MEUTE_WEEKLY_COST_USD=10.0 MEUTE_ROOT="$root" "$REPO/contrib/quota-self-budget.sh")" "0"
}


# The subscription gate: PRP-001 §3 step 4, finally measuring the thing it is
# for. Source is the status line's rate_limits snapshot; the adapter reports
# the scarcer of the 5h/7d pools, and a window past its resets_at counts as
# fresh.
test_subscription_gate() {
  local root="$FIXTURE/subq"; mkdir -p "$root/state"
  ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  ln -sfn "$REPO/lib" "$root/lib"
  local snap="$root/state/rate-limits.json" cap="$REPO/contrib/statusline-capture.sh"
  local adapter="$root/contrib/quota-subscription.sh"

  # -- adapter arithmetic --
  printf '{"captured_at":1,"five_hour":{"used_percentage":23.5,"resets_at":9999999999},"seven_day":{"used_percentage":41.2,"resets_at":9999999999}}' > "$snap"
  is "subscription: reports the scarcer pool, ceilinged" "$(MEUTE_ROOT="$root" "$adapter")" "58"
  printf '{"captured_at":1,"five_hour":{"used_percentage":90,"resets_at":500},"seven_day":{"used_percentage":41.2,"resets_at":9999999999}}' > "$snap"
  is "subscription: a window past resets_at counts as fresh" "$(MEUTE_ROOT="$root" MEUTE_NOW=1000 "$adapter")" "58"
  printf '{"captured_at":1,"five_hour":{"used_percentage":100,"resets_at":9999999999}}' > "$snap"
  is "subscription: a single window is enough"            "$(MEUTE_ROOT="$root" "$adapter")" "0"
  printf '{"captured_at":1}' > "$snap"
  MEUTE_ROOT="$root" "$adapter" >/dev/null 2>&1
  is "subscription: a snapshot with no window is not a source" "$?" "1"
  rm -f "$snap"
  MEUTE_ROOT="$root" "$adapter" >/dev/null 2>&1
  is "subscription: no snapshot fails, never guesses"     "$?" "1"

  # -- quota.sh precedence: snapshot beats the override and the stub --
  printf '{"captured_at":1,"seven_day":{"used_percentage":70,"resets_at":9999999999}}' > "$snap"
  printf '99\n' > "$root/state/quota-override"
  is "quota.sh: the snapshot outranks the override file" \
     "$(MEUTE_QUOTA_STUB=100 "$root/bin/quota.sh" --with-source)" "30 quota-subscription.sh"
  is "quota.sh: an explicit MEUTE_QUOTA_CMD still outranks the snapshot" \
     "$(MEUTE_QUOTA_CMD='echo 42' "$root/bin/quota.sh")" "42"
  printf 'not json' > "$snap"
  "$root/bin/quota.sh" >/dev/null 2>&1
  is "quota.sh: an unreadable snapshot fails closed, no fallback" "$?" "1"
  rm -f "$snap" "$root/state/quota-override"

  # -- the capture wrapper --
  local out
  out="$(printf '{"model":{"display_name":"M"},"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":9999999999}}}' \
         | MEUTE_ROOT="$root" "$cap" -- 'jq -r .model.display_name')"
  is  "capture: the wrapped status line still gets stdin and speaks" "$out" "M"
  is  "capture: the snapshot carries the window" "$(jq -r .five_hour.used_percentage "$snap")" "5"
  has "capture: ...and when it was taken"        "$(jq -r 'has("captured_at")' "$snap")" "true"
  printf '{"model":{"display_name":"M"}}' | MEUTE_ROOT="$root" "$cap" -- 'true'
  is  "capture: a document without rate_limits leaves the last snapshot alone" \
      "$(jq -r .five_hour.used_percentage "$snap")" "5"
  out="$(printf '{}' | MEUTE_ROOT="$root" "$cap")"; rc=$?
  is  "capture: with nothing to wrap it prints nothing and exits 0" "${rc}:${out}" "0:"

  # -- install-statusline edits settings.json, carefully --
  local cfg="$root/claude"; mkdir -p "$cfg"
  printf '{"model":"opus","statusLine":{"type":"command","command":"echo \\"it'"'"'s $HOME\\""}}' > "$cfg/settings.json"
  CLAUDE_CONFIG_DIR="$cfg" "$root/bin/meute" install-statusline >/dev/null 2>&1
  is  "install-statusline: exits 0" "$?" "0"
  local wrapped; wrapped="$(jq -r .statusLine.command "$cfg/settings.json")"
  has "install-statusline: the wrapper leads"               "$wrapped" "statusline-capture.sh --"
  is  "install-statusline: other settings survive"          "$(jq -r .model "$cfg/settings.json")" "opus"
  [[ -f "$cfg/settings.json.meute-bak" ]] && ok "install-statusline: backs the file up first" \
    || bad "install-statusline: backs the file up first" "no .meute-bak"
  # The original, quotes and $HOME and all, must run exactly as before.
  is  "install-statusline: the original command runs unchanged inside the wrapper" \
      "$(printf '{}' | MEUTE_ROOT="$root" sh -c "$wrapped")" "it's $HOME"
  CLAUDE_CONFIG_DIR="$cfg" "$root/bin/meute" install-statusline >/dev/null 2>&1
  is  "install-statusline: idempotent" \
      "$(jq -r .statusLine.command "$cfg/settings.json" | grep -o 'statusline-capture' | wc -l)" "1"
  printf '{broken' > "$cfg/settings.json"
  CLAUDE_CONFIG_DIR="$cfg" "$root/bin/meute" install-statusline >/dev/null 2>&1
  is  "install-statusline: refuses to touch invalid JSON" "$?" "1"
  is  "install-statusline: ...and leaves it as it found it" "$(cat "$cfg/settings.json")" "{broken"
}

# Two gates, and a run must clear both. Before this the self-budget REPLACED the
# subscription probe whenever no MEUTE_QUOTA_CMD was set, so "quota 100% · ok"
# meant "meute has not spent its own allowance" and said nothing about the
# pool the human shares -- the one constraint the whole design is for.
test_two_gates() {
  local root="$FIXTURE/gates"
  mkdir -p "$root/state" "$root/tasks" "$root/git-r"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"
  ln -sfn "$REPO/contrib" "$root/contrib"
  cp "$REPO"/tasks/*.md "$root/tasks/"
  git -C "$root/git-r" init -q -b main
  echo x > "$root/git-r/f"; git -C "$root/git-r" add -A
  git -C "$root/git-r" -c user.email=t@t -c user.name=t commit -qm init
  python3 - "$root" <<'PY2'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.20,
               "tier3_max_in_flight": 3, "branch_prefix": "meute", "weekly_cost_usd": 10.0},
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"audit-security": {"tier": "tier2", "template": "tasks/audit-security.md", "slots": ["daily"]}},
    "repos": [{"name": "r", "path": str(root / "git-r"), "spec": "fixture", "tasks": ["audit-security"]}],
    "community": [],
}, open(root / "repos.yaml", "w"), sort_keys=False)
PY2
  local wk; wk="$(date +%G-%V)"
  local snap="$root/state/rate-limits.json" out

  # Pool fine, meute's own ceiling spent -> declines, and says it is the ceiling.
  printf '{"captured_at":1,"seven_day":{"used_percentage":10,"resets_at":9999999999}}' > "$snap"
  : > "$root/state/log"
  printf 'ts\tweek=%s\tstatus=ok\tcost=10.00\n' "$wk" >> "$root/state/log"
  out="$("$root/bin/run.sh" daily 2>&1)"
  has "gates: a spent self-budget declines even with pool to spare" "$out" "status=skipped"
  has "gates: ...naming the ceiling as the reason"                  "$out" "own weekly ceiling"
  has "gates: ...with the budget reading on the log line"           "$out" "budget=0"

  # Ceiling fine, pool below the floor -> declines, and says it is the pool.
  : > "$root/state/log"
  printf '{"captured_at":1,"seven_day":{"used_percentage":80,"resets_at":9999999999}}' > "$snap"
  out="$("$root/bin/run.sh" daily 2>&1)"
  has "gates: a scarce pool declines even with self-budget to spare" "$out" "status=skipped"
  has "gates: ...naming the floor as the reason"                     "$out" "below floor 30%"
  has "gates: ...and the real source, not the stub"                  "$out" "quota=20:quota-subscription.sh"

  # Both clear -> the run proceeds to selection.
  printf '{"captured_at":1,"seven_day":{"used_percentage":10,"resets_at":9999999999}}' > "$snap"
  out="$("$root/bin/run.sh" daily --dry-run 2>&1)"
  has "gates: both clear and the run goes ahead" "$out" "would run: key=r/audit-security"

  # The agent's cwd is the worktree and dontAsk refuses reads outside it, so
  # the prompt must say the checkout is the worktree -- not the repo it was
  # cut from, which is what the first market-comparison run was told and
  # could not read.
  local prompt; prompt="$(grep -oE 'prompt=\S+' <<< "$out" | cut -d= -f2)"
  has   "prompt: names the worktree as the checkout"  "$(grep -m1 'checked out at' "$prompt")" ".worktrees/r-audit-security-"
  hasnt "prompt: ...not the repo it was cut from"     "$(grep -m1 'checked out at' "$prompt")" "git-r\`"
}

# End to end through the real runner with a stubbed engine: the first test that
# reaches past the gates into worktree -> invoke -> report. The stub `claude`
# answers preflight and emits a minimal envelope; what it "read" is what was
# in its cwd, so a file carried into the worktree shows up in the report.
test_worktree_files() {
  local root="$FIXTURE/wtfiles" repo="$FIXTURE/wtfiles/git-and"
  mkdir -p "$root/state" "$root/tasks" "$root/stub" "$repo"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  printf 'Task {{REPO_NAME}} {{REPO_PATH}} {{FILE_BUDGET}} {{LENS}} {{REPORT_PATH}} {{DATE}} {{BRANCH}} {{TASK}} {{TIER}} {{REPO_SPEC}} {{ALLOWED_COMMANDS}} {{DEFAULT_BRANCH}} {{UPSTREAM}} {{ETIQUETTE}} {{ETIQUETTE_CONTENT}} {{TICKET_ID}} {{TICKET_TITLE}} {{TICKET_NOTES}}\n' > "$root/tasks/t.md"

  git -C "$repo" init -q -b main
  printf 'local.properties\n' > "$repo/.gitignore"
  echo x > "$repo/f.txt"; git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init
  printf 'sdk.dir=/opt/sdk\n' > "$repo/local.properties"        # gitignored: a worktree never has it

  # The stub engine: preflight passes; the "report" is a listing of its cwd.
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
for var in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_API_URL ANTHROPIC_ENDPOINT OPENAI_API_KEY OPENAI_BASE_URL OPENAI_API_BASE OPENAI_ORG_ID OPENAI_PROJECT CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
  [[ -z "${!var+x}" ]] || { printf 'unsafe inherited engine variable: %s\n' "$var" >&2; exit 91; }
done
if [[ "$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
files="$(ls -A | tr '\n' ' ')"
jq -n --arg r "## Summary
cwd holds: ${files}" '{is_error:false,result:$r,total_cost_usd:0.01,num_turns:1}'
STUB
  chmod +x "$root/stub/claude"

  python3 - "$root" "$repo" <<'PY2'
import sys, pathlib, yaml
root, repo = sys.argv[1], sys.argv[2]
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.20,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"t": {"tier": "tier2", "template": "tasks/t.md", "slots": ["daily"]}},
    "repos": [{"name": "and", "path": repo, "spec": "android fixture", "tasks": ["t"],
               "worktree_files": ["local.properties", "does/not/exist.txt"]}],
    "community": [],
}, open(pathlib.Path(root) / "repos.yaml", "w"), sort_keys=False)
PY2

  local out
  local -a blocked_engine_vars=(
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_API_URL ANTHROPIC_ENDPOINT
    OPENAI_API_KEY OPENAI_BASE_URL OPENAI_API_BASE OPENAI_ORG_ID OPENAI_PROJECT
    CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
    HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
  )
  out="$(env PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "${blocked_engine_vars[@]/%/=sentinel}" "$root/bin/run.sh" daily 2>&1)"
  has "worktree_files: the run completes through the stub engine" "$out" "status=ok"
  has "engine environment: routing, proxy, and credential variables are scrubbed" "$out" "scrubbed=ANTHROPIC_API_KEY"
  has "worktree_files: the runner says what it carried across"     "$out" "carried local.properties"
  local report; report="$(ls "$root"/reports/and/t-*.md | head -1)"
  has "worktree_files: the gitignored file was there when the engine ran" \
      "$(cat "$report")" "local.properties"
  has "worktree_files: ...alongside the tracked one"               "$(cat "$report")" "f.txt"
  hasnt "worktree_files: a missing source is skipped, not an error" "$out" "does/not/exist"
  is  "worktree_files: the main checkout was never touched" \
      "$(git -C "$repo" status --porcelain | wc -l)" "0"

  # A syntactically safe manifest path must still not follow a local symlink.
  mkdir -p "$root/outside"; printf 'not for agents\n' > "$root/outside/secret.txt"
  ln -s "$root/outside/secret.txt" "$repo/linked-secret.txt"
  python3 - "$root" <<'PY4'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
manifest = root / "repos.yaml"
d = yaml.safe_load(manifest.read_text())
d["repos"][0]["worktree_files"] = ["linked-secret.txt"]
yaml.safe_dump(d, manifest.open("w"), sort_keys=False)
PY4
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily 2>&1)"
  has "worktree_files: symlink sources are rejected" "$out" "skipped unsafe worktree file linked-secret.txt"
  local symlink_report; symlink_report="$(ls "$root"/reports/and/t-*.md | sort | tail -1)"
  hasnt "worktree_files: symlink target never reaches the engine" "$(cat "$symlink_report")" "linked-secret.txt"

  # A symlink below the top level used to slip past the walk: the
  # component-by-component check cleared its remainder early when the last
  # two components spelled the same, so a/a -> ../f.txt was carried.
  mkdir -p "$repo/a"; ln -s ../f.txt "$repo/a/a"
  python3 - "$root" <<'PY4'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
manifest = root / "repos.yaml"
d = yaml.safe_load(manifest.read_text())
d["repos"][0]["worktree_files"] = ["a/a"]
yaml.safe_dump(d, manifest.open("w"), sort_keys=False)
PY4
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily 2>&1)"
  has   "worktree_files: a symlink below the top level is rejected" "$out" "skipped unsafe worktree file a/a"
  hasnt "worktree_files: ...and is not carried"                     "$out" "carried a/a"

  # The schema refuses anything that could reach outside the repo.
  local err
  for bad in '"/etc/passwd"' '"../secrets"' '"a/../../b"'; do
    python3 - "$root" "$repo" "$bad" <<'PY3'
import sys, pathlib, yaml, json
root, repo, bad = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
d = yaml.safe_load(open(pathlib.Path(root) / "repos.yaml"))
d["repos"][0]["worktree_files"] = [bad]
yaml.safe_dump(d, open(pathlib.Path(root) / "bad.yaml", "w"), sort_keys=False)
PY3
    err="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" validate "$root/bad.yaml" 2>&1 || true)"
    has "worktree_files: rejects ${bad}" "$err" "relative path inside the repo"
  done
}

# textual-serve deliberately has no authentication. Pin the CLI boundary so an
# accidental --host does not expose report triage on a shared network.
test_web_bind_guard() {
  local out rc
  out="$(bash -c 'source "$1/bin/meute"; tui_python() { printf "%s\\n" /bin/echo; }; cmd_web --host 0.0.0.0' _ "$REPO" 2>&1)"; rc=$?
  is "web: refuses non-loopback without explicit acknowledgement" "$rc" "1"
  has "web: names the required public-bind flag" "$out" "--insecure-public"
  out="$(bash -c 'source "$1/bin/meute"; tui_python() { printf "%s\\n" /bin/echo; }; cmd_web --host 127.0.0.1 --port 8123' _ "$REPO" 2>&1)"
  has "web: loopback remains available without acknowledgement" "$out" "--host 127.0.0.1 --port 8123"
  out="$(bash -c 'source "$1/bin/meute"; tui_python() { printf "%s\\n" /bin/echo; }; cmd_web --host 0.0.0.0 --insecure-public' _ "$REPO" 2>&1)"
  has "web: explicit insecure opt-in permits non-loopback" "$out" "--host 0.0.0.0"
}

# Findings were gated on the task NAME `audit-security` in two places, so the
# other findings-shaped reports (architecture-review, market-comparison, now
# suggest-features) listed as a truncated first line and were invisible to
# `meute findings` and therefore to per-finding promote/dismiss. Any report
# with a `## Findings` section counts now.
test_findings_are_content_driven() {
  local root="$FIXTURE/fcd"; mkdir -p "$root/reports/zeta" "$root/state" "$root/tasks"
  ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/lib" "$root/lib"
  cp "$REPO"/tasks/*.md "$root/tasks/"
  cp "$FIXTURE/repos.yaml" "$root/repos.yaml"
  cat > "$root/reports/zeta/suggest-features-2026-09-06.md" <<'MD'
---
repo: zeta
task: suggest-features
tier: tier2
lens: unfinished
started: 2026-09-06T04:00:00-04:00
status: ok
---

## Summary
Two anchored suggestions.

## Findings

### [HIGH] Finish the export path the TODO at exporter.py:40 abandons
- **Anchor:** `src/exporter.py:40`

### [LOW] Wire the parsed-but-unread `retries` config key
- **Anchor:** `src/config.py:12`
MD
  is  "findings: a suggest-features report is summarised by count" \
      "$(python3 "$REPO/lib/report.py" summary "$root/reports/zeta/suggest-features-2026-09-06.md")" "HIGH×1 LOW×1"
  is  "findings: report.py parses them"     "$(python3 "$REPO/lib/report.py" findings "$root/reports/zeta/suggest-features-2026-09-06.md" | jq length)" "2"
  local out; out="$("$root/bin/meute" findings --all 2>&1)"
  has "findings: meute lists them for triage" "$out" "zeta/suggest-features-2026-09-06#1"
  has "findings: with their priority"         "$out" "HIGH"
  # a report with no Findings section still refuses, so gen-tests stays gen-tests
  python3 "$REPO/lib/report.py" findings "$FIXTURE/reports/beta/gen-tests-2026-08-27.md" >/dev/null 2>&1
  is  "findings: a report without a Findings section is still refused" "$?" "2"
}

# suggest-features is wired the same way the other tier-2 reports are.
test_suggest_features_queued() {
  local root="$FIXTURE/sugg"; mkdir -p "$root"/{state,tasks,git-s}
  ln -sfn "$REPO/lib" "$root/lib"; cp "$REPO/tasks/suggest-features.md" "$root/tasks/"
  git -C "$root/git-s" init -q -b main; echo x > "$root/git-s/f"; git -C "$root/git-s" add -A
  git -C "$root/git-s" -c user.email=t@t -c user.name=t commit -qm init
  python3 - "$root" <<'PY2'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2, "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read,Grep,Glob", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"suggest-features": {"tier": "tier2", "template": "tasks/suggest-features.md",
                                   "slots": ["weekly"], "model": "opus",
                                   "lenses": ["unfinished", "promised", "friction", "adjacent"]}},
    "repos": [{"name": "s", "path": str(root / "git-s"), "spec": "fixture", "tasks": ["suggest-features"]}],
    "community": [],
}, open(root / "repos.yaml", "w"), sort_keys=False)
PY2
  local e; e="$(python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -c 'select(.task=="suggest-features")')"
  is  "suggest-features: read-only tier2"        "$(jq -r .tier <<< "$e")" "tier2"
  is  "suggest-features: never writes code"      "$(jq -r .writes_code <<< "$e")" "false"
  has "suggest-features: four rotating lenses"   "$(jq -c .lenses <<< "$e")" "adjacent"
  hasnt "suggest-features: no web, no Bash"      "$(jq -r .tools <<< "$e")" "Web"
  local pub; pub="$(python3 -c "import yaml;print(yaml.safe_load(open('$REPO/repos.yaml'))['tasks']['suggest-features']['tier'])")"
  is  "suggest-features: registered in the public schema doc" "$pub" "tier2"
}

# discover recorded whatever branch happened to be checked out as the repo's
# default -- five of the first twenty-one repos added were mid-feature, so
# their audits and drafts would have been cut from unfinished work.
test_repo_default_branch() {
  local base="$FIXTURE/defbranch"; mkdir -p "$base"
  mk() { # name initial-branch
    git -C "$base" init -q -b "$2" "$1"; echo x > "$base/$1/f"
    git -C "$base/$1" add -A; git -C "$base/$1" -c user.email=t@t -c user.name=t commit -qm init
  }
  local pick; pick() { bash -c "source '$REPO/bin/meute' >/dev/null 2>&1; repo_default_branch '$1'"; }

  mk on-feature main; git -C "$base/on-feature" checkout -q -b feat/wip
  is "default_branch: main wins over the checked-out feature branch" "$(pick "$base/on-feature")" "main"

  mk on-master master; git -C "$base/on-master" checkout -q -b fix/x
  is "default_branch: master when there is no main"                  "$(pick "$base/on-master")" "master"

  # origin's declared default outranks a local main -- this is the case the
  # set -e bug hid: with NO origin/HEAD the symbolic-ref fails and, unguarded,
  # aborted the function before the main/master fallback could run.
  mk with-origin main; git -C "$base/with-origin" checkout -q -b trunk
  git -C "$base/with-origin" update-ref refs/remotes/origin/trunk HEAD
  git -C "$base/with-origin" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  is "default_branch: origin/HEAD outranks a local main"            "$(pick "$base/with-origin")" "trunk"

  mk neither devel
  is "default_branch: falls back to the checked-out branch"          "$(pick "$base/neither")" "devel"
}

# PRP-003 screen 1. lib/inbox.py is the data layer both the terminal and the
# browser consume; every write goes through bin/meute, so the UI cannot
# disagree with the CLI. Tested against the shared fixture with the system
# python3 -- no Textual, no venv -- which is itself the hard invariant.
test_inbox() {
  local dump py="$REPO/lib/inbox.py"
  dump="$(MEUTE_ROOT="$FIXTURE" python3 "$py" dump)"
  is  "inbox: dump is JSON"          "$(jq -r 'type' <<< "$dump")" "object"
  # The CLI and the data layer must count the same undecided findings.
  is  "inbox: undecided count matches meute findings" \
      "$(jq '[.findings[]|select(.state=="new")]|length' <<< "$dump")" \
      "$(meute findings 2>/dev/null | grep -c '^    NEW')"
  is  "inbox: reports are all listed"  "$(jq '.reports|length' <<< "$dump")" "$(meute reports --all 2>/dev/null | wc -l)"
  has "inbox: dismiss reasons are the CLI's enum" "$(jq -r '.dismiss_reasons|join(" ")' <<< "$dump")" "false-positive wont-fix out-of-scope duplicate too-large other"
  is  "inbox: findings come grouped by repo, most severe first" \
      "$(jq -r '[.findings[]|select(.repo=="alpha" and (.report|endswith("08-28")))|.severity]|join(",")' <<< "$dump")" "CRITICAL,HIGH,HIGH"
  is  "inbox: a finding carries its report id and number" \
      "$(jq -r '.findings[]|select(.repo=="alpha" and .severity=="CRITICAL")|"\(.report)#\(.n)"' <<< "$dump")" "alpha/audit-security-2026-08-28#1"
  is  "inbox: status carries the quota source"  "$(jq -r '.status.quota_source' <<< "$dump")" "stub"
  is  "inbox: quota is explicitly Claude-only" "$(jq -r '.status.quota_engine' <<< "$dump")" "claude"
  is  "inbox: unwired Codex quota is unavailable" "$(jq -r '.status.codex_quota' <<< "$dump")" "null"

  # One finding's markdown, cut at the next finding or the next section.
  local body
  body="$(MEUTE_ROOT="$FIXTURE" python3 -c "
import sys; sys.path.insert(0,'$REPO/lib'); import inbox
print(inbox.finding_body('alpha/audit-security-2026-08-28', 2))")"
  has   "inbox: finding_body starts at its own header" "$body" "### [HIGH] Path traversal"
  hasnt "inbox: ...and stops before the next finding"  "$body" "Unvalidated header"

  # Actions are the CLI's, verbatim: a dismiss through inbox.py is a dismiss.
  local out
  out="$(MEUTE_ROOT="$FIXTURE" python3 "$py" dismiss alpha/audit-security-2026-08-28 3 too-large "via inbox")"
  is  "inbox: dismiss returns ok"        "$(jq -r .ok <<< "$out")" "true"
  is  "inbox: ...and the CLI sees it"    "$(meute findings --all 2>/dev/null | grep 'audit-security-2026-08-28#3' | awk '{print $1}')" "dismissed"
  has "inbox: ...with the reason kept"   "$(grep 'audit-security-2026-08-28#3' "$FIXTURE/state/reports")" "too-large: via inbox"
  out="$(MEUTE_ROOT="$FIXTURE" python3 "$py" dismiss alpha/audit-security-2026-08-28 3 nonsense 2>/dev/null || true)"
  is  "inbox: a bad reason is refused by the CLI, not papered over" "$(jq -r .ok <<< "$out")" "false"

  # The view logic, without a terminal.
  local hdr
  hdr="$(python3 - "$REPO/tui" <<'PY2'
import sys, json
sys.path.insert(0, sys.argv[1])
from model import Model
m = Model.from_dump({
    "findings": [   # in the order inbox.py emits: by repo, then severity
        {"repo": "a", "state": "dismissed", "severity": "HIGH", "task": "t", "lens": "", "title": "gone", "location": ""},
        {"repo": "a", "state": "new", "severity": "HIGH", "task": "t", "lens": "", "title": "needs fix", "location": "x.py:1"},
        {"repo": "b", "state": "new", "severity": "LOW", "task": "t", "lens": "", "title": "low b", "location": ""},
    ],
    "status": {"quota": 12, "quota_source": "quota-subscription.sh", "quota_engine": "claude", "codex_quota": None, "floor": 30, "week": "w", "runs": 1, "declined": 2, "cost": 1.5, "ceiling": 40.0},
})
print("visible", len(m.visible()))
m.show_decided = True; print("all", len(m.visible())); m.show_decided = False
m.query = "x.py"; print("filter", [f["title"] for f in m.visible()]); m.query = ""
print("repos", m.repos(), "jump", m.first_index_of_repo("b"))
print("hdr", m.header_line())
m.status["quota_source"] = "stub"; print("stub", m.header_line())
PY2
)"
  has "model: undecided only by default"        "$hdr" "visible 2"
  has "model: toggle shows decided too"          "$hdr" "all 3"
  has "model: filter matches any column"         "$hdr" "filter ['needs fix']"
  has "model: repo jump targets that repo's first visible row" "$hdr" "repos ['a', 'b'] jump 1"
  has "model: header says Claude is BELOW FLOOR" "$hdr" "Claude quota 12% BELOW FLOOR 30%"
  has "model: header says unwired Codex is unavailable" "$hdr" "Codex unavailable"
  has "model: header carries spend vs ceiling"   "$hdr" "\$1.50 of \$40.0"
  has "model: header counts undecided"           "$hdr" "2 undecided"
  has "model: a stub reads UNMEASURED, never ok" "$hdr" "UNMEASURED (stub)"

  # PRP-003's hard invariant: the runner never depends on the UI.
  is  "invariant: run.sh never references tui/" "$(grep -c 'tui/' "$REPO/bin/run.sh")" "0"
  is  "invariant: lib/ never imports textual"   "$(grep -rlc 'textual' "$REPO/lib" | wc -l)" "0"
  is  "invariant: tui/model.py imports no textual" "$(grep -c 'textual' "$REPO/tui/model.py")" "0"
}

# Pruning deletes branches. The property that matters is not "does it prune"
# but "does it ever delete work that exists nowhere else".
test_branch_prune() {
  local root="$FIXTURE/prune" repo="$FIXTURE/prune/repo"
  mkdir -p "$repo"; ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"
  mkdir -p "$root/tasks" "$root/state"; cp "$REPO"/tasks/*.md "$root/tasks/"
  git -C "$repo" init -q -b main
  local G=(git -C "$repo" -c user.email=t@t -c user.name=t)
  echo base > "$repo/f.txt"; git -C "$repo" add -A; "${G[@]}" commit -qm init
  git -C "$repo" branch meute/ancestor                      # true ancestor
  git -C "$repo" checkout -q -b meute/squashed
  echo feature >> "$repo/f.txt"; git -C "$repo" add -A; "${G[@]}" commit -qm feat
  git -C "$repo" checkout -q main
  echo feature >> "$repo/f.txt"; git -C "$repo" add -A; "${G[@]}" commit -qm "squashed feat"
  echo later > "$repo/other.txt"; git -C "$repo" add -A; "${G[@]}" commit -qm later
  git -C "$repo" checkout -q -b meute/unique main~2
  echo irreplaceable > "$repo/new.txt"; git -C "$repo" add -A; "${G[@]}" commit -qm unique
  git -C "$repo" checkout -q main; git -C "$repo" branch meute/identical

  python3 - "$root" "$repo" <<'PY'
import sys, pathlib, yaml
root, repo = pathlib.Path(sys.argv[1]), sys.argv[2]
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5, "timeout_seconds": 60},
    "policy": {"quota_floor_percent": 30, "community_share": 0.20,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False, "network": "proxied"}},
    "tasks": {"audit-security": {"tier": "tier2", "template": "tasks/audit-security.md",
                                 "slots": ["daily"]}},
    "repos": [{"name": "prunefix", "path": repo, "spec": "fixture",
               "default_branch": "main", "tasks": ["audit-security"]}],
    "community": [],
}, open(root/"repos.yaml", "w"), sort_keys=False)
PY

  local out
  out="$(MEUTE_MANIFEST="$root/repos.yaml" "$root/bin/meute" branches 2>&1)"
  has  "prune: an ancestor branch reads absorbed"  "$out" "meute/ancestor"
  has  "prune: report flags unique work"           "$out" "not in main"

  out="$(MEUTE_MANIFEST="$root/repos.yaml" "$root/bin/meute" branches --prune 2>&1)"
  local left; left="$(git -C "$repo" branch --list 'meute/*' | tr -d ' ' | tr '\n' ' ')"
  is   "prune: only the unique branch survives"    "${left% }" "meute/unique"
  # squash-merge rewrites the commit, so git's own --merged never lists it;
  # content comparison is the only thing that catches this case.
  hasnt "prune: a squash-absorbed branch is removed" "$left" "meute/squashed"
  is   "prune: the unique work is still readable"  "$(git -C "$repo" show meute/unique:new.txt 2>/dev/null)" "irreplaceable"

  out="$(MEUTE_MANIFEST="$root/repos.yaml" "$root/bin/meute" branches --prune 2>&1)"
  has  "prune: is idempotent"                      "$out" "pruned 0"
}


# A report is a row; a decision is made per finding. Acting on one finding must
# not hide the others in the same report.
test_finding_level_triage() {
  local out
  out="$(meute findings --all 2>&1)"
  has "findings: lists per finding, not per report" "$out" "audit-security-2026-08-28#1"
  has "findings: shows the second finding too"      "$out" "audit-security-2026-08-28#2"
  has "findings: severity-first inside a repo"      "$out" "CRITICAL"

  # dismiss one finding; the other must stay visible
  meute dismiss alpha/audit-security-2026-08-28 -f 2 -r false-positive >/dev/null 2>&1
  out="$(meute findings 2>&1)"
  hasnt "findings: a dismissed finding leaves the list" "$out" "audit-security-2026-08-28#2"
  has   "findings: its siblings remain"                 "$out" "audit-security-2026-08-28#3"
  has   "reports: the report is not closed early"       "$(meute reports --all 2>/dev/null | grep '2026-08-28')" "read"
}

# ---------------------------------------------------- PRP-004 phase 1 -------
# The container schema (PRP-004 §4.1), one test per rule. Every rule test
# starts from the §4.1 example merged into tier blocks shaped like
# repos.yaml's, breaks one field, and reads the message; the example itself
# has to validate first or the rejections prove nothing.
readonly P4_DIGEST="sha256:$(printf 'a%.0s' {1..64})"

# Writes $root/repos.yaml and a git repo at $root/git-netlens. Templates are
# the real ones, so MEUTE_ROOT=$REPO for validation and MEUTE_ROOT=$root when
# state/ (stages, tickets) must be the fixture's.
p4_fixture() {
  local root="$1"
  mkdir -p "$root"/{state,tasks,etiquette,git-netlens,git-upstream}
  cp "$REPO"/tasks/*.md "$root/tasks/"
  cp "$REPO/etiquette/example-project.yaml" "$root/etiquette/upstream.yaml"
  local g
  for g in git-netlens git-upstream; do
    git -C "$root/$g" init -q -b main
    echo x > "$root/$g/f.txt"; git -C "$root/$g" add -A
    git -C "$root/$g" -c user.email=t@t -c user.name=t commit -qm init
  done
  python3 - "$root" "$P4_DIGEST" <<'PY'
import sys, pathlib, yaml
root, digest = pathlib.Path(sys.argv[1]), sys.argv[2]
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5,
                 "timeout_seconds": 60, "runtime": "host"},
    "policy": {"quota_floor_percent": 30, "community_share": 0.20,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {
        "tier1": {"tools": "Read,Edit,Bash", "permission_mode": "acceptEdits",
                  "writes_code": True, "network": "proxied"},
        "tier2": {"tools": "Read,Grep,Glob", "permission_mode": "dontAsk",
                  "writes_code": False, "network": "proxied"},
        "tier2-web": {"tools": "Read,Grep,Glob,WebSearch,WebFetch", "permission_mode": "dontAsk",
                      "writes_code": False, "runtime": "host"},
        "tier2-scout": {"tools": "Read,Grep,Glob,Bash", "permission_mode": "dontAsk",
                        "writes_code": False, "network": "proxied"},
        "tier3": {"tools": "Read,Edit,Bash", "permission_mode": "acceptEdits",
                  "writes_code": True, "network": "proxied"},
        "tier3-review": {"tools": "Read,Grep,Glob,Bash", "permission_mode": "dontAsk",
                         "allowed_tools": "Bash(git diff:*) Bash(git log:*) Bash(git show:*)",
                         "writes_code": False, "network": "proxied"},
    },
    "tasks": {
        "audit-security": {"tier": "tier2", "template": "tasks/audit-security.md", "slots": ["daily"]},
        "market-comparison": {"tier": "tier2-web", "template": "tasks/market-comparison.md",
                              "slots": ["weekly"]},
        "draft-ticket": {"tier": "tier3", "template": "tasks/draft-ticket.md",
                         "slots": ["weekly"], "requires_specced_ticket": True},
        "scout": {"tier": "tier2-scout", "template": "tasks/scout.md", "slots": ["weekly"]},
        "draft": {"tier": "tier3", "template": "tasks/draft.md",
                  "slots": ["weekly"], "requires_specced_ticket": True},
    },
    "repos": [{
        "name": "netlens", "path": str(root / "git-netlens"), "spec": "fixture netlens",
        "runtime": "container",
        "image": {"tag": "agent-netlens:g3f9a1c2", "digest": digest},
        "push": True, "repo": "owner/netlens", "auto_merge": False,
        "allowed_tools": "Bash(./gradlew test:*)",
        "tasks": ["audit-security", "market-comparison", "draft-ticket"],
        "tickets": [{"id": "NL-14", "title": "wakelock", "specced": True, "engine": "codex"},
                    {"id": "NL-15", "title": "default engine", "specced": True}],
    }],
    "community": [{
        "name": "upstream", "repo": "owner/upstream", "path": str(root / "git-upstream"),
        "spec": "fixture upstream", "etiquette": "etiquette/upstream.yaml",
        "tasks": ["scout", "draft"],
        "tickets": [{"id": "77", "title": "cleared", "specced": True}],
    }],
}, open(root / "repos.yaml", "w"), sort_keys=False)
PY
}

# A manifest edit that must be rejected: apply it, validate, read the message.
p4_reject() { # label root code expected-message
  local root="$2"
  yaml_edit "$root/repos.yaml" "$root/bad.yaml" "$3"
  has "$1" "$(validate "$root/bad.yaml" "$root")" "$4"
}

test_p4_example_validates() {
  local root="$FIXTURE/p4-example"; p4_fixture "$root"
  is  "prp-004: the §4.1 example validates"          "$(validate "$root/repos.yaml" "$root")" "ok: $root/repos.yaml"
  has "prp-004: repos.yaml ships tier3-review"       "$(python3 -c "import yaml; print(yaml.safe_load(open('$REPO/repos.yaml'))['tiers']['tier3-review'])")" "'network': 'proxied'"
  has "prp-004: ...that never edits"                 "$(python3 -c "import yaml; print(yaml.safe_load(open('$REPO/repos.yaml'))['tiers']['tier3-review'])")" "'writes_code': False"
  is  "prp-004: repos.yaml defaults to the host"     "$(python3 -c "import yaml; print(yaml.safe_load(open('$REPO/repos.yaml'))['defaults']['runtime'])")" "host"
  is  "prp-004: repos.yaml's web tier is host-only"  "$(python3 -c "import yaml; print(yaml.safe_load(open('$REPO/repos.yaml'))['tiers']['tier2-web']['runtime'])")" "host"
  p4_reject "prp-004: defaults.runtime is host or container" "$root" \
    'd["defaults"]["runtime"] = "vm"' "defaults.runtime: must be 'host' or 'container'"
  p4_reject "prp-004: a repo runtime is host or container"   "$root" \
    'd["repos"][0]["runtime"] = "vm"' "repos.netlens.runtime: must be 'host' or 'container'"

  # The entry carries what run.sh will need, resolved, and is not a stage.
  local entry
  entry="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" daily | jq -c 'select(.repo=="netlens")')"
  is "entry: runtime resolved"        "$(jq -r '.runtime' <<< "$entry")"      "container"
  is "entry: image tag carried"       "$(jq -r '.image.tag' <<< "$entry")"    "agent-netlens:g3f9a1c2"
  is "entry: image digest carried"    "$(jq -r '.image.digest' <<< "$entry")" "$P4_DIGEST"
  is "entry: network from the tier"   "$(jq -r '.network' <<< "$entry")"      "proxied"
  is "entry: push carried"            "$(jq -r '.push' <<< "$entry")"         "true"
  is "entry: repo reaches upstream"   "$(jq -r '.upstream' <<< "$entry")"     "owner/netlens"
  is "entry: a build is not a stage"  "$(jq -r '.stage_entry' <<< "$entry")"  "false"
}

# Rule 1: image.tag + image.digest when the resolved runtime is container.
test_p4_rule1_image_required() {
  local root="$FIXTURE/p4-rule1"; p4_fixture "$root"
  p4_reject "rule 1: no image: block at all"     "$root" 'del d["repos"][0]["image"]' \
    "repos.netlens.image: tag and digest are required when runtime is container"
  p4_reject "rule 1: digest missing"             "$root" 'del d["repos"][0]["image"]["digest"]' \
    "repos.netlens.image.digest: required when runtime is container"
  p4_reject "rule 1: tag missing"                "$root" 'del d["repos"][0]["image"]["tag"]' \
    "repos.netlens.image.tag: required when runtime is container"
  p4_reject "rule 1: digest must be sha256:<64 hex>" "$root" 'd["repos"][0]["image"]["digest"] = "sha256:abc"' \
    "repos.netlens.image.digest: must match ^sha256:[0-9a-f]{64}$"
  p4_reject "rule 1: the default runtime reaches a repo with no image" "$root" \
    'd["defaults"]["runtime"] = "container"; d["community"][0]["etiquette"] = "etiquette/upstream.yaml"' \
    "community.upstream.image: tag and digest are required when runtime is container"
  p4_reject "rule 1: image is not a defaults key" "$root" 'd["defaults"]["image"] = {"tag": "agent-base:g1"}' \
    "defaults.image: set per repo, not in defaults"
  # Not a default: a host repo needs no image, and one it does not need is not an error.
  yaml_edit "$root/repos.yaml" "$root/host.yaml" 'd["repos"][0]["runtime"] = "host"; del d["repos"][0]["image"]'
  has "rule 1: a host repo needs no image"     "$(validate "$root/host.yaml" "$root")" "ok:"
}

# Rule 2: network is a tier key only; a host tier beats a container repo.
test_p4_rule2_network_tier_only() {
  local root="$FIXTURE/p4-rule2"; p4_fixture "$root"
  p4_reject "rule 2: network on a repo"    "$root" 'd["repos"][0]["network"] = "none"' \
    "repos.netlens.network: network is a tier key only"
  p4_reject "rule 2: network on a task"    "$root" 'd["tasks"]["audit-security"]["network"] = "none"' \
    "tasks.audit-security.network: network is a tier key only"
  p4_reject "rule 2: network on a ticket"  "$root" 'd["repos"][0]["tickets"][0]["network"] = "none"' \
    "repos.netlens.tickets[NL-14].network: network is a tier key only"
  p4_reject "rule 2: a tier must say none or proxied" "$root" 'd["tiers"]["tier2"]["network"] = "open"' \
    "tiers.tier2.network: must be 'none' or 'proxied'"
  p4_reject "rule 2: a tier cannot omit it" "$root" 'del d["tiers"]["tier2"]["network"]' \
    "tiers.tier2.network: required (none or proxied) unless the tier is runtime: host"
  p4_reject "rule 2: a host tier has the host's network" "$root" 'd["tiers"]["tier2-web"]["network"] = "proxied"' \
    "tiers.tier2-web.network: meaningless on a runtime: host tier"
  p4_reject "rule 2: network on defaults"  "$root" 'd["defaults"]["network"] = "none"' \
    "defaults.network: set per tier, not in defaults"
  p4_reject "rule 2: a tier can only force host"  "$root" 'd["tiers"]["tier2"]["runtime"] = "container"' \
    "tiers.tier2.runtime: only 'host' may be set on a tier"
  local web
  web="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -c 'select(.task=="market-comparison")')"
  is "rule 2: tier runtime: host beats the repo's container" "$(jq -r '.runtime' <<< "$web")" "host"
  is "rule 2: ...and carries no network"                     "$(jq -r '.network' <<< "$web")" ""
}

# Rule 3: push only under repos:.
test_p4_rule3_push_repos_only() {
  local root="$FIXTURE/p4-rule3"; p4_fixture "$root"
  p4_reject "rule 3: push on a community project" "$root" 'd["community"][0]["push"] = True' \
    "community.upstream.push: only repos: entries may push"
  p4_reject "rule 3: push is a boolean"           "$root" 'd["repos"][0]["push"] = "yes"' \
    "repos.netlens.push: must be true or false"
  p4_reject "rule 3: push is not a defaults key"  "$root" 'd["defaults"]["push"] = True' \
    "defaults.push: set per repo, not in defaults"
  yaml_edit "$root/repos.yaml" "$root/off.yaml" 'd["community"][0]["push"] = False'
  has "rule 3: push: false on community is harmless" "$(validate "$root/off.yaml" "$root")" "ok:"
}

# Rule 4: auto_merge: true is refused.
test_p4_rule4_auto_merge() {
  local root="$FIXTURE/p4-rule4"; p4_fixture "$root"
  p4_reject "rule 4: auto_merge: true" "$root" 'd["repos"][0]["auto_merge"] = True' \
    "repos.netlens.auto_merge: true is not supported"
  p4_reject "rule 4: auto_merge is a boolean" "$root" 'd["repos"][0]["auto_merge"] = "never"' \
    "repos.netlens.auto_merge: must be true or false"
  yaml_edit "$root/repos.yaml" "$root/absent.yaml" 'del d["repos"][0]["auto_merge"]'
  has "rule 4: absent is fine" "$(validate "$root/absent.yaml" "$root")" "ok:"
}

# Rule 5: --runtime container on a repo with no image: fails closed at run
# time, with rule 1's message, before any engine is invoked.
test_p4_rule5_cli_runtime_fails_closed() {
  local root="$FIXTURE/p4-rule5"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  mkdir -p "$root/stub"
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
echo invoked >> "$(dirname "$0")/invocations"
jq -n '{is_error:false,result:"## Summary\nstub ran",total_cost_usd:0.01,num_turns:1}'
STUB
  # A podman that EXISTS and holds no such image. Without this the fixture
  # inherits the machine's: where podman is absent entirely the boundary
  # refuses for a different, equally correct reason, and these assertions
  # would be about what is installed rather than about the boundary.
  printf '#!/usr/bin/env bash\necho "Error: no such image" >&2\nexit 125\n' > "$root/stub/podman"
  chmod +x "$root/stub/claude" "$root/stub/podman"
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" 'd["repos"][0]["runtime"] = "host"; del d["repos"][0]["image"]'
  local out
  local run; run() { PATH="$root/stub:$PATH" MEUTE_PODMAN="$root/stub/podman" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" "$@" 2>&1; }
  out="$(run daily --repo netlens --runtime container)"
  has   "rule 5: refused with rule 1's message" "$out" "repos.netlens.image: tag and digest are required when runtime is container"
  has   "rule 5: ...as an error line"           "$out" "status=error"
  [[ -f "$root/stub/invocations" ]] && bad "rule 5: no engine ran" "the stub was invoked" || ok "rule 5: no engine ran"
  out="$(run daily --runtime vm || true)"
  has   "rule 5: --runtime takes host or container" "$out" "unknown runtime"
  # A repo that opted into containers has nothing to run in before Phase 2;
  # the host must not quietly stand in for the isolation it asked for.
  p4_fixture "$root"
  # The fixture pins an image this host does not have, so the boundary now
  # refuses it in eligible() -- earlier than Phase 1's abort, and without a
  # state/log line, because an entry that was never selected did not run.
  out="$(run daily --repo netlens)"
  has   "runtime: a container repo with an unverifiable pin is refused" "$out" "is not present on this host"
  # Forced, so the refusal is logged rather than stepped over silently --
  # but with the boundary's reason, not the credential abort's: the entry
  # never got far enough to be refused for having no credentials.
  has   "runtime: ...and logged with the boundary's own reason"          "$out" "status=error"
  hasnt "runtime: ...not the credential abort's"                        "$out" "needs the credential volumes"
  [[ -f "$root/stub/invocations" ]] && bad "runtime: ...and no engine ran" "the stub was invoked" || ok "runtime: ...and no engine ran"
  # Nor may the CLI talk it down: a repo that opted into isolation runs
  # isolated or not at all. --runtime never changes what runs in Phase 1.
  : > "$root/state/cursor"
  out="$(run daily --repo netlens --runtime host)"
  has   "runtime: --runtime host on a container repo is refused" "$out" "detail=repo opted into isolation; --runtime host is not a downgrade path before Phase 2"
  has   "runtime: ...as an error line"                            "$out" "status=error"
  [[ -f "$root/stub/invocations" ]] && bad "runtime: ...and no engine ran either" "the stub was invoked" || ok "runtime: ...and no engine ran either"
  is    "runtime: ...no worktree was cut"                         "$(ls "$root/.worktrees" 2>/dev/null | wc -l)" "0"
  # A flag the operator can simply drop: logged, and left where it was.
  is    "runtime: ...and stays retryable"                         "$(kv_get_test "$root/state/cursor" cursor.daily)" ""
  # --runtime host is accepted only where it changes nothing. The one case a
  # fixture cannot reach -- an entry with no runtime at all -- is pinned by
  # reading the guard, since manifest.py always emits one.
  yaml_edit "$root/repos.yaml" "$root/hostrepo.yaml" 'd["repos"][0]["runtime"] = "host"; del d["repos"][0]["image"]'
  out="$(MEUTE_MANIFEST="$root/hostrepo.yaml" run daily --repo netlens --runtime host)"
  has   "runtime: --runtime host on a host repo runs as before" "$out" "status=ok"
  is    "runtime: the guard accepts host only against a manifest runtime of exactly host" \
        "$(grep -c '\[\[ "$RUNTIME_OVERRIDE" != "host" || "$manifest_runtime" == "host" \]\]' "$REPO/bin/run.sh")" "1"
  # A dry run records the same refusal: the entry is unrunnable whether or
  # not this fire would have invoked anything.
  : > "$root/state/cursor"
  out="$(run daily --repo netlens --dry-run)"
  has   "runtime: --dry-run is refused at the same boundary" "$out" "is not present on this host"
  hasnt "runtime: ...without inventing a run"                "$out" "would run:"

  # Every precondition a forced run can hit leaves the entry where it was.
  # The operator fixes the flag, the pin or the credential and re-runs; the
  # cursor is rotation state and they did not ask to rotate.
  p4_fixture "$root"
  printf '#!/usr/bin/env bash\necho "Error: no such image" >&2\nexit 125\n' > "$root/stub/podman"
  chmod +x "$root/stub/podman"
  : > "$root/state/cursor"
  out="$(run daily --repo netlens --runtime host)"
  has "precondition: the downgrade refusal is logged"   "$out" "is not a downgrade path"
  is  "precondition: ...and stays retryable"            "$(kv_get_test "$root/state/cursor" cursor.daily)" ""
  yaml_edit "$root/repos.yaml" "$root/nopin.yaml" 'd["repos"][0]["runtime"] = "host"; del d["repos"][0]["image"]'
  out="$(MEUTE_MANIFEST="$root/nopin.yaml" run daily --repo netlens --runtime container)"
  has "precondition: rule 5 is logged"                  "$out" "tag and digest are required when runtime is container"
  is  "precondition: ...and stays retryable too"        "$(kv_get_test "$root/state/cursor" cursor.daily)" ""
  # The credential abort that used to sit here is gone: Phase 2b dispatches a
  # verified entry into the container rather than refusing it, and the last
  # precondition before an engine runs is now the in-container preflight,
  # asserted in test_p2b_preflight. Unforced, the rotation still advances: an
  # entry it cannot run must not stall every repo behind it (PRP-001 §10).
  out="$(MEUTE_MANIFEST="$root/nopin.yaml" run daily --runtime container)"
  has "precondition: unforced, the same refusal is logged" "$out" "tag and digest are required when runtime is container"
  is  "precondition: ...and the rotation moves on"      "$(kv_get_test "$root/state/cursor" cursor.daily)" "netlens/audit-security"
}

# Rule 6: the build engine is per ticket; the review engine is derived.
test_p4_rule6_ticket_engine() {
  local root="$FIXTURE/p4-rule6"; p4_fixture "$root"
  local q
  q="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly)"
  is "rule 6: ticket engine wins"            "$(jq -r 'select(.ticket_id=="NL-14") | .engine' <<< "$q")" "codex"
  is "rule 6: no ticket engine, repo/defaults" "$(jq -r 'select(.ticket_id=="NL-15") | .engine' <<< "$q")" "claude"
  p4_reject "rule 6: review_engine is not a field" "$root" 'd["repos"][0]["tickets"][0]["review_engine"] = "claude"' \
    "repos.netlens.tickets[NL-14].review_engine: not a field - the review engine is derived from engine"
  p4_reject "rule 6: a ticket engine is claude or codex" "$root" 'd["repos"][0]["tickets"][0]["engine"] = "gpt"' \
    "repos.netlens.tickets[NL-14].engine: must be 'claude' or 'codex'"
  # PRP-001 s10: the machine-written source is not a way around the schema.
  python3 - "$root" <<'PYT'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({"tickets": {"netlens": [{"id": "NL-90", "title": "m", "specced": True, "engine": "gpt"}]}},
               open(root / "state" / "tickets.yaml", "w"))
PYT
  has "rule 6: a machine ticket's engine is gated too" "$(validate "$root/repos.yaml" "$root")" \
      "state/tickets.yaml[netlens][NL-90].engine: must be 'claude' or 'codex'"
  python3 - "$root" <<'PYT'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({"tickets": {"netlens": [{"id": "NL-90", "title": "m", "specced": True, "review_engine": "claude"}]}},
               open(root / "state" / "tickets.yaml", "w"))
PYT
  has "rule 6: ...and review_engine is refused there too" "$(validate "$root/repos.yaml" "$root")" \
      "state/tickets.yaml[netlens][NL-90].review_engine: not a field"
  rm -f "$root/state/tickets.yaml"
  # The writer refuses what the reader would: a promoted ticket must never
  # leave state/tickets.yaml failing validation on every slot until a human
  # edits it by hand.
  local rc
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" add-ticket "$root/repos.yaml" netlens '{"title":"bad engine","engine":"gpt"}' 2>&1)"; rc=$?
  is  "rule 6: add-ticket refuses an unknown engine"   "$rc" "2"
  has "rule 6: ...naming the field"                    "$out" "add-ticket[netlens][NE-16].engine: must be 'claude' or 'codex'"
  [[ -e "$root/state/tickets.yaml" ]] && bad "rule 6: ...and writes nothing" "state/tickets.yaml was created" || ok "rule 6: ...and writes nothing"
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" add-ticket "$root/repos.yaml" netlens '{"title":"x","review_engine":"claude"}' 2>&1)"; rc=$?
  is  "rule 6: add-ticket refuses review_engine"       "$rc" "2"
  has "rule 6: ...naming that field too"               "$out" "add-ticket[netlens][NE-16].review_engine: not a field"
  [[ -e "$root/state/tickets.yaml" ]] && bad "rule 6: ...and still writes nothing" "state/tickets.yaml was created" || ok "rule 6: ...and still writes nothing"
}

# Rule 7: a state/stages row turns the ticket's build entry into its next
# stage entry, ahead of the repo's other work; done or absent -> build entry.
test_p4_rule7_stage_entries() {
  local root="$FIXTURE/p4-rule7"; p4_fixture "$root"
  local q
  printf 'netlens/NL-14\treview\tmeute/draft-ticket-2026-09-01\tabc123\treports/netlens/draft-ticket-2026-09-01.md\tcodex\n' > "$root/state/stages"
  q="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly)"
  local stage; stage="$(jq -c 'select(.ticket_id=="NL-14")' <<< "$q")"
  is "rule 7: a review row yields one entry for the ticket" "$(wc -l <<< "$stage")" "1"
  is "rule 7: it is a stage entry"        "$(jq -r '.stage_entry' <<< "$stage")"   "true"
  is "rule 7: stage"                      "$(jq -r '.stage' <<< "$stage")"         "review"
  is "rule 7: branch"                     "$(jq -r '.branch' <<< "$stage")"        "meute/draft-ticket-2026-09-01"
  is "rule 7: base"                       "$(jq -r '.base' <<< "$stage")"          "abc123"
  is "rule 7: build_report"               "$(jq -r '.build_report' <<< "$stage")"  "reports/netlens/draft-ticket-2026-09-01.md"
  is "rule 7: key carries the stage"      "$(jq -r '.key' <<< "$stage")"           "netlens/draft-ticket/NL-14/review"
  is "rule 7: review runs on tier3-review" "$(jq -r '.tier' <<< "$stage")"         "tier3-review"
  is "rule 7: review engine is the other one" "$(jq -r '.engine' <<< "$stage")"    "claude"
  # run.sh dispatches on these fields, not on the tier's name: a review that
  # kept the build tier's profile could edit and run gradle.
  is "rule 7: review tools are tier3-review's"      "$(jq -r '.tools' <<< "$stage")"           "Read,Grep,Glob,Bash"
  is "rule 7: review permission mode too"           "$(jq -r '.permission_mode' <<< "$stage")" "dontAsk"
  is "rule 7: a review never writes code"           "$(jq -r '.writes_code' <<< "$stage")"     "false"
  is "rule 7: review network is the tier's"         "$(jq -r '.network' <<< "$stage")"         "proxied"
  is "rule 7: review allowlist is the tier's alone" "$(jq -r '.allowed_tools' <<< "$stage")"   "Bash(git diff:*) Bash(git log:*) Bash(git show:*)"
  hasnt "rule 7: the build allowlist does not leak into the review" "$(jq -r '.allowed_tools' <<< "$stage")" "gradlew"
  is "rule 7: the stage entry leads its repo" "$(jq -r '.key' <<< "$q" | head -1)" "netlens/draft-ticket/NL-14/review"
  is "rule 7: the other ticket still builds" "$(jq -r 'select(.ticket_id=="NL-15") | .stage_entry' <<< "$q")" "false"

  printf 'netlens/NL-14\tresolve\tmeute/x\tabc123\treports/x.md\tcodex\n' > "$root/state/stages"
  q="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -c 'select(.ticket_id=="NL-14")')"
  is "rule 7: resolve runs on tier3"        "$(jq -r '.tier' <<< "$q")"   "tier3"
  is "rule 7: resolve uses the build engine" "$(jq -r '.engine' <<< "$q")" "codex"
  is "rule 7: resolve has tier3's tools"    "$(jq -r '.tools' <<< "$q")"  "Read,Edit,Bash"
  is "rule 7: resolve writes code"          "$(jq -r '.writes_code' <<< "$q")" "true"
  has "rule 7: resolve keeps the build allowlist" "$(jq -r '.allowed_tools' <<< "$q")" "gradlew"
  printf 'netlens/NL-14\treview-2\tmeute/x\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  q="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -c 'select(.ticket_id=="NL-14")')"
  is "rule 7: review-2 flips the engine too" "$(jq -r '.engine' <<< "$q")" "codex"
  printf 'netlens/NL-14\tpublish\tmeute/x\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  q="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -c 'select(.ticket_id=="NL-14")')"
  is "rule 7: publish has no engine"        "$(jq -r '.engine' <<< "$q")" ""
  is "rule 7: publish keeps the task's tier" "$(jq -r '.tier' <<< "$q")"  "tier3"
  is "rule 7: publish has no tools"         "$(jq -r '.tools' <<< "$q")"  ""
  is "rule 7: publish never writes code"    "$(jq -r '.writes_code' <<< "$q")" "false"
  # PRP-004 s4.4 pins publish to proxied: git push and gh need the egress
  # proxy whatever the build tier was allowed.
  yaml_edit "$root/repos.yaml" "$root/nonet.yaml" 'd["tiers"]["tier3"]["network"] = "none"'
  q="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/nonet.yaml" weekly | jq -c 'select(.ticket_id=="NL-14")')"
  is "rule 7: publish is proxied even under a network: none build tier" "$(jq -r '.network' <<< "$q")" "proxied"

  printf 'netlens/NL-14\tdone\tmeute/x\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  q="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -c 'select(.ticket_id=="NL-14")')"
  is "rule 7: a done row yields the build entry" "$(jq -r '.stage_entry' <<< "$q")" "false"
  is "rule 7: ...with the build key"             "$(jq -r '.key' <<< "$q")"         "netlens/draft-ticket/NL-14"
  rm -f "$root/state/stages"
  q="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly | jq -c 'select(.ticket_id=="NL-14")')"
  is "rule 7: no file, build entry"              "$(jq -r '.stage_entry' <<< "$q")" "false"

  # A row the builder cannot read must stop the queue, not invent a stage.
  printf 'netlens/NL-14\tshipping\tmeute/x\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  has "rule 7: an unknown stage is refused" "$(validate "$root/repos.yaml" "$root")" "state/stages: netlens/NL-14: unknown stage 'shipping'"
  printf 'netlens/NL-14\treview\tmeute/x\n' > "$root/state/stages"
  has "rule 7: a short row is refused"      "$(validate "$root/repos.yaml" "$root")" "state/stages: netlens/NL-14: expected stage, branch, base, build_report, engine"
  printf 'netlens/NL-14\treview\tmeute/x\tabc123\treports/x.md\tgpt\n' > "$root/state/stages"
  has "rule 7: an unknown build engine is refused" "$(validate "$root/repos.yaml" "$root")" "state/stages: netlens/NL-14: engine must be claude or codex"
  printf 'netlens/NL-14\treview\tmeute/x\t\treports/x.md\tclaude\n' > "$root/state/stages"
  has "rule 7: an empty column is refused"         "$(validate "$root/repos.yaml" "$root")" "state/stages: netlens/NL-14: base is empty"
  printf 'netlens/NL-14\treview\tmeute/x\tabc123\treports/x.md\tclaude\nnetlens/NL-14\tresolve\tmeute/x\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  has "rule 7: a duplicate key is refused"         "$(validate "$root/repos.yaml" "$root")" "state/stages: netlens/NL-14: duplicate row"
  # A review row needs the tier it runs on; without one the entry would have
  # no profile at all, which is not a safer profile.
  printf 'netlens/NL-14\treview\tmeute/x\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  yaml_edit "$root/repos.yaml" "$root/notier.yaml" 'del d["tiers"]["tier3-review"]'
  has "rule 7: a review row without tier3-review is refused" "$(validate "$root/notier.yaml" "$root")" \
      "tiers.tier3-review: required -- state/stages has a review row for netlens/NL-14"
  # A row nothing will run -- its ticket gone, or present but not specced, or
  # in a repo with no ticket-consuming task -- is a warning, not a wedge: the
  # queue still builds, and validate says so. queue itself stays silent: it
  # runs three times a fire and promote parses its output with stderr merged.
  printf 'netlens/NL-99\treview\tmeute/x\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  has "rule 7: a row for a vanished ticket is reported by validate" "$(validate "$root/repos.yaml" "$root")" \
      "state/stages: 1 row(s) that no task consumes: netlens/NL-99"
  local err; err="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly 2>&1 >/dev/null)"
  is  "rule 7: ...queue says nothing about it"      "$err" ""
  is  "rule 7: ...and the queue still builds"       "$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" queue "$root/repos.yaml" weekly 2>/dev/null | jq -r 'select(.ticket_id=="NL-14") | .stage_entry')" "false"
  yaml_edit "$root/repos.yaml" "$root/unspecced.yaml" 'd["repos"][0]["tickets"][0]["specced"] = False'
  printf 'netlens/NL-14\treview\tmeute/x\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  has "rule 7: a row for an unspecced ticket is reported too" "$(validate "$root/unspecced.yaml" "$root")" \
      "state/stages: 1 row(s) that no task consumes: netlens/NL-14"
  has "rule 7: ...while the consumed one is not"    "$(validate "$root/repos.yaml" "$root")" "ok:"
  printf 'netlens/NL-14\tdone\tmeute/x\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  has "rule 7: a done row is finished, not unconsumed" "$(validate "$root/unspecced.yaml" "$root")" "ok:"
  is  "rule 7: list-stages flags the same rows"      "$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" list-stages "$root/unspecced.yaml" | jq -r '.unconsumed')" "false"
  printf 'netlens/NL-14\treview\tmeute/x\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  is  "rule 7: ...and the unspecced one as unconsumed" "$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" list-stages "$root/unspecced.yaml" | jq -r '.unconsumed')" "true"
  rm -f "$root/state/stages"
}

# Rule 8: the tag is Atelier's immutable one for this repo, or the base image.
test_p4_rule8_tag_format() {
  local root="$FIXTURE/p4-rule8"; p4_fixture "$root"
  p4_reject "rule 8: a registry-style tag"      "$root" 'd["repos"][0]["image"]["tag"] = "localhost/agent-netlens:latest"' \
    "repos.netlens.image.tag: 'localhost/agent-netlens:latest' must be agent-netlens:g<hex> or agent-base:g<hex>"
  p4_reject "rule 8: another project's overlay" "$root" 'd["repos"][0]["image"]["tag"] = "agent-other:g3f9a1c2"' \
    "repos.netlens.image.tag: 'agent-other:g3f9a1c2' must be agent-netlens:g<hex> or agent-base:g<hex>"
  p4_reject "rule 8: a mutable tag"             "$root" 'd["repos"][0]["image"]["tag"] = "agent-netlens:latest"' \
    "repos.netlens.image.tag: 'agent-netlens:latest' must be agent-netlens:g<hex> or agent-base:g<hex>"
  yaml_edit "$root/repos.yaml" "$root/base.yaml" 'd["repos"][0]["image"]["tag"] = "agent-base:g0badf00d"'
  has "rule 8: the base image is accepted" "$(validate "$root/base.yaml" "$root")" "ok:"
}

# Rule 9: push needs the owner's repo, owner/name, and nothing derives it.
test_p4_rule9_push_needs_repo() {
  local root="$FIXTURE/p4-rule9"; p4_fixture "$root"
  p4_reject "rule 9: push without repo"     "$root" 'del d["repos"][0]["repo"]' \
    "repos.netlens.repo: required (owner/name) when push is true"
  p4_reject "rule 9: repo must be owner/name" "$root" 'd["repos"][0]["repo"] = "https://github.com/owner/netlens"' \
    "repos.netlens.repo: 'https://github.com/owner/netlens' must be owner/name"
  yaml_edit "$root/repos.yaml" "$root/nopush.yaml" 'd["repos"][0]["push"] = False; del d["repos"][0]["repo"]'
  has "rule 9: no push, no repo needed" "$(validate "$root/nopush.yaml" "$root")" "ok:"
}

# Decision 3: a stage entry is exempt from the tier-3 cap -- the cap gates new
# builds, and at cap a resolve must still run on a branch it counts -- and,
# until Phase 4 can run one, is aborted before any engine is invoked.
test_p4_stage_entry_cap_and_abort() {
  local root="$FIXTURE/p4-stage-run"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  mkdir -p "$root/stub"
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
echo invoked >> "$(dirname "$0")/invocations"
jq -n '{is_error:false,result:"## Summary\nstub ran",total_cost_usd:0.01,num_turns:1}'
STUB
  chmod +x "$root/stub/claude"
  # Host runtime, no image: this test is about stages, not containers.
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" \
    'd["repos"][0]["runtime"] = "host"; del d["repos"][0]["image"]; d["repos"][0]["tickets"] = [d["repos"][0]["tickets"][1]]; d["repos"][0]["tasks"] = ["draft-ticket"]; d["community"] = []; d["policy"]["tier3_max_in_flight"] = 1'
  # One draft in flight fills the cap of 1.
  git -C "$root/git-netlens" branch meute/draft-ticket-2026-09-01 >/dev/null 2>&1
  local out
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" weekly --dry-run 2>&1)"
  has "cap: the build entry is held at the cap" "$out" "tier-3 drafts already in flight"

  printf 'netlens/NL-15\tresolve\tmeute/draft-ticket-2026-09-01\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" weekly 2>&1 || true)"
  hasnt "cap: the stage entry passes the cap"        "$out" "already in flight"
  has   "stage: aborted before Phase 4 can run it"   "$out" "detail=stage entries are not runnable before Phase 4"
  has   "stage: ...logged as an error"               "$out" "status=error"
  [[ -f "$root/stub/invocations" ]] && bad "stage: no engine ran" "the stub was invoked" || ok "stage: no engine ran"
  is    "stage: the cursor moved past it"            "$(kv_get_test "$root/state/cursor" cursor.weekly)" "netlens/draft-ticket/NL-15/resolve"
  is    "stage: no worktree was cut"                 "$(ls "$root/.worktrees" 2>/dev/null | wc -l)" "0"
  # A dry run records the same abort and moves on.
  : > "$root/state/cursor"
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" weekly --dry-run 2>&1 || true)"
  has   "stage: --dry-run still logs the abort"      "$out" "status=error"
  is    "stage: ...and still advances the cursor"    "$(kv_get_test "$root/state/cursor" cursor.weekly)" "netlens/draft-ticket/NL-15/resolve"
  # One fire, one line: the runner validates once but builds the queue three
  # times (the slot's, then both slots for the tier-3 scope).
  printf 'netlens/NL-99\treview\tmeute/x\tabc123\treports/x.md\tclaude\n' >> "$root/state/stages"
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" weekly --dry-run 2>&1 || true)"
  is    "stage: an unconsumed row is reported exactly once per fire" "$(grep -c 'that no task consumes' <<< "$out")" "1"
  printf 'netlens/NL-15\tresolve\tmeute/draft-ticket-2026-09-01\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  # publish has no engine, so no pool to probe: it must reach the abort, not
  # stall the slot on a quota reading for an engine called "".
  printf 'netlens/NL-15\tpublish\tmeute/draft-ticket-2026-09-01\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" weekly 2>&1 || true)"
  has   "stage: a publish entry is aborted, not gated on an empty engine" "$out" "detail=stage entries are not runnable before Phase 4"
  is    "stage: ...and the cursor moved past it too" "$(kv_get_test "$root/state/cursor" cursor.weekly)" "netlens/draft-ticket/NL-15/publish"
  # status walks the same queue the runner does; an engine-less stage entry
  # must read as "next", not as a bash error about an empty array key.
  : > "$root/state/cursor"
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/meute" status 2>&1)"
  hasnt "stage: status survives an engine-less stage entry" "$out" "bad array subscript"
  has   "stage: ...and names it as next"                    "$out" "next weekly  netlens/draft-ticket/NL-15/publish"
}
kv_get_test() { awk -F'\t' -v key="$2" '$1 == key { print $2; exit }' "$1"; }

# The four PRP-004 columns, always `-` in this phase, on every line class the
# runner writes: a line differs from one on main only by this suffix.
test_p4_log_columns() {
  local root="$FIXTURE/p4-log"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  mkdir -p "$root/stub"
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
jq -n '{is_error:false,result:"## Summary\nstub ran",total_cost_usd:0.01,num_turns:1}'
STUB
  chmod +x "$root/stub/claude"
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" 'd["repos"][0]["runtime"] = "host"; del d["repos"][0]["image"]'
  # Phase 2b fills runtime= on a line that selected an entry; image= only for
  # a container run, and stage=/pr= wait for Phases 4 and 5.
  local suffix=$'\truntime=host\timage=-\tstage=-\tpr=-'
  local unselected=$'\truntime=-\timage=-\tstage=-\tpr=-'
  local run; run() { PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB="$1" "$root/bin/run.sh" daily "${@:2}" >/dev/null 2>&1 || true; }
  run 100 --repo netlens
  local line; line="$(grep 'status=ok' "$root/state/log" | tail -1)"
  is  "log: an ok line ends with the four columns"  "${line: -${#suffix}}" "$suffix"
  has "log: ...after the last existing column"      "${line%"$suffix"}" $'\tdur='
  hasnt "log: ...and nowhere else"                  "${line%"$suffix"}" "image="
  run 10 --repo netlens
  line="$(grep 'status=skipped' "$root/state/log" | tail -1)"
  # A skip happens before an entry is selected, so there is no runtime to name.
  is  "log: a skipped line carries them too"        "${line: -${#unselected}}" "$unselected"
  printf 'netlens/NL-14\treview\tmeute/x\tabc123\treports/x.md\tcodex\n' > "$root/state/stages"
  PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" weekly >/dev/null 2>&1 || true
  line="$(grep 'status=error' "$root/state/log" | tail -1)"
  is  "log: an error line carries them too"         "${line: -${#unselected}}" "$unselected"
  # Everything that reads the log still counts this week.
  local status_out
  status_out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/meute" status 2>&1)"
  has "log: status still totals the week"           "$status_out" "2 runs"
  is  "log: the inbox still reads it"               "$(MEUTE_ROOT="$root" python3 "$REPO/lib/inbox.py" dump | jq -r '.status.runs')" "2"
}

# meute image bump: the only writer of image.digest, through add-repo's
# validated, backed-up path, and never into repos.yaml.
test_p4_image_bump() {
  local root="$FIXTURE/p4-bump"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  mkdir -p "$root/stub"
  local new="sha256:$(printf 'b%.0s' {1..64})"
  cat > "$root/stub/podman" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$root/stub/podman-calls"
[[ "\$*" == *"agent-netlens:g3f9a1c2"* ]] || { echo "Error: no such image" >&2; exit 125; }
printf '%s %s\n' "$new" "$P2_ID"
STUB
  chmod +x "$root/stub/podman"
  local bump; bump() { MEUTE_PODMAN="$root/stub/podman" "$root/bin/meute" image bump "$@" 2>&1; }

  # repos.yaml is the tracked schema doc: refused before podman is even asked.
  local out before
  before="$(cat "$root/repos.yaml")"
  out="$(bump netlens)"
  has   "image bump: refuses repos.yaml"       "$out" "refusing to write repos.yaml"
  is    "image bump: ...untouched"             "$(cat "$root/repos.yaml")" "$before"
  [[ -e "$root/repos.yaml.bak" ]] && bad "image bump: no .bak of repos.yaml" "repos.yaml.bak exists" || ok "image bump: no .bak of repos.yaml"
  [[ -e "$root/stub/podman-calls" ]] && bad "image bump: podman not consulted for a refused write" "podman was called" || ok "image bump: podman not consulted for a refused write"

  cp "$root/repos.yaml" "$root/repos.local.yaml"
  out="$(bump netlens)"
  has   "image bump: writes repos.local.yaml"  "$out" "netlens: image.digest -> ${new:0:19}"
  is    "image bump: the digest landed"        "$(python3 -c "import yaml; print(yaml.safe_load(open('$root/repos.local.yaml'))['repos'][0]['image']['digest'])")" "$new"
  is    "image bump: ...for the manifest's tag" "$(cat "$root/stub/podman-calls")" "image inspect --format {{.Digest}} {{.Id}} -- agent-netlens:g3f9a1c2"
  [[ -f "$root/repos.local.yaml.bak" ]] && ok "image bump: backs the manifest up first" || bad "image bump: backs the manifest up first" "no .bak"
  is    "image bump: the backup is the old manifest" "$(cat "$root/repos.local.yaml.bak")" "$before"
  has   "image bump: the result validates"     "$(validate "$root/repos.local.yaml" "$root")" "ok:"

  out="$(bump unknown)"
  has   "image bump: unknown repo"             "$out" "unknown repo 'unknown'"
  yaml_edit "$root/repos.local.yaml" "$root/repos.local.yaml" 'd["repos"][0]["runtime"] = "host"; del d["repos"][0]["image"]'
  out="$(bump netlens)"
  has   "image bump: refuses a repo with no image.tag" "$out" "netlens has no image.tag"
  # Digest bumps happen because the manifest fails rule 1 today; the write
  # must validate the manifest as it will be, not as it is.
  yaml_edit "$root/repos.local.yaml" "$root/repos.local.yaml" \
    'd["repos"][0]["runtime"] = "container"; d["repos"][0]["image"] = {"tag": "agent-netlens:g3f9a1c2"}'
  has   "image bump: the manifest is invalid before the bump" "$(validate "$root/repos.local.yaml" "$root")" "image.digest: required"
  out="$(bump netlens)"
  has   "image bump: ...and valid after it"    "$(validate "$root/repos.local.yaml" "$root")" "ok:"

  # The refusal is by identity, not by name: open() follows a symlink, so a
  # link with any other basename would have written the tracked file and
  # left the backup beside the alias. Found by the Codex pass.
  ln -s "$root/repos.yaml" "$root/alias.yaml"
  before="$(cat "$root/repos.yaml")"
  out="$(MEUTE_MANIFEST="$root/alias.yaml" MEUTE_PODMAN="$root/stub/podman" "$root/bin/meute" image bump netlens 2>&1)"; rc=$?
  is    "symlink: image bump refuses an alias of repos.yaml"     "$rc" "1"
  has   "symlink: ...by its identity"                            "$out" "refusing to write repos.yaml"
  has   "symlink: ...and says what the alias resolves to"        "$out" "resolves to $root/repos.yaml"
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" set-image-digest "$root/alias.yaml" netlens "$new" 2>&1)"; rc=$?
  is    "symlink: set-image-digest refuses the alias too"        "$rc" "2"
  has   "symlink: ...naming the real file"                       "$out" "resolves to $root/repos.yaml"
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" add-repo "$root/alias.yaml" \
        "$(printf '{"name":"via-alias","path":"%s","spec":"s"}' "$root/git-upstream")" 2>&1)"; rc=$?
  is    "symlink: add-repo refuses the alias too"                "$rc" "2"
  has   "symlink: ...with the same refusal"                      "$out" "refusing to write repos.yaml"
  out="$(MEUTE_MANIFEST="$root/alias.yaml" "$root/bin/meute" discover "$root" 2>&1)"; rc=$?
  is    "symlink: discover's front door refuses the alias too"   "$rc" "1"
  has   "symlink: ...pointing at repos.local.yaml"               "$out" "no repos.local.yaml found"
  is    "symlink: repos.yaml is untouched"                       "$(cat "$root/repos.yaml")" "$before"
  [[ -e "$root/alias.yaml.bak" ]] && bad "symlink: no backup beside the alias" "alias.yaml.bak exists" || ok "symlink: no backup beside the alias"
  [[ -e "$root/repos.yaml.bak" ]] && bad "symlink: no backup beside repos.yaml either" "repos.yaml.bak exists" || ok "symlink: no backup beside repos.yaml either"
  # A link to repos.local.yaml is fine, and the write lands on the real file,
  # backup beside it -- not beside a link that may be gone tomorrow.
  local new2="sha256:$(printf 'd%.0s' {1..64})"
  sed -i "s/$new/$new2/" "$root/stub/podman"
  ln -s "$root/repos.local.yaml" "$root/local-alias.yaml"
  rm -f "$root/repos.local.yaml.bak"
  out="$(MEUTE_MANIFEST="$root/local-alias.yaml" MEUTE_PODMAN="$root/stub/podman" "$root/bin/meute" image bump netlens 2>&1)"; rc=$?
  is    "symlink: an alias of repos.local.yaml is written through" "$rc" "0"
  has   "symlink: ...and the note names the backup that exists"    "$out" "backup of the previous manifest: repos.local.yaml.bak"
  is    "symlink: ...the real file changed"                        "$(python3 -c "import yaml; print(yaml.safe_load(open('$root/repos.local.yaml'))['repos'][0]['image']['digest'])")" "$new2"
  is    "symlink: ...the backup sits beside the real file"         "$(python3 -c "import yaml; print(yaml.safe_load(open('$root/repos.local.yaml.bak'))['repos'][0]['image']['digest'])")" "$new"
  [[ -e "$root/local-alias.yaml.bak" ]] && bad "symlink: ...not beside the link" "local-alias.yaml.bak exists" || ok "symlink: ...not beside the link"
  [[ -L "$root/local-alias.yaml" ]] && ok "symlink: ...and the link is still a link" || bad "symlink: ...and the link is still a link" "the link was replaced by a file"

  printf '#!/usr/bin/env bash\necho not-a-digest\n' > "$root/stub/podman"
  out="$(bump netlens)"
  has   "image bump: a malformed inspect answer is refused" "$out" "not a sha256 digest"
  out="$(MEUTE_ROOT="$root" python3 "$REPO/lib/manifest.py" set-image-digest "$root/repos.yaml" netlens "$new" 2>&1 || true)"
  has   "set-image-digest: refuses repos.yaml on its own too" "$out" "refusing to write repos.yaml"
}

# doctor: image present at the pinned digest, per container repo, and the
# egress proxy running, fleet-wide -- only when some repo runs in a container.
# The ignore rules cover the manifest by name, and MEUTE_MANIFEST can name
# anything -- with write_with_backup dropping a .bak beside whatever it
# resolves to. Naming patterns cannot cover a name nobody predicted, so
# doctor asks git about the real file. Raised in review of the ignore fix:
# the rule closed the documented path and left the override open.
test_doctor_manifest_ignored() {
  local root="$FIXTURE/doctor-manifest"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  # doctor asks git, so the fixture needs a repo and this harness's own rules.
  # p4_fixture writes repos.yaml; the two copies are the manifest a fleet
  # actually uses and one under a name no ignore rule predicts.
  git -C "$root" init -q
  cp "$REPO/.gitignore" "$root/.gitignore"
  cp "$root/repos.yaml" "$root/repos.local.yaml"
  cp "$root/repos.yaml" "$root/fleet.local.yaml"
  local doc; doc() { "$root/bin/meute" doctor 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g'; }
  local out
  out="$(doc)"
  has "doctor: the documented manifest and its .bak are ignored" \
    "$out" "ok   manifest repos.local.yaml and its .bak are gitignored"
  out="$(MEUTE_MANIFEST="$root/fleet.local.yaml" doc)"
  has "doctor: a manifest the rules do not cover is a FAIL" \
    "$out" "FAIL manifest fleet.local.yaml or fleet.local.yaml.bak is not gitignored"
  out="$(MEUTE_MANIFEST="$root/repos.yaml" doc)"
  has "doctor: the tracked schema doc is not mistaken for a leak" \
    "$out" "ok   manifest is repos.yaml, the tracked schema doc"
  cp "$root/repos.local.yaml" "$FIXTURE/outside.yaml"
  out="$(MEUTE_MANIFEST="$FIXTURE/outside.yaml" doc)"
  has "doctor: a manifest outside the harness cannot be published by it" \
    "$out" "ok   manifest lives outside the harness"
}

test_p4_doctor_containers() {
  local root="$FIXTURE/p4-doctor"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  mkdir -p "$root/stub"
  cat > "$root/stub/podman" <<STUB
#!/usr/bin/env bash
case "\$*" in
  "image inspect --format {{.Digest}} {{.Id}} -- agent-netlens:g3f9a1c2") printf '%s %s\n' "\${STUB_DIGEST:-$P4_DIGEST}" "$P2_ID" ;;
  "container inspect --format {{.State.Running}} -- atelier-egress") printf '%s\n' "\${STUB_EGRESS:-true}" ;;
  "inspect atelier-egress --format "*) printf '%s\n' "\${STUB_IP-10.89.14.10}" ;;
  *) echo "Error: no such object" >&2; exit 125 ;;
esac
STUB
  chmod +x "$root/stub/podman"
  # Colour stripped so the label and its message can be matched as one string.
  local doc; doc() { PATH="$root/stub:$PATH" MEUTE_PODMAN="$root/stub/podman" "$root/bin/meute" doctor 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g'; }
  local out
  out="$(doc)"
  has "doctor: image at the pinned digest"        "$out" "ok   image agent-netlens:g3f9a1c2 present at pinned digest"
  has "doctor: egress proxy running"              "$out" "ok   atelier-egress running at 10.89.14.10"
  has "doctor: an unreadable proxy address is a FAIL" "$(STUB_IP= doc)" "FAIL atelier-egress has no address on atelier-internal"
  out="$(STUB_DIGEST="sha256:$(printf 'c%.0s' {1..64})" doc)"
  has "doctor: digest drift is a FAIL"            "$out" "FAIL image agent-netlens:g3f9a1c2 is not at the pinned digest"
  has "doctor: ...and says how to re-pin"         "$out" "meute image bump netlens"
  out="$(STUB_EGRESS=false doc)"
  has "doctor: a stopped proxy is a FAIL"         "$out" "FAIL atelier-egress is not running"
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" 'd["repos"][0]["image"]["tag"] = "agent-netlens:gdeadbeef"'
  out="$(doc)"
  has "doctor: an absent image is a FAIL"         "$out" "FAIL image agent-netlens:gdeadbeef not present"
  # A row for a ticket the manifest no longer has is reported here, where the
  # owner looks; the runner only mutters it on stderr under the timer.
  printf 'netlens/NL-99\treview\tmeute/x\tabc123\treports/x.md\tclaude\n' > "$root/state/stages"
  out="$(doc)"
  has "doctor: unconsumed stage rows are a warning" "$out" "warn state/stages: 1 row(s) that no task consumes: netlens/NL-99"
  rm -f "$root/state/stages"
  # No podman is a different failure from no image, and says which knob to turn.
  out="$(PATH="$root/stub:$PATH" MEUTE_PODMAN="$root/stub/no-such-podman" "$root/bin/meute" doctor 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
  has "doctor: a missing podman is named as such" "$out" "FAIL podman not found (MEUTE_PODMAN=$root/stub/no-such-podman)"
  hasnt "doctor: ...not mistaken for a missing image" "$out" "not present"
  # A tag with no digest yet is the bump the owner has not run.
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" 'd["repos"][0]["image"] = {"tag": "agent-netlens:g3f9a1c2"}'
  out="$(doc)"
  has "doctor: an unpinned digest says so"        "$out" "FAIL image agent-netlens:g3f9a1c2: no digest pinned yet -- meute image bump netlens"
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" 'd["repos"][0]["runtime"] = "host"; del d["repos"][0]["image"]'
  out="$(doc)"
  hasnt "doctor: no container repo, no image check" "$out" "pinned digest"
  hasnt "doctor: ...and no proxy check"             "$out" "atelier-egress"
}


# ------------------------------------------------- PRP-004 phase 2a --------
# The isolation boundary. These run the REAL Atelier base image where one is
# present, because a stub cannot answer the only questions that matter here:
# what uid the process has, which capabilities it kept, what the filesystem
# looks like from inside. Where it is absent (CI), each such test skips with
# the reason -- a skipped isolation proof is visible; a faked one is not.
readonly P2_IMAGE="agent-base:g691e067"
readonly P2_DIGEST="sha256:9ac5558d3ffd9acb1d76948a8f4d99f6bcbb19fccfb95fb6295616dc0f1c999d"
# The immutable ID the digest assert resolves to. A tag is a moving name; this
# is what podman is actually given, so a re-tag between the two cannot swap it.
readonly P2_ID="2e1dd114a47a8b0add24769829a16e88363f490c719238829eb007ae008e27f8"

# The podman this host reaches, resolved the way lib/container.sh resolves it.
p2_podman() {
  if [[ -n "${MEUTE_PODMAN:-}" ]]; then printf '%s\n' "$MEUTE_PODMAN"
  elif [[ -e /run/.containerenv ]]; then printf 'distrobox-host-exec podman\n'
  else printf 'podman\n'; fi
}

# Is the real image here, at the digest these tests pin? Everything that runs
# a container asks first.
p2_image_present() {
  local -a podman; read -ra podman <<< "$(p2_podman)"
  [[ "$(timeout 20 "${podman[@]}" image inspect --format '{{.Digest}}' -- "$P2_IMAGE" 2>/dev/null)" == "$P2_DIGEST" ]]
}

# A git repo with a `secret` branch whose blob is reachable from nowhere else.
# Prints the blob's sha so the clone can be asked whether it has it.
p2_source_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  echo public > "$repo/f.txt"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$repo" checkout -q -b secret
  echo 'a credential nobody outside this branch may read' > "$repo/secret.txt"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm secret
  git -C "$repo" rev-parse secret:secret.txt
  git -C "$repo" checkout -q main
}

# The flag set of decision 4, asserted without starting anything. A container
# that runs with the wrong flags is the whole risk of this phase, so the argv
# is pinned field by field rather than spot-checked.
test_p2_container_argv() {
  local root="$FIXTURE/p2-argv"; mkdir -p "$root/stub" "$root/work" "$root/out"
  cat > "$root/stub/podman" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"image inspect"*) printf '%s %s\n' "$P2_DIGEST" "$P2_ID" ;;
  *) printf '10.89.14.10\n' ;;
esac
STUB
  chmod +x "$root/stub/podman"
  local entry argv
  entry="$(jq -cn --arg tag "$P2_IMAGE" --arg digest "$P2_DIGEST" \
    '{repo:"alpha", image:{tag:$tag, digest:$digest}, network:"none", timeout_seconds:1800,
      engine:"claude", writes_code:true}')"

  ( source "$REPO/lib/container.sh"
    MEUTE_PODMAN="$root/stub/podman" container_ready "$entry" >/dev/null 2>&1
    container_argv "$entry" build claude "$root/work" "$root/out" -- git status
    printf '%s\n' "${CONTAINER_ARGV[@]}" ) > "$root/argv-none"
  argv="$(tr '\n' ' ' < "$root/argv-none")"

  has "argv: it is a podman run"              "$argv" "run "
  has "argv: the container is removed"        "$argv" "--rm"
  has "argv: the host uid is kept"            "$argv" "--userns=keep-id:uid=1000,gid=1000"
  has "argv: every capability is dropped"     "$argv" "--cap-drop=ALL"
  has "argv: privileges cannot be regained"   "$argv" "--security-opt=no-new-privileges"
  has "argv: pid 1 reaps"                     "$argv" "--init"
  has "argv: the pid count is bounded"        "$argv" "--pids-limit=2048"
  has "argv: the scratch tree is /work"       "$argv" "--volume ${root}/work:/work:Z"
  has "argv: captures land in /out"           "$argv" "--volume ${root}/out:/out:Z"
  has "argv: the cwd is the scratch tree"     "$argv" "--workdir /work"
  has "argv: the run is bounded"              "$argv" "--timeout 1800"
  has "argv: ...and so is the stop"           "$argv" "--stop-timeout"
  # The pin is verified against a tag, but a tag is a moving name: anything
  # that re-tags the image between the assert and the run would substitute
  # what executes. podman is given the immutable ID the assert resolved.
  has   "argv: the verified image ID is what runs"   "$argv" "$P2_ID"
  hasnt "argv: ...and the tag never reaches podman"  "$argv" "$P2_IMAGE"
  has   "argv: a vanished image is an error, not a pull" "$argv" "--pull=never"
  has "argv: the command follows the image"   "$argv" "git status"
  # The owner's checkout is never mounted, and no host path reaches the
  # container except the two scratch directories this phase creates.
  # /work, /out, and one credential volume -- nothing else reaches the
  # container, and in particular never the owner's checkout.
  is  "argv: nothing else is mounted"         "$(grep -c '^--volume$' "$root/argv-none")" "3"

  has "argv (none): the network is off"       "$argv" "--network=none"
  hasnt "argv (none): no proxy is injected"   "$argv" "HTTPS_PROXY"
  hasnt "argv (none): and no host alias"      "$argv" "--add-host"

  ( source "$REPO/lib/container.sh"
    export MEUTE_PODMAN="$root/stub/podman"
    container_ready "$entry" >/dev/null 2>&1
    container_argv "$(jq -c '.network = "proxied"' <<< "$entry")" build claude "$root/work" "$root/out" -- git status
    printf '%s\n' "${CONTAINER_ARGV[@]}" ) > "$root/argv-proxied"
  argv="$(tr '\n' ' ' < "$root/argv-proxied")"
  has "argv (proxied): on the internal network"      "$argv" "--network=atelier-internal"
  has "argv (proxied): the proxy resolves by address" "$argv" "--add-host atelier-egress:10.89.14.10"
  has "argv (proxied): HTTPS_PROXY is injected"       "$argv" "HTTPS_PROXY=http://atelier-egress:3128"
  # Atelier's finding: curl reads the lowercase form and ignores the other.
  has "argv (proxied): ...and https_proxy too"        "$argv" "https_proxy=http://atelier-egress:3128"
  has "argv (proxied): nothing bypasses the proxy"    "$argv" "NO_PROXY="

  # The preflight of Phase 2b is the one stage that takes no network at all,
  # whatever the tier says, because it only reads a credential.
  ( source "$REPO/lib/container.sh"
    export MEUTE_PODMAN="$root/stub/podman"
    container_ready "$entry" >/dev/null 2>&1
    container_argv "$(jq -c '.network = "proxied"' <<< "$entry")" preflight claude "" "" -- true
    printf '%s\n' "${CONTAINER_ARGV[@]}" ) > "$root/argv-pre"
  argv="$(tr '\n' ' ' < "$root/argv-pre")"
  has   "argv (preflight): takes no network whatever the tier says" "$argv" "--network=none"
  hasnt "argv (preflight): and no proxy"                            "$argv" "HTTPS_PROXY"
  # §4.4 gives the preflight no mounts: it reads a credential, and a scratch
  # tree it cannot use is a scratch tree it should not have.
  hasnt "argv (preflight): no scratch tree"   "$argv" "/work"
  hasnt "argv (preflight): no capture tree"   "$argv" "/out"

  # Phase 2b. The image root is not the agent's to change -- it is pinned by
  # digest, so a write there is lost at --rm anyway and is one more place to
  # hide. Measured: both CLIs complete under this.
  argv="$(tr '\n' ' ' < "$root/argv-none")"
  has "argv: the image root is read-only"     "$argv" "--read-only"
  has "argv: ...with /tmp the one exception"  "$argv" "--tmpfs /tmp"
  # One credential, the entry's own engine's, and never the GitHub token --
  # `just auth` fills that one with the owner's full-scope interactive login.
  has "argv: the engine's own credential is mounted" "$argv" "atelier-auth-claude:/home/agent/.claude:z"
  hasnt "argv: ...and no other engine's"             "$argv" "atelier-auth-codex"
  hasnt "argv: ...and never the GitHub token"        "$argv" "atelier-auth-gh"
  ( source "$REPO/lib/container.sh"
    export MEUTE_PODMAN="$root/stub/podman"
    container_ready "$(jq -c '.engine = "codex"' <<< "$entry")" >/dev/null 2>&1
    container_argv "$(jq -c '.engine = "codex"' <<< "$entry")" build codex "$root/work" "$root/out" -- true
    printf '%s\n' "${CONTAINER_ARGV[@]}" ) > "$root/argv-codex"
  argv="$(tr '\n' ' ' < "$root/argv-codex")"
  has "argv: a codex entry mounts the codex credential" "$argv" "atelier-auth-codex:/home/agent/.codex:z"
  hasnt "argv: ...and not claude's"                     "$argv" "atelier-auth-claude"

  # A tier that does not write code cannot write the branch it is reading.
  # git still works there: status, diff <base>...HEAD, log and show all
  # succeed on a read-only mount, provided it is still relabelled.
  ( source "$REPO/lib/container.sh"
    export MEUTE_PODMAN="$root/stub/podman"
    container_ready "$entry" >/dev/null 2>&1
    container_argv "$(jq -c '.writes_code = false' <<< "$entry")" build claude "$root/work" "$root/out" -- true
    printf '%s\n' "${CONTAINER_ARGV[@]}" ) > "$root/argv-ro"
  argv="$(tr '\n' ' ' < "$root/argv-ro")"
  has   "argv: a reading tier gets /work read-only" "$argv" "${root}/work:/work:ro,Z"
  hasnt "argv: ...and /out stays writable"          "$argv" "/out:ro"
  argv="$(tr '\n' ' ' < "$root/argv-none")"
  has   "argv: a writing tier keeps /work writable" "$argv" "${root}/work:/work:Z"

  # A stage that runs an engine must carry exactly one credential. An empty
  # or unknown engine used to mean "mount nothing and carry on", which is
  # right for the probe and wrong for a build: the run would reach the
  # container and fail there with an auth error, rather than being refused
  # here with a reason.
  local rc out
  for stage in build preflight; do
    out="$( source "$REPO/lib/container.sh"
            export MEUTE_PODMAN="$root/stub/podman"
            container_ready "$entry" >/dev/null 2>&1
            container_argv "$entry" "$stage" "" "$root/work" "$root/out" -- true 2>&1 )"; rc=$?
    is  "argv: ${stage} refuses an engine it cannot mount a credential for" "$rc" "1"
    has "argv: ...with a reason rather than a silent no-credential run"     "$out" "credential"
  done
  out="$( source "$REPO/lib/container.sh"
          export MEUTE_PODMAN="$root/stub/podman"
          container_ready "$entry" >/dev/null 2>&1
          container_argv "$entry" build gpt "$root/work" "$root/out" -- true 2>&1 )"; rc=$?
  is "argv: an unrecognised engine is refused too" "$rc" "1"
  # The probe holds no credential deliberately, and says so by taking a
  # path of its own rather than falling through the engine branch.
  out="$( source "$REPO/lib/container.sh"
          export MEUTE_PODMAN="$root/stub/podman"
          container_ready "$entry" >/dev/null 2>&1
          container_argv "$entry" probe "" "$root/work" "$root/out" -- true
          printf '%s\n' "${CONTAINER_ARGV[@]}" | tr '\n' ' ' )"; rc=$?
  is    "argv: the probe needs no engine and no credential" "$rc" "0"
  hasnt "argv: ...and mounts none"                          "$out" "atelier-auth"
  # An unknown stage is refused rather than guessed at.
  out="$( source "$REPO/lib/container.sh"
          export MEUTE_PODMAN="$root/stub/podman"
          container_ready "$entry" >/dev/null 2>&1
          container_argv "$entry" teatime claude "$root/work" "$root/out" -- true 2>&1 )"; rc=$?
  is "argv: an unknown stage is refused, not guessed" "$rc" "1"
}

# What the flags actually buy, asked of the kernel rather than of the argv.
# One container start answers every question: a probe per assertion would
# make the suite pay a container start each time for nothing.
test_p2_isolation() {
  if ! p2_image_present; then
    skip "isolation: the real container boundary" "${P2_IMAGE} is not on this host (expected in CI)"
    return 0
  fi
  local root="$FIXTURE/p2-iso"; mkdir -p "$root/out"
  local blob; blob="$(p2_source_repo "$root/src")"
  local base; base="$(git -C "$root/src" rev-parse HEAD)"

  # The scratch tree the container will see: a clone, not the repo.
  ( source "$REPO/lib/container.sh"; source "$REPO/lib/scratch.sh"
    scratch_clone "$root/src" "$root/work" main "meute/probe-2026-09-22" "$base" ) >/dev/null 2>&1

  local probe; probe="$(cat <<'SH'
echo "uid=$(id -u)"
echo "gid=$(id -g)"
echo "capbnd=$(awk '/^CapBnd/{print $2}' /proc/self/status)"
echo "nonewprivs=$(awk '/^NoNewPrivs/{print $2}' /proc/self/status)"
echo "home=$HOME"
touch /work/written-inside 2>/dev/null && echo "work=writable" || echo "work=readonly"
touch /out/capture 2>/dev/null && echo "out=writable" || echo "out=readonly"
git -C /work status --porcelain >/dev/null 2>&1 && echo "gitstatus=ok" || echo "gitstatus=failed"
git -C /work diff "$BASE_SHA"...HEAD >/dev/null 2>&1 && echo "gitdiff=ok" || echo "gitdiff=failed"
git -C /work cat-file -e SECRET_BLOB 2>/dev/null && echo "secret=present" || echo "secret=absent"
getent hosts example.com >/dev/null 2>&1 && echo "dns=resolved" || echo "dns=failed"
test -e "$HOST_HOME/.claude" && echo "hosthome=visible" || echo "hosthome=absent"
test -e "$HOST_ROOT" && echo "hostroot=visible" || echo "hostroot=absent"
SH
)"
  probe="${probe//SECRET_BLOB/$blob}"
  local entry out
  entry="$(jq -cn --arg tag "$P2_IMAGE" --arg digest "$P2_DIGEST" \
    '{repo:"alpha", image:{tag:$tag, digest:$digest}, network:"none", timeout_seconds:120}')"
  out="$( source "$REPO/lib/container.sh"
          container_ready "$entry" >/dev/null 2>&1 \
            || { printf 'container_ready refused: %s\n' "$CONTAINER_BLOCKED"; exit 1; }
          BASE_SHA="$base" HOST_HOME="$HOME" HOST_ROOT="$REPO" \
          container_run "$entry" build claude "$root/work" "$root/out" -- \
            env BASE_SHA="$base" HOST_HOME="$HOME" HOST_ROOT="$REPO" sh -c "$probe" 2>&1 )"

  local field; field() { grep -m1 "^$1=" <<< "$out" | cut -d= -f2-; }
  is "isolation: the agent is uid 1000, not root"      "$(field uid)"        "1000"
  is "isolation: ...and gid 1000"                      "$(field gid)"        "1000"
  is "isolation: the capability bounding set is empty"  "$(field capbnd)"     "0000000000000000"
  is "isolation: privileges cannot be regained"         "$(field nonewprivs)" "1"
  is "isolation: /work is writable"                     "$(field work)"       "writable"
  is "isolation: /out is writable"                      "$(field out)"        "writable"
  # The defect that made §4.2 choose a clone over a linked worktree, proven
  # from inside: a worktree's .git points at a host path that is not there.
  is "isolation: git status works on the scratch tree"  "$(field gitstatus)"  "ok"
  is "isolation: git diff <base>...HEAD works too"      "$(field gitdiff)"    "ok"
  is "isolation: the source's other branches are absent" "$(field secret)"    "absent"
  is "isolation: under network none, nothing resolves"  "$(field dns)"        "failed"
  is "isolation: the owner's home is not mounted"       "$(field hosthome)"   "absent"
  is "isolation: nor is the meute checkout"             "$(field hostroot)"   "absent"
  hasnt "isolation: \$HOME is the image's, not the owner's" "$(field home)"   "$HOME"

  # What the container wrote is the host user's afterwards -- keep-id's whole
  # purpose, and what lets commit_worktree run host-side over the result.
  [[ -f "$root/work/written-inside" ]] \
    && is "isolation: a file written inside belongs to the host user afterwards" \
          "$(stat -c '%u' "$root/work/written-inside")" "$(id -u)" \
    || bad "isolation: a file written inside belongs to the host user afterwards" "nothing was written"
}

# The clone is not the repository. §4.2's claim, asserted in both directions
# so --no-local cannot be quietly dropped later.
test_p2_scratch_clone() {
  local root="$FIXTURE/p2-clone"; mkdir -p "$root"
  local blob; blob="$(p2_source_repo "$root/src")"
  local base; base="$(git -C "$root/src" rev-parse HEAD)"
  source "$REPO/lib/scratch.sh"

  scratch_clone "$root/src" "$root/work" main "meute/lint-2026-09-22" "$base" >/dev/null 2>&1
  is  "clone: the branch is cut at the recorded base" \
      "$(git -C "$root/work" rev-parse HEAD)" "$base"
  is  "clone: ...and checked out under the run's name" \
      "$(git -C "$root/work" rev-parse --abbrev-ref HEAD)" "meute/lint-2026-09-22"
  # The transport path honours --single-branch and cannot hardlink; a
  # local-path clone copies the whole object store, purged history included.
  ( cd "$root/work" && git cat-file -e "$blob" 2>/dev/null ) \
    && bad "clone: an unrelated branch's object is absent" "the secret blob came across" \
    || ok "clone: an unrelated branch's object is absent"
  is  "clone: ...and so is its branch" \
      "$(git -C "$root/work" branch -a --list '*secret*' | wc -l)" "0"
  # The other direction, so the flag cannot be dropped without a failure.
  git clone -q "$root/src" "$root/local-clone" 2>/dev/null
  ( cd "$root/local-clone" && git cat-file -e "$blob" 2>/dev/null ) \
    && ok "clone: a local clone WOULD have carried it -- the flag is what stops it" \
    || bad "clone: a local clone WOULD have carried it -- the flag is what stops it" "absent either way; the assertion above proves nothing"
  is  "clone: the owner's checkout is untouched" \
      "$(git -C "$root/src" status --porcelain | wc -l)" "0"

  # A repo with no resolvable default branch takes the source's HEAD, as the
  # host path already does.
  scratch_clone "$root/src" "$root/work2" "" "meute/lint-2026-09-22" "$base" >/dev/null 2>&1
  is  "clone: no default branch falls back to HEAD" \
      "$(git -C "$root/work2" rev-parse HEAD)" "$base"

  # A later stage clones the branch it is continuing, not the default one.
  git -C "$root/src" branch meute/draft-2026-09-01 main
  scratch_clone "$root/src" "$root/work3" "" "meute/draft-2026-09-01" "$base" >/dev/null 2>&1
  is  "clone: a later stage checks out the recorded branch" \
      "$(git -C "$root/work3" rev-parse --abbrev-ref HEAD)" "meute/draft-2026-09-01"

  # gitignored build plumbing travels into the clone exactly as into a worktree.
  printf 'sdk.dir=/opt/sdk\n' > "$root/src/local.properties"
  printf 'local.properties\n' > "$root/src/.gitignore"
  git -C "$root/src" add .gitignore
  git -C "$root/src" -c user.email=t@t -c user.name=t commit -qm ignore
  scratch_copy_files "$root/src" "$root/work4" local.properties >/dev/null 2>&1 || true
  [[ -f "$root/work4/local.properties" ]] \
    && ok "clone: worktree_files are carried into the clone" \
    || bad "clone: worktree_files are carried into the clone" "local.properties did not arrive"
}

# Work is never left only in the clone cleanup removes.
test_p2_scratch_import() {
  local root="$FIXTURE/p2-import"; mkdir -p "$root"
  p2_source_repo "$root/src" >/dev/null
  local base; base="$(git -C "$root/src" rev-parse main)"
  source "$REPO/lib/scratch.sh"

  # The ordinary path: the branch does not exist in the source, so it arrives.
  scratch_clone "$root/src" "$root/work" main "meute/lint-2026-09-22" "$base" >/dev/null 2>&1
  echo change > "$root/work/new.txt"
  git -C "$root/work" add -A
  git -C "$root/work" -c user.email=t@t -c user.name=t commit -qm work
  local tip; tip="$(git -C "$root/work" rev-parse HEAD)"
  scratch_import "$root/src" "$root/work" "meute/lint-2026-09-22" 2026-09-22 >/dev/null 2>&1
  is "import: the branch lands in the owner's repo" \
     "$(git -C "$root/src" rev-parse meute/lint-2026-09-22 2>/dev/null)" "$tip"
  is "import: ...as a branch, not aside" "$SCRATCH_IMPORT" "branch"

  # A non-fast-forward: the owner moved the branch on while the run worked.
  # git refuses, and the work goes to a ref nothing has checked out.
  scratch_clone "$root/src" "$root/work2" main "meute/lint-2026-09-23" "$base" >/dev/null 2>&1
  echo one > "$root/work2/a.txt"; git -C "$root/work2" add -A
  git -C "$root/work2" -c user.email=t@t -c user.name=t commit -qm one
  local aside_tip; aside_tip="$(git -C "$root/work2" rev-parse HEAD)"
  git -C "$root/src" branch meute/lint-2026-09-23 secret
  scratch_import "$root/src" "$root/work2" "meute/lint-2026-09-23" 2026-09-23 >/dev/null 2>&1
  is "import: a non-fast-forward goes aside, not nowhere" "$SCRATCH_IMPORT" "aside"
  is "import: ...to a dated ref under refs/meute/import" \
     "$(git -C "$root/src" rev-parse refs/meute/import/meute/lint-2026-09-23-2026-09-23 2>/dev/null)" "$aside_tip"
  is "import: ...and the owner's branch is left alone" \
     "$(git -C "$root/src" rev-parse meute/lint-2026-09-23)" "$(git -C "$root/src" rev-parse secret)"

  # A branch checked out somewhere is stepped over BEFORE the run: git would
  # refuse the import afterwards, and the run's work would have nowhere to go.
  git -C "$root/src" worktree add -q "$root/wt" -b meute/checked-out main 2>/dev/null
  scratch_branch_is_checked_out "$root/src" meute/checked-out \
    && ok "import: a branch checked out in a worktree is seen before the run" \
    || bad "import: a branch checked out in a worktree is seen before the run" "not detected"
  scratch_branch_is_checked_out "$root/src" meute/lint-2026-09-22 \
    && bad "import: ...and one that is not is not" "false positive" \
    || ok "import: ...and one that is not is not"
  is "import: the checked-out branch still holds what the owner had" \
     "$(git -C "$root/src" rev-parse meute/checked-out)" "$base"
}

# Fail closed: a pin that does not match, a proxy that is not running, an
# address that cannot be read. Each is a step-over -- the fire runs the next
# entry -- never a skip, which would end the fire and starve the queue.
test_p2_fail_closed() {
  local root="$FIXTURE/p2-closed"; mkdir -p "$root/stub"
  local entry
  entry="$(jq -cn --arg tag "$P2_IMAGE" --arg digest "$P2_DIGEST" \
    '{repo:"alpha", runtime:"container", image:{tag:$tag, digest:$digest}, network:"proxied"}')"

  # Everything as it should be.
  cat > "$root/stub/podman" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"image inspect"*) printf '%s %s\n' "\${STUB_DIGEST-$P2_DIGEST}" "$P2_ID" ;;
  *"container inspect"*"State.Running"*) printf '%s\n' "\${STUB_EGRESS:-true}" ;;
  *"NetworkSettings"*) printf '%s\n' "\${STUB_IP-10.89.14.10}" ;;
  *) exit 125 ;;
esac
STUB
  chmod +x "$root/stub/podman"
  local ready; ready() {
    ( source "$REPO/lib/container.sh"
      MEUTE_PODMAN="$root/stub/podman" container_ready "$entry" >/dev/null 2>&1 \
        && printf 'ready\n' || printf '%s\n' "$CONTAINER_BLOCKED" ) 2>/dev/null
  }
  is "fail closed: a matching pin and a live proxy are ready" "$(ready)" "ready"
  # The ID the assert resolved is what the caller must run.
  is "fail closed: a verified pin exports the image ID" \
     "$( source "$REPO/lib/container.sh"
         MEUTE_PODMAN="$root/stub/podman" container_ready "$entry" >/dev/null 2>&1
         printf '%s\n' "${CONTAINER_IMAGE_ID:-unset}" )" "$P2_ID"
  has "fail closed: a drifted image is not" \
      "$(STUB_DIGEST=sha256:$(printf 'f%.0s' {1..64}) ready)" \
      "alpha: image ${P2_IMAGE} is not at the pinned digest"
  is "fail closed: an absent image is not" \
     "$(STUB_DIGEST= ready)" \
     "alpha: image ${P2_IMAGE} is not present on this host"
  is "fail closed: a stopped egress proxy is not" \
     "$(STUB_EGRESS=false ready)" \
     "alpha: atelier-egress is not running"
  is "fail closed: an unreadable proxy address is not" \
     "$(STUB_IP= ready)" \
     "alpha: atelier-egress has no address on atelier-internal"
  # A tier that takes no network does not need the proxy at all.
  is "fail closed: a network: none entry needs no proxy" \
     "$(STUB_EGRESS=false ready_none)" "ready"
}
ready_none() {
  local root="$FIXTURE/p2-closed"
  ( source "$REPO/lib/container.sh"
    MEUTE_PODMAN="$root/stub/podman" container_ready \
      "$(jq -cn --arg tag "$P2_IMAGE" --arg digest "$P2_DIGEST" \
         '{repo:"alpha", runtime:"container", image:{tag:$tag, digest:$digest}, network:"none"}')" \
      >/dev/null 2>&1 && printf 'ready\n' || printf '%s\n' "$CONTAINER_BLOCKED" ) 2>/dev/null
}

# The same conditions, seen by the runner: the entry is stepped over in
# eligible(), the fire runs the next entry, and state/log never gets a line
# for the one that was passed -- one line per fire is what week_runs and the
# inbox consume.
test_p2_step_over() {
  local root="$FIXTURE/p2-step"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  mkdir -p "$root/stub"
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
jq -n '{is_error:false,result:"## Summary\nstub ran",total_cost_usd:0.01,num_turns:1}'
STUB
  chmod +x "$root/stub/claude"
  cat > "$root/stub/podman" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"image inspect"*) printf 'sha256:%s %s\n' "\$(printf 'f%.0s' {1..64})" "$P2_ID" ;;
  *"container inspect"*) printf 'true\n' ;;
  *"NetworkSettings"*) printf '10.89.14.10\n' ;;
  *) exit 125 ;;
esac
STUB
  chmod +x "$root/stub/podman"
  # Two repos: the container one drifts, the host one is fine.
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" \
    'import copy
beta = copy.deepcopy(d["repos"][0]); beta["name"] = "beta"; beta["runtime"] = "host"
del beta["image"]; del beta["push"]; del beta["repo"]; beta["tickets"] = []
beta["tasks"] = ["audit-security"]; beta["path"] = d["repos"][0]["path"]
d["repos"][0]["tasks"] = ["audit-security"]; d["repos"][0]["tickets"] = []
d["repos"].append(beta); d["community"] = []'
  local out
  out="$(PATH="$root/stub:$PATH" MEUTE_PODMAN="$root/stub/podman" MEUTE_QUOTA_STUB=100 \
         "$root/bin/run.sh" daily 2>&1)"
  has   "step-over: the drifted repo is named on stderr"   "$out" "is not at the pinned digest"
  has   "step-over: ...and the fire runs the next entry"   "$out" "repo=beta"
  is    "step-over: exactly one log line for the fire"     "$(wc -l < "$root/state/log")" "1"
  hasnt "step-over: ...and it is not the drifted repo's"   "$(cat "$root/state/log")" "repo=netlens"
  is    "step-over: the cursor sits on the entry that ran" \
        "$(kv_get_test "$root/state/cursor" cursor.daily)" "beta/audit-security"

  # --repo is a human overriding the QUEUE's gates (share, cap, quota), not
  # the boundary's readiness: a forced run on a drifted pin is the one case
  # where the operator is least able to see what they would be running.
  local forced
  forced="$(PATH="$root/stub:$PATH" MEUTE_PODMAN="$root/stub/podman" MEUTE_QUOTA_STUB=100 \
            "$root/bin/run.sh" daily --repo netlens 2>&1)"
  has   "step-over: a forced selection is still refused on a drifted pin" \
        "$forced" "is not at the pinned digest"
  hasnt "step-over: ...and never reaches the engine" "$forced" "status=ok"
  # An operator who named the repo is owed the reason in state/log, not a
  # generic "nothing was eligible". This is the one path where the drift is
  # otherwise invisible: the queue held exactly the entry they asked for.
  local forced_line; forced_line="$(tail -1 "$root/state/log")"
  has   "step-over: a forced refusal is logged as an error"   "$forced_line" "status=error"
  has   "step-over: ...naming the repo the operator asked for" "$forced_line" "repo=netlens"
  has   "step-over: ...and saying the pin did not match"       "$forced_line" "detail=netlens: image"
  has   "step-over: ...with the digest as the reason"          "$forced_line" "is not at the pinned digest"
  hasnt "step-over: ...not a generic empty round"              "$forced_line" "status=skipped"
  # Logged, but not retired: the cursor stays where the last successful fire
  # left it, so the entry the operator asked for is still there to retry once
  # the image is built. Only the unforced rotation advances past an entry.
  is    "step-over: ...but the forced entry stays retryable"   "$(kv_get_test "$root/state/cursor" cursor.daily)" "beta/audit-security"
}

# `meute container probe <repo>`: what a human runs to see whether a repo is
# container-ready, and what these tests drive. It is the only new reachable
# code path in this phase -- a timer fire still cannot dispatch a container.
test_p2_container_probe() {
  local root="$FIXTURE/p2-probe"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" \
    "d['repos'][0]['image'] = {'tag': '$P2_IMAGE', 'digest': '$P2_DIGEST'}"
  # These two refuse before anything touches podman, so they are asserted
  # here rather than behind the image gate below.
  local out rc
  out="$("$root/bin/meute" container probe beta 2>&1)"; rc=$?
  is  "probe: an unknown repo is refused"            "$rc" "1"
  has "probe: ...by name"                            "$out" "unknown repo 'beta'"
  yaml_edit "$root/repos.yaml" "$root/hostrepo.yaml" 'd["repos"][0]["runtime"] = "host"; del d["repos"][0]["image"]'
  out="$(MEUTE_MANIFEST="$root/hostrepo.yaml" "$root/bin/meute" container probe netlens 2>&1)"; rc=$?
  is  "probe: a host repo has nothing to probe"      "$rc" "1"
  has "probe: ...and is told so"                     "$out" "runs on the host"

  if ! p2_image_present; then
    skip "probe: against the real image" "${P2_IMAGE} is not on this host (expected in CI)"
    return 0
  fi
  out="$("$root/bin/meute" container probe netlens 2>&1)"; rc=$?
  is  "probe: it succeeds on a container-ready repo" "$rc" "0"
  has "probe: it reports the uid"                    "$out" "uid 1000"
  has "probe: it reports the capability set"         "$out" "capabilities none"
  has "probe: it reports no-new-privileges"          "$out" "no-new-privs yes"
  has "probe: it reports git working in /work"       "$out" "git in /work ok"
  has "probe: it reports /out writable"              "$out" "/out writable"
  has "probe: it reports the network is closed"      "$out" "dns blocked"
  has "probe: it names the pin it asserted"          "$out" "$P2_IMAGE"
  is  "probe: it leaves no scratch tree behind"      "$(ls "$root/.worktrees" 2>/dev/null | wc -l)" "0"
  is  "probe: the owner's checkout is untouched"     "$(git -C "$root/git-netlens" status --porcelain | wc -l)" "0"
}

# The engine adapters build argv and run nothing, so the same array can be
# handed to the host or to podman. The host path must not change shape.
test_p2_engine_argv() {
  local root="$FIXTURE/p2-engine"; mkdir -p "$root"
  printf 'do the thing\n' > "$root/prompt"
  local argv
  argv="$( source "$REPO/lib/engines.sh"
           MODEL=sonnet TOOLS="Read,Edit" PERMISSION_MODE=acceptEdits ALLOWED_TOOLS="Bash(pytest:*)" \
           MEUTE_SETTING_SOURCES= engine_argv_claude "$root/prompt"
           printf '%s\n' "${ENGINE_ARGV[@]}" )"
  is  "engine argv: claude is the command"      "$(head -1 <<< "$argv")" "claude"
  has "engine argv: the prompt is passed"       "$argv" "do the thing"
  has "engine argv: json envelope"              "$argv" "--output-format"
  has "engine argv: the model"                  "$argv" "sonnet"
  has "engine argv: the tier's tools"           "$argv" "Read,Edit"
  has "engine argv: the permission mode"        "$argv" "acceptEdits"
  has "engine argv: the allowlist"              "$argv" "Bash(pytest:*)"
  hasnt "engine argv: it does not cd"           "$argv" "cd"
  hasnt "engine argv: nor time itself out"      "$argv" "timeout"

  argv="$( source "$REPO/lib/engines.sh"
           WRITES_CODE=1 MEUTE_CODEX_MODEL= engine_argv_codex "$root/prompt" /work /out/codex-last
           printf '%s\n' "${ENGINE_ARGV[@]}" )"
  is  "engine argv: codex is the command"        "$(head -1 <<< "$argv")" "codex"
  has "engine argv: the workdir is a parameter"  "$argv" "/work"
  has "engine argv: so is the final-message file" "$argv" "/out/codex-last"
  has "engine argv: a writing tier gets workspace-write" "$argv" "workspace-write"
  argv="$( source "$REPO/lib/engines.sh"
           WRITES_CODE=0 MEUTE_CODEX_MODEL= engine_argv_codex "$root/prompt" /work /out/codex-last
           printf '%s\n' "${ENGINE_ARGV[@]}" )"
  has "engine argv: a reading tier gets read-only" "$argv" "read-only"

  # The whole sandbox decision, in one table. On the host codex's own sandbox
  # is the only boundary, so it keeps workspace-write; inside the container
  # that boundary has been replaced by a stronger one AND codex's own cannot
  # initialise there, which produces a green run that changed nothing.
  local sb; sb() { ( source "$REPO/lib/engines.sh"; codex_sandbox "$1" "$2" ); }
  is "sandbox: host, writing tier -- codex guards itself"   "$(sb host 1)"      "workspace-write"
  is "sandbox: host, reading tier -- nothing to relax"      "$(sb host 0)"      "read-only"
  is "sandbox: container, reading tier -- still nothing"    "$(sb container 0)" "read-only"
  is "sandbox: container, writing tier -- the container is the boundary" \
     "$(sb container 1)" "danger-full-access"
  # Anything that is not plainly the container keeps codex's own sandbox: an
  # unset, empty or unexpected runtime must never reach full access.
  is "sandbox: an empty runtime is not the container"       "$(sb "" 1)"        "workspace-write"
  is "sandbox: nor is an unrecognised one"                  "$(sb vm 1)"        "workspace-write"
}


# The `proxied` profile, run rather than argued. Every tier but tier2-web
# uses it, all of Phase 2b depends on it, and the allow-list is what PRP-004
# §1 sells the container on -- so the claim "the agent reaches the provider
# and nothing else" is asked of the proxy itself, once, in one start.
test_p2_proxied_egress() {
  if ! p2_image_present; then
    skip "egress: the proxied profile" "${P2_IMAGE} is not on this host (expected in CI)"
    return 0
  fi
  local ip
  ip="$( source "$REPO/lib/container.sh"; egress_running && egress_ip )" || ip=""
  if [[ -z "$ip" ]]; then
    skip "egress: the proxied profile" "atelier-egress is not running on this host (expected in CI)"
    return 0
  fi
  local root="$FIXTURE/p2-egress"; mkdir -p "$root/work" "$root/out"
  local entry out
  entry="$(jq -cn --arg tag "$P2_IMAGE" --arg digest "$P2_DIGEST" \
    '{repo:"alpha", runtime:"container", image:{tag:$tag, digest:$digest},
      network:"proxied", timeout_seconds:120}')"
  is "egress: a proxied entry is ready when the proxy is up" \
     "$( source "$REPO/lib/container.sh"; container_ready "$entry" && echo ready || echo "$CONTAINER_BLOCKED" )" "ready"

  # github.com is on Atelier's allow-list; example.com is not. 56 is curl's
  # "recv failure" -- the proxy closing a CONNECT it refuses to open.
  local probe; probe="$(cat <<'SH'
getent hosts atelier-egress >/dev/null 2>&1 && echo "addhost=resolved" || echo "addhost=failed"
echo "https_upper=${HTTPS_PROXY:-unset}"
echo "https_lower=${https_proxy:-unset}"
echo "http_upper=${HTTP_PROXY:-unset}"
echo "http_lower=${http_proxy:-unset}"
echo "plain=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://github.com/ 2>/dev/null)"
echo "noproxy=${NO_PROXY-unset}"
echo "allowed=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 https://github.com/ 2>/dev/null)"
curl -s -o /dev/null --max-time 20 https://example.com/ 2>/dev/null
echo "denied_rc=$?"
SH
)"
  out="$( source "$REPO/lib/container.sh"
          container_ready "$entry" >/dev/null 2>&1 \
            || { printf 'container_ready refused: %s\n' "$CONTAINER_BLOCKED"; exit 1; }
          container_run "$entry" build claude "$root/work" "$root/out" -- sh -c "$probe" 2>&1 )"
  local field; field() { grep -m1 "^$1=" <<< "$out" | cut -d= -f2-; }
  is "egress: the proxy resolves through --add-host, not DNS" "$(field addhost)"    "resolved"
  is "egress: HTTPS_PROXY is set inside"                      "$(field https_upper)" "http://atelier-egress:3128"
  is "egress: ...and https_proxy, for clients that read only that spelling" "$(field https_lower)" "http://atelier-egress:3128"
  is "egress: nothing is exempted from the proxy"             "$(field noproxy)"    ""
  # Plain http has its own pair, and curl reads only the lowercase one there:
  # it refuses uppercase HTTP_PROXY on purpose, because a CGI request header
  # called `Proxy:` lands in the environment under exactly that name.
  is "egress: HTTP_PROXY is set inside"                       "$(field http_upper)" "http://atelier-egress:3128"
  is "egress: ...and http_proxy, the only one curl reads"     "$(field http_lower)" "http://atelier-egress:3128"
  is "egress: a plain-http fetch goes through the allow-list too" "$(field plain)"   "301"
  is "egress: an allow-listed host is reachable"              "$(field allowed)"    "200"
  # Not a timeout and not a DNS failure: the proxy refused the CONNECT.
  is "egress: a host off the allow-list is refused"           "$(field denied_rc)"  "56"
}

# The caller contract the argv split changed: lib/engines.sh no longer cds or
# times out, so bin/run.sh does both -- for BOTH engines. codex used to run
# from the runner's own cwd with --cd pointing at the worktree; it now runs
# from the worktree as claude always did. A live run would prove it weeks
# from now; a stub that reports its own pwd proves it here.
test_p2_engine_cwd() {
  local root="$FIXTURE/p2-cwd" repo="$FIXTURE/p2-cwd/git-c"
  mkdir -p "$root"/{state,tasks,stub} "$repo"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  printf 'Task {{REPO_NAME}} {{REPO_PATH}} {{FILE_BUDGET}} {{LENS}} {{REPORT_PATH}} {{DATE}} {{BRANCH}} {{TASK}} {{TIER}} {{REPO_SPEC}} {{ALLOWED_COMMANDS}} {{DEFAULT_BRANCH}} {{UPSTREAM}} {{ETIQUETTE}} {{ETIQUETTE_CONTENT}} {{TICKET_ID}} {{TICKET_TITLE}} {{TICKET_NOTES}}\n' > "$root/tasks/t.md"
  git -C "$repo" init -q -b main
  echo x > "$repo/f.txt"; git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init

  # Each stub records the directory it was started in, and codex also records
  # the directory it was TOLD to use, so the two can be compared.
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
pwd > "$(dirname "$0")/claude-pwd"
jq -n '{is_error:false,result:"## Summary\nstub ran",total_cost_usd:0.01,num_turns:1}'
STUB
  cat > "$root/stub/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "login" ]]; then printf 'Logged in using ChatGPT\n'; exit 0; fi
pwd > "$(dirname "$0")/codex-pwd"
last=""; cd_arg=""; sandbox=""
while (( $# )); do
  case "$1" in
    -o) last="$2"; shift ;;
    --cd) cd_arg="$2"; shift ;;
    -s) sandbox="$2"; shift ;;
  esac
  shift
done
printf '%s\n' "$cd_arg" > "$(dirname "$0")/codex-cd"
printf '%s\n' "$sandbox" > "$(dirname "$0")/codex-sandbox"
printf '## Summary\nstub ran\n' > "$last"
STUB
  chmod +x "$root/stub/claude" "$root/stub/codex"

  python3 - "$root" "$repo" <<'PY'
import sys, pathlib, yaml
root, repo = sys.argv[1], sys.argv[2]
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5,
                 "timeout_seconds": 60, "runtime": "host"},
    "policy": {"quota_floor_percent": 30, "community_share": 0.20,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk",
                        "writes_code": False, "network": "proxied"}},
    "tasks": {"t": {"tier": "tier2", "template": "tasks/t.md", "slots": ["daily"]}},
    "repos": [{"name": "c", "path": repo, "spec": "cwd fixture", "tasks": ["t"]}],
    "community": [],
}, open(pathlib.Path(root) / "repos.yaml", "w"), sort_keys=False)
PY

  local out
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 "$root/bin/run.sh" daily 2>&1)"
  has "cwd: the claude run completes"  "$out" "status=ok"
  local claude_pwd; claude_pwd="$(cat "$root/stub/claude-pwd" 2>/dev/null || echo none)"
  case "$claude_pwd" in
    "$root"/.worktrees/c-t-*) ok "cwd: claude is started inside the run's worktree" ;;
    *) bad "cwd: claude is started inside the run's worktree" "started in [$claude_pwd]" ;;
  esac

  : > "$root/state/cursor"
  out="$(PATH="$root/stub:$PATH" MEUTE_QUOTA_STUB=100 MEUTE_CODEX_QUOTA_CMD='echo 100' \
         "$root/bin/run.sh" daily --engine codex 2>&1)"
  has "cwd: the codex run completes" "$out" "status=ok"
  local codex_pwd codex_cd
  codex_pwd="$(cat "$root/stub/codex-pwd" 2>/dev/null || echo none)"
  codex_cd="$(cat "$root/stub/codex-cd" 2>/dev/null || echo none)"
  # codex names its working directory rather than inheriting it, and on the
  # host it has always run from the runner's own cwd. The argv split must not
  # change that: what `-s workspace-write` derives its writable root from --
  # cwd or --cd -- is unverified (PRP-004 §8), so moving the process is a
  # change to the sandbox's shape that nobody has measured.
  case "$codex_pwd" in
    "$root"/.worktrees/c-t-*) bad "cwd: codex on the host keeps the runner's cwd" "it was moved into the worktree" ;;
    *) ok "cwd: codex on the host keeps the runner's cwd" ;;
  esac
  case "$codex_cd" in
    "$root"/.worktrees/c-t-*) ok "cwd: ...and is told the worktree through --cd, as before" ;;
    *) bad "cwd: ...and is told the worktree through --cd, as before" "--cd was [$codex_cd]" ;;
  esac
  [[ "$codex_cd" != "$codex_pwd" ]] \
    && ok "cwd: the two differ on the host, which is the behaviour that shipped" \
    || bad "cwd: the two differ on the host, which is the behaviour that shipped" "both were [$codex_pwd]"
  # On the host nothing has replaced codex's own sandbox, so nothing may
  # relax it -- asserted on the real invocation, not only on the table.
  local host_sandbox; host_sandbox="$(cat "$root/stub/codex-sandbox" 2>/dev/null || echo none)"
  is    "sandbox: a host run keeps codex's own sandbox"  "$host_sandbox" "read-only"
  hasnt "sandbox: ...and never full access on the host"  "$host_sandbox" "danger"
}


# podman's --timeout bounds the CONTAINER; it does nothing about a podman
# client or control-plane call that stalls. Under a timer that is the whole
# fleet wedged behind one flock, so the run carries its own wall clock --
# deliberately slack above the inner one, so it can only fire when podman
# itself is stuck rather than pre-empting a run that is merely slow.
test_p2_outer_bound() {
  source "$REPO/lib/container.sh"
  is "outer bound: slack above the container's own timeout" \
     "$(container_outer_bound 1800)" "$(( 1800 + 30 + 60 ))"
  is "outer bound: ...at every size"  "$(container_outer_bound 60)" "$(( 60 + 30 + 60 ))"
  # A missing or unreadable timeout is not a licence to run forever.
  is "outer bound: a missing timeout still has one" "$(container_outer_bound "")" "$(( 1800 + 30 + 60 ))"
  is "outer bound: so does a nonsense one"          "$(container_outer_bound abc)" "$(( 1800 + 30 + 60 ))"
  # The wiring itself: a stalled podman must be killed, not waited on. There
  # is no way to assert this without waiting out a real bound, so the call is
  # pinned by reading it -- the same way the --runtime guard is.
  is "outer bound: container_run wraps podman in that wall clock" \
     "$(grep -c 'timeout --kill-after="\$CONTAINER_STOP_TIMEOUT" "\$(container_outer_bound' "$REPO/lib/container.sh")" "1"
}

# Phase 2b removes the abort that kept a timer fire from dispatching a
# container, so what has to be asserted now is the opposite: that a verified
# entry IS dispatched, into a container carrying the flags 2a settled, and
# that the log says which image actually ran. Asserted without a real image,
# so a machine that has none -- CI, a fresh checkout -- still covers the
# dispatch path; the stub podman stands in for the engine's envelope.
test_p2b_container_dispatch() {
  local root="$FIXTURE/p2-cred"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  mkdir -p "$root/stub"
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
echo invoked >> "$(dirname "$0")/invocations"
jq -n '{is_error:false,result:"## Summary\nstub ran",total_cost_usd:0.01,num_turns:1}'
STUB
  # The fixture's own pin, answered as podman would: a verified boundary is
  # the precondition for reaching the abort, not the thing under test here.
  cat > "$root/stub/podman" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$root/stub/podman-calls"
case "\$*" in
  *"image inspect"*) printf '%s %s\n' "$P4_DIGEST" "$P2_ID" ;;
  *"{{.State.Running}}"*) printf 'true\n' ;;
  *"NetworkSettings"*) printf '10.89.14.10\n' ;;
  *"claude auth status"*) printf '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}\n' ;;
  *" -p "*) printf '{"is_error":false,"result":"## Summary ran inside the container","total_cost_usd":0.01,"num_turns":1}\n' ;;
  *) exit 125 ;;
esac
STUB
  chmod +x "$root/stub/claude" "$root/stub/podman"
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" \
    "d['repos'][0]['tasks'] = ['audit-security']; d['repos'][0]['tickets'] = []; d['community'] = []"
  local out
  out="$(PATH="$root/stub:$PATH" MEUTE_PODMAN="$root/stub/podman" MEUTE_QUOTA_STUB=100 \
         "$root/bin/run.sh" daily --repo netlens 2>&1)"
  has "dispatch: a verified entry runs rather than being refused" "$out" "status=ok"
  hasnt "dispatch: ...and the Phase 1 refusal is gone"            "$out" "needs the credential volumes"
  is  "dispatch: the entry is logged once"  "$(grep -c 'repo=netlens' "$root/state/log")" "1"
  # The boundary was really crossed, and the log says what ran: the image ID
  # the digest assert resolved, not the tag it was asked about.
  has "dispatch: the log names the runtime"  "$out" "runtime=container"
  has "dispatch: ...and the image that ran"  "$out" "image=${P2_ID:0:12}"
  has "dispatch: ...and the stage that ran"  "$out" "stage=build"
  has "dispatch: the pin was asserted first" "$(cat "$root/stub/podman-calls")" "{{.Digest}}"
  # Two containers, in order: the credential probe with no network and no
  # trees, then the engine with /work, /out and the proxied profile.
  is  "dispatch: the preflight ran in a container of its own" \
      "$(grep -c 'claude auth status' "$root/stub/podman-calls")" "1"
  has "dispatch: ...on no network at all"   "$(grep 'claude auth status' "$root/stub/podman-calls")" "--network=none"
  hasnt "dispatch: ...with no scratch tree" "$(grep 'claude auth status' "$root/stub/podman-calls")" "/work"
  has "dispatch: ...and only its own credential" \
      "$(grep 'claude auth status' "$root/stub/podman-calls")" "atelier-auth-claude:/home/agent/.claude:z"
  local engine_call; engine_call="$(grep -- '-p ' "$root/stub/podman-calls" | tail -1)"
  has "dispatch: the engine got the scratch tree at /work" "$engine_call" ":/work:"
  has "dispatch: ...and /out for its captures"             "$engine_call" ":/out:Z"
  has "dispatch: ...the image root read-only"              "$engine_call" "--read-only"
  has "dispatch: ...its own credential volume"             "$engine_call" "atelier-auth-claude"
  hasnt "dispatch: ...and never the GitHub token"          "$(cat "$root/stub/podman-calls")" "atelier-auth-gh"
}

# The last precondition before an engine runs. The host may be logged in
# while the volume the container reads is empty, signed out, or absent -- so
# the probe runs inside, and a failure is remediable (`just auth`), which
# makes it retryable under force rather than a discarded request.
test_p2b_preflight() {
  local root="$FIXTURE/p2b-preflight"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  mkdir -p "$root/stub"
  # A podman whose image verifies, but whose container reports a signed-out
  # credential -- exactly the shape of an unpopulated auth volume.
  cat > "$root/stub/podman" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$root/stub/podman-calls"
case "\$*" in
  *"image inspect"*) printf '%s %s\n' "$P4_DIGEST" "$P2_ID" ;;
  *"{{.State.Running}}"*) printf 'true\n' ;;
  *"NetworkSettings"*) printf '10.89.14.10\n' ;;
  *"claude auth status"*) printf '{"loggedIn":false}\n' ;;
  *) exit 125 ;;
esac
STUB
  chmod +x "$root/stub/podman"
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" \
    "d['repos'][0]['tasks'] = ['audit-security']; d['repos'][0]['tickets'] = []; d['community'] = []"
  local out
  out="$(PATH="$root/stub:$PATH" MEUTE_PODMAN="$root/stub/podman" MEUTE_QUOTA_STUB=100 \
         "$root/bin/run.sh" daily --repo netlens 2>&1)"
  has "preflight: a signed-out volume stops the run"   "$out" "status=error"
  has "preflight: ...saying what to do about it"       "$out" "not logged in inside the container"
  has "preflight: ...and naming just auth"             "$out" "just auth"
  hasnt "preflight: ...before any engine was invoked"  "$(cat "$root/stub/podman-calls")" "\-p "
  # Remediable, so forced it stays retryable -- the operator runs `just auth`
  # and asks for the same repo again.
  is  "preflight: a forced refusal leaves the cursor alone" \
      "$(kv_get_test "$root/state/cursor" cursor.daily)" ""
  # §4.4 wants the stage named, and §7's demotion rule excludes
  # stage=preflight lines BY NAME: logged as `-`, a signed-out credential
  # counts toward demoting a repo for a reason that has nothing to do with it.
  local line; line="$(tail -1 "$root/state/log")"
  has "preflight: the line names the stage"       "$line" "stage=preflight"
  has "preflight: ...and the runtime it was in"   "$line" "runtime=container"
  has "preflight: ...and the image it would run"  "$line" "image=${P2_ID:0:12}"
}

# The probe makes two scratch directories. If the second cannot be made, the
# first must still go: a leaked clone of a private repo under /tmp is exactly
# what the boundary exists to avoid. Needs no image -- the failure is before
# any container starts.
test_p2_probe_cleanup() {
  local root="$FIXTURE/p2-probe-clean"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  mkdir -p "$root/stub" "$root/tmp"
  cat > "$root/stub/podman" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"image inspect"*) printf '%s %s\n' "$P2_DIGEST" "$P2_ID" ;;
  *) exit 125 ;;
esac
STUB
  # Succeeds for the scratch clone, fails for the capture directory.
  cat > "$root/stub/mktemp" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *meute-probe-out-*) echo "mktemp: stubbed failure" >&2; exit 1 ;;
  *) exec /usr/bin/mktemp "$@" ;;
esac
STUB
  chmod +x "$root/stub/podman" "$root/stub/mktemp"
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" \
    "d['repos'][0]['image'] = {'tag': '$P2_IMAGE', 'digest': '$P2_DIGEST'}"

  local out rc
  out="$(PATH="$root/stub:$PATH" TMPDIR="$root/tmp" MEUTE_PODMAN="$root/stub/podman" \
         "$root/bin/meute" container probe netlens 2>&1)"; rc=$?
  is "probe cleanup: a failed second mktemp fails the probe" "$rc" "1"
  is "probe cleanup: ...and the first scratch tree is still removed" \
     "$(ls "$root/tmp" 2>/dev/null | wc -l)" "0"
}


# The pin has to be ONE observation, not two agreeing ones. Two inspects of
# the same tag can see two different images -- a retag between them passes
# the digest assert for one and runs the other -- and an identity that
# outlives what proved it is the same defect wherever it appears.
test_p2_pin_is_one_snapshot() {
  local root="$FIXTURE/p2-pin"; mkdir -p "$root/stub"
  cat > "$root/stub/podman" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$root/stub/calls"
case "\$*" in
  *"image inspect"*) printf '%s %s\n' "\${STUB_DIGEST-$P2_DIGEST}" "\${STUB_ID-$P2_ID}" ;;
  *"{{.State.Running}}"*) printf 'true\n' ;;
  *"NetworkSettings"*) printf '10.89.14.10\n' ;;
  *) exit 125 ;;
esac
STUB
  chmod +x "$root/stub/podman"
  local entry
  entry="$(jq -cn --arg tag "$P2_IMAGE" --arg digest "$P2_DIGEST" \
    '{repo:"alpha", runtime:"container", image:{tag:$tag, digest:$digest}, network:"proxied"}')"

  : > "$root/stub/calls"
  local id
  id="$( source "$REPO/lib/container.sh"
         MEUTE_PODMAN="$root/stub/podman" container_ready "$entry" >/dev/null 2>&1
         printf '%s\n' "${CONTAINER_IMAGE_ID:-unset}" )"
  is "pin: the digest and the ID come from one observation" \
     "$(grep -c 'image inspect' "$root/stub/calls")" "1"
  is "pin: ...and that observation's ID is what will run" "$id" "$P2_ID"

  # Binding: an ID is only usable for the entry whose pin produced it.
  # Non-empty is not proof it belongs here -- readiness passing for one repo
  # and failing for the next must not leave the first repo's image behind.
  local leaked
  leaked="$( source "$REPO/lib/container.sh"
             export MEUTE_PODMAN="$root/stub/podman"
             container_ready "$entry" >/dev/null 2>&1
             # A second repo whose pin cannot be verified at all.
             STUB_DIGEST= container_ready \
               "$(jq -c '.repo = "beta" | .image.tag = "agent-beta:gfeed"' <<< "$entry")" >/dev/null 2>&1
             printf '%s\n' "${CONTAINER_IMAGE_ID:-cleared}" )"
  is "pin: a failed readiness check leaves no previous image behind" "$leaked" "cleared"

  # Even with an ID in hand, the argv must refuse an entry it does not belong to.
  local refused rc
  refused="$( source "$REPO/lib/container.sh"
              export MEUTE_PODMAN="$root/stub/podman"
              container_ready "$entry" >/dev/null 2>&1
              container_argv "$(jq -c '.repo = "beta" | .image.tag = "agent-beta:gfeed"' <<< "$entry")" \
                build claude "$root" "$root" -- true 2>&1 )"; rc=$?
  is  "pin: the argv refuses an entry the verified ID is not for" "$rc" "1"
  has "pin: ...and says why"                                      "$refused" "verified"
  # The entry it IS for still builds, so the refusal is about identity.
  ( source "$REPO/lib/container.sh"
    export MEUTE_PODMAN="$root/stub/podman"
    container_ready "$entry" >/dev/null 2>&1
    container_argv "$entry" build claude "$root" "$root" -- true ) >/dev/null 2>&1 \
    && ok "pin: the entry it was verified for still builds" \
    || bad "pin: the entry it was verified for still builds" "refused its own entry"
}

# A forced refusal must stay retryable. The operator named this repo, the
# precondition they hit is one they can remediate -- build the image, start
# the proxy, bump the pin -- and the whole point of logging it is that they
# come back. Retiring the item they asked for turns a transient condition
# into a permanent loss, and in plan mode the loss is silent: the staged
# item is marked attempted and the next fire never offers it again.
test_p2_forced_refusal_is_retryable() {
  local universe="$FIXTURE/p2-retry" root="$FIXTURE/p2-retry/meute-stand-in"
  mkdir -p "$root"/{state,tasks,stub} "$universe/repo-one"
  ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/contrib" "$root/contrib"
  cp "$REPO/tasks/audit-security.md" "$root/tasks/"
  git -C "$universe/repo-one" init -q -b main
  echo x > "$universe/repo-one/f.txt"; git -C "$universe/repo-one" add -A
  git -C "$universe/repo-one" -c user.email=t@t -c user.name=t commit -qm init
  # A podman that exists and holds no such image, so the refusal is the
  # boundary's and not this machine's.
  printf '#!/usr/bin/env bash\necho "Error: no such image" >&2\nexit 125\n' > "$root/stub/podman"
  cat > "$root/stub/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" ]]; then printf '{"loggedIn":true,"subscriptionType":"max","authMethod":"stub"}\n'; exit 0; fi
echo invoked >> "$(dirname "$0")/invocations"
jq -n '{is_error:false,result:"## Summary\nstub ran",total_cost_usd:0.01,num_turns:1}'
STUB
  chmod +x "$root/stub/podman" "$root/stub/claude"
  # A fleet that runs in containers by default: a staged plan item inherits
  # that runtime and has no pin of its own, so it cannot be verified.
  python3 - "$root" <<'PY'
import sys, pathlib, yaml
root = pathlib.Path(sys.argv[1])
yaml.safe_dump({
    "version": 1,
    "defaults": {"engine": "claude", "model": "sonnet", "file_budget": 5,
                 "timeout_seconds": 60, "runtime": "container"},
    "policy": {"quota_floor_percent": 30, "community_share": 0.2,
               "tier3_max_in_flight": 3, "branch_prefix": "meute"},
    "tiers": {"tier2": {"tools": "Read,Grep,Glob", "permission_mode": "dontAsk",
                        "writes_code": False, "network": "proxied"}},
    "tasks": {"audit-security": {"tier": "tier2", "template": "tasks/audit-security.md",
                                 "slots": ["daily"]}},
    "repos": [], "community": [],
}, open(root / "repos.local.yaml", "w"), sort_keys=False)
PY
  "$root/bin/meute" plan --enqueue "$universe" >/dev/null 2>&1
  local key; key="$(jq -r '.entries[] | select(.path | endswith("/repo-one")) | .name' "$root/state/plan-queue.json" | head -1)"
  [[ -n "$key" ]] || { bad "retryable: the plan staged an item to force" "nothing staged"; return 0; }

  local out
  out="$(PATH="$root/stub:$PATH" MEUTE_PODMAN="$root/stub/podman" MEUTE_QUOTA_STUB=100 \
         "$root/bin/run.sh" daily --repo "$key" 2>&1)"
  has "retryable: the forced refusal is logged"        "$out" "status=error"
  has "retryable: ...naming the repo asked for"        "$out" "repo=${key}"
  has "retryable: ...with the boundary's reason"       "$out" "detail=${key}: no image pinned"
  [[ -f "$root/stub/invocations" ]] \
    && bad "retryable: ...and no engine ran" "the stub was invoked" \
    || ok "retryable: ...and no engine ran"
  # The remediable part: the item the operator asked for is still theirs to
  # retry once they have built the image.
  is "retryable: the staged item is not marked attempted" \
     "$(kv_get_test "$root/state/plan-complete" "plan/${key}/audit-security")" ""
  is "retryable: ...and the plan is not retired"  "$([[ -f "$root/state/plan-queue.json" ]] && echo staged || echo gone)" "staged"
  is "retryable: ...and the cursor did not move past it" \
     "$(kv_get_test "$root/state/cursor" plan-cursor.daily)" ""

  # The same rule at the other precondition a staged item can reach. A plan
  # entry never carries an image of its own -- build_plan_queue builds from a
  # synthetic project -- so the pin checks stop it in eligible(); what reaches
  # run_entry is the downgrade refusal, and that one archived the whole plan.
  out="$(PATH="$root/stub:$PATH" MEUTE_PODMAN="$root/stub/podman" MEUTE_QUOTA_STUB=100 \
         "$root/bin/run.sh" daily --repo "$key" --runtime host 2>&1)"
  has "retryable: a forced downgrade refusal is logged too" "$out" "is not a downgrade path"
  has "retryable: ...naming the staged repo"                "$out" "repo=${key}"
  is  "retryable: ...and the plan survives it"              "$([[ -f "$root/state/plan-queue.json" ]] && echo staged || echo archived)" "staged"
  is  "retryable: ...with the item still pending"           "$(kv_get_test "$root/state/plan-complete" "plan/${key}/audit-security")" ""
  is  "retryable: ...and no archive left behind"            "$(ls "$root"/state/plan-queue.completed-* 2>/dev/null | wc -l)" "0"
}

# A credential volume has to survive being used. Meute shares these with
# Atelier's interactive `agent-enter` containers by design, so the property
# that matters is not which flag is spelled but this: after a Meute run, a
# container that mounts the same volume with NO relabel flag can still read
# it. Private relabel (:Z) passes every single-run check and fails this one,
# which is why it went unnoticed -- a run always relabels successfully and
# then works. The failure it causes is an intermittent "not logged in" that
# looks exactly like the refresh-token collision §5 item 3 is watching for.
test_p2b_credential_volume_is_shared() {
  if ! p2_image_present; then
    skip "volume: shared after use" "${P2_IMAGE} is not on this host (expected in CI)"
    return 0
  fi
  local vol="meute-test-shared-$$"
  local -a podman; read -ra podman <<< "$( source "$REPO/lib/container.sh"; podman_cmd )"
  "${podman[@]}" volume create "$vol" >/dev/null 2>&1 \
    || { skip "volume: shared after use" "cannot create a podman volume here"; return 0; }
  # Seed it the way `just auth` does, then hand it to a run the way
  # container_argv would -- taking the flag from the code, not from a literal.
  local mount; mount="$( source "$REPO/lib/container.sh"; container_auth_mount claude )"
  local flag="${mount##*:}"
  "${podman[@]}" run --rm --userns=keep-id:uid=1000,gid=1000 --cap-drop=ALL --network=none \
    -v "${vol}:/seed:z" "$P2_IMAGE" sh -c 'printf secret > /seed/.credentials.json' >/dev/null 2>&1
  "${podman[@]}" run --rm --userns=keep-id:uid=1000,gid=1000 --cap-drop=ALL --network=none \
    -v "${vol}:/home/agent/.claude:${flag}" "$P2_IMAGE" \
    sh -c 'cat /home/agent/.claude/.credentials.json >/dev/null' >/dev/null 2>&1 \
    && ok "volume: the run reads its own credential" \
    || bad "volume: the run reads its own credential" "denied with flag ${flag}"
  # The assertion that :Z fails: somebody else's container, afterwards.
  local second
  second="$("${podman[@]}" run --rm --userns=keep-id:uid=1000,gid=1000 --cap-drop=ALL --network=none \
    -v "${vol}:/home/agent/.claude" "$P2_IMAGE" \
    sh -c 'cat /home/agent/.claude/.credentials.json 2>/dev/null || echo DENIED' 2>&1)"
  is "volume: ...and leaves it readable by the next container" "$second" "secret"
  "${podman[@]}" volume rm "$vol" >/dev/null 2>&1 || true

  # And the fix must not be over-applied: the per-run trees are private, and
  # private relabel is exactly right for them.
  local root="$FIXTURE/p2b-vol"; mkdir -p "$root/stub" "$root/work" "$root/out"
  cat > "$root/stub/podman" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"image inspect"*) printf '%s %s\n' "$P2_DIGEST" "$P2_ID" ;;
  *) printf '10.89.14.10\n' ;;
esac
STUB
  chmod +x "$root/stub/podman"
  local argv
  argv="$( source "$REPO/lib/container.sh"
           export MEUTE_PODMAN="$root/stub/podman"
           local e; e="$(jq -cn --arg tag "$P2_IMAGE" --arg digest "$P2_DIGEST" \
             '{repo:"alpha", image:{tag:$tag, digest:$digest}, network:"none",
               engine:"claude", writes_code:true, timeout_seconds:60}')"
           container_ready "$e" >/dev/null 2>&1
           container_argv "$e" build claude "$root/work" "$root/out" -- true
           printf '%s\n' "${CONTAINER_ARGV[@]}" | tr '\n' ' ' )"
  has "volume: the scratch tree stays privately labelled" "$argv" "${root}/work:/work:Z"
  has "volume: ...and so does the capture tree"           "$argv" "${root}/out:/out:Z"
}

# --engine is the one input that can make the effective engine differ from
# the entry's. The credential mount has to follow the engine that actually
# RUNS, or an override puts one provider's agent in front of the other's
# OAuth credential -- and in a writing container that agent holds
# danger-full-access over it. The sandbox ruling was conditioned on one
# credential per stage; this is the way that inverts.
test_p2b_engine_override_credential() {
  local root="$FIXTURE/p2b-override"; p4_fixture "$root"
  ln -sfn "$REPO/lib" "$root/lib"; ln -sfn "$REPO/bin" "$root/bin"; ln -sfn "$REPO/contrib" "$root/contrib"
  mkdir -p "$root/stub"
  cat > "$root/stub/podman" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$root/stub/podman-calls"
case "\$*" in
  *"image inspect"*) printf '%s %s\n' "$P4_DIGEST" "$P2_ID" ;;
  *"{{.State.Running}}"*) printf 'true\n' ;;
  *"NetworkSettings"*) printf '10.89.14.10\n' ;;
  *"claude auth status"*) printf '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}\n' ;;
  *"codex login status"*) printf 'Logged in using ChatGPT\n' ;;
  *" -p "*) printf '{"is_error":false,"result":"## Summary ran","total_cost_usd":0.01,"num_turns":1}\n' ;;
  *"codex exec"*) for a in "\$@"; do [[ -n "\${want:-}" ]] && { printf '## Summary ran\n' > "\$a"; unset want; }; [[ "\$a" == "-o" ]] && want=1; done ;;
  *) exit 125 ;;
esac
STUB
  chmod +x "$root/stub/podman"
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" \
    "d['repos'][0]['tasks'] = ['audit-security']; d['repos'][0]['tickets'] = []; d['community'] = []"
  local run; run() { : > "$root/stub/podman-calls"; : > "$root/state/cursor"
    PATH="$root/stub:$PATH" MEUTE_PODMAN="$root/stub/podman" MEUTE_QUOTA_STUB=100 \
      MEUTE_CODEX_QUOTA_CMD='echo 100' "$root/bin/run.sh" daily --repo netlens "$@" 2>&1; }

  # The manifest says claude. Untouched, it is claude's volume and no other.
  local out; out="$(run)"
  has   "override: the entry's own engine mounts its own credential" \
        "$(cat "$root/stub/podman-calls")" "atelier-auth-claude"
  hasnt "override: ...and not the other engine's" \
        "$(cat "$root/stub/podman-calls")" "atelier-auth-codex"

  # --engine codex on a claude entry: codex runs, so codex's credential is
  # the only one that may be in front of it.
  out="$(run --engine codex)"
  local calls; calls="$(cat "$root/stub/podman-calls")"
  has   "override: --engine codex mounts the codex credential" "$calls" "atelier-auth-codex"
  hasnt "override: ...and never claude's"                      "$calls" "atelier-auth-claude"
  has   "override: ...and it is codex that is probed"          "$calls" "codex login status"
  hasnt "override: ...not the engine the entry named"          "$calls" "claude auth status"

  # And the reverse, so the fix is not one-directional.
  yaml_edit "$root/repos.yaml" "$root/repos.yaml" "d['repos'][0]['engine'] = 'codex'"
  out="$(run --engine claude)"
  calls="$(cat "$root/stub/podman-calls")"
  has   "override: --engine claude on a codex entry mounts claude's" "$calls" "atelier-auth-claude"
  hasnt "override: ...and never codex's"                             "$calls" "atelier-auth-codex"

  # The invariant that keeps this fixed is these assertions, not a grep for
  # a spelling. There WAS such a grep here -- `jq -r '.engine` counted in
  # lib/container.sh, asserted zero -- and it is gone on purpose, so if the
  # instinct to "restore it, it is only one line" arrives, this is the
  # answer: it passes for `jq '.engine'`, for `. as $e | .engine`, and for
  # any helper that reads the field, while the property it claims to guard
  # is broken. A check that is cheap to write and hard to trust is worse
  # than no check, because it occupies the space where a real one would go
  # and makes that space look filled. The override tests above exercise the
  # property in both directions and fail when it breaks; a bash test parsing
  # bash would be a weaker guard sitting next to a stronger one.

  # And the two are bound rather than trusted to agree: the credential is
  # chosen from the engine parameter while the command comes from the
  # caller's argv, so a mismatch between them is refused outright.
  # The claim is made by the builder and checked by the mount, so it does
  # not matter how the command is spelled. A check that pattern-matched
  # argv[0] would pass for every line below while the property is violated,
  # and would start doing so the first time someone pins the binary by path
  # or prefixes an env var -- a change that would look entirely innocent.
  local mismatch rc
  refuse() { # <declared-engine> <mounting-for> <command...>
    ( source "$REPO/lib/engines.sh"; source "$REPO/lib/container.sh"
      export MEUTE_PODMAN="$root/stub/podman"
      local e; e="$(jq -cn --arg tag "$P2_IMAGE" --arg digest "$P4_DIGEST" \
        '{repo:"netlens", image:{tag:$tag, digest:$digest}, network:"none",
          writes_code:true, timeout_seconds:60}')"
      container_ready "$e" >/dev/null 2>&1
      ENGINE_ARGV_ENGINE="$1"; local for_engine="$2"; shift 2
      container_argv "$e" build "$for_engine" "$root" "$root" -- "$@" 2>&1 )
  }
  mismatch="$(refuse claude codex claude -p hello)"; rc=$?
  is  "override: a credential that does not match the command is refused" "$rc" "1"
  has "override: ...and says which two disagree"                          "$mismatch" "codex"
  has "override: ...naming the command's engine too"                      "$mismatch" "claude"
  # The spellings a pattern match would have missed entirely.
  mismatch="$(refuse claude codex /usr/local/bin/claude -p hello)"; rc=$?
  is "override: an absolute path is still bound to its engine"   "$rc" "1"
  mismatch="$(refuse claude codex env FOO=1 claude -p hello)"; rc=$?
  is "override: an env-prefixed command too"                     "$rc" "1"
  mismatch="$(refuse codex claude /opt/codex/bin/codex exec x)"; rc=$?
  is "override: and the same in the other direction"             "$rc" "1"
  # A matching declaration still builds, however the command is spelled.
  refuse claude claude /usr/local/bin/claude -p hello >/dev/null 2>&1 \
    && ok "override: a matching declaration builds, path or not" \
    || bad "override: a matching declaration builds, path or not" "refused its own engine"
  # The builders are what make the claim, so it is theirs to declare.
  is "override: the claude builder declares what it built" \
     "$( source "$REPO/lib/engines.sh"
         MODEL=s TOOLS=Read PERMISSION_MODE=dontAsk ALLOWED_TOOLS= MEUTE_SETTING_SOURCES= \
           engine_argv_claude "$root/../p2-engine/prompt" >/dev/null 2>&1
         printf '%s\n' "${ENGINE_ARGV_ENGINE:-unset}" )" "claude"
  is "override: ...and the codex builder likewise" \
     "$( source "$REPO/lib/engines.sh"
         WRITES_CODE=0 MEUTE_CODEX_MODEL= \
           engine_argv_codex "$root/../p2-engine/prompt" /work /out/last host >/dev/null 2>&1
         printf '%s\n' "${ENGINE_ARGV_ENGINE:-unset}" )" "codex"
}

# ------------------------------------------------------------------- main ---
printf 'meute test suite\n'
REAL_STATE_BEFORE="$(real_state_snapshot)"
setup
test_summaries
test_listing
test_show_marks_read
test_promote
test_cap
test_dismiss_and_edges
test_resolve
test_community_gates
test_quota_gate
test_runner_uses_selected_engine_quota
test_mixed_engine_quota
test_help
test_doctor
test_unit_path_line
test_dedup_dirs
test_timer_arming
test_install_timers
test_pause
test_hold_extend
test_engines
test_self_budget
test_manifest_ceiling
test_subscription_gate
test_two_gates
test_worktree_files
test_web_bind_guard
test_branch_prune
test_finding_level_triage
test_public_manifest_valid
test_binary_probe_allowlisted
test_architecture_review_queued
test_market_comparison_queued
test_findings_are_content_driven
test_suggest_features_queued
test_add_repo
test_discover
test_plan_state_ignored
test_private_manifest_copies_ignored
test_tier_tools_must_be_string
test_plan_tier_class
test_plan_identity
test_plan_worktrees
test_plan
test_plan_run
test_repo_default_branch
test_inbox
test_p4_example_validates
test_p4_rule1_image_required
test_p4_rule2_network_tier_only
test_p4_rule3_push_repos_only
test_p4_rule4_auto_merge
test_p4_rule5_cli_runtime_fails_closed
test_p4_rule6_ticket_engine
test_p4_rule7_stage_entries
test_p4_rule8_tag_format
test_p4_rule9_push_needs_repo
test_p4_stage_entry_cap_and_abort
test_p4_log_columns
test_p4_image_bump
test_doctor_manifest_ignored
test_p4_doctor_containers
test_p2_container_argv
test_p2_engine_argv
test_p2_scratch_clone
test_p2_scratch_import
test_p2_fail_closed
test_p2_step_over
test_p2_forced_refusal_is_retryable
test_p2_engine_cwd
test_p2_outer_bound
test_p2_pin_is_one_snapshot
test_p2_isolation
test_p2_proxied_egress
test_p2_container_probe
test_p2b_container_dispatch
test_p2b_preflight
test_p2b_credential_volume_is_shared
test_p2b_engine_override_credential
test_p2_probe_cleanup
test_real_repo_untouched
printf '\n%s passed, %s failed\n' "$PASS" "$FAILED"
(( FAILED == 0 ))
