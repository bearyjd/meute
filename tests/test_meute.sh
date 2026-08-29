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

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAILED=0
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

ok()   { printf '  ok    %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAILED=$(( FAILED + 1 )); }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$3], got [$2]"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "[$2] does not contain [$3]"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "[$2] unexpectedly contains [$3]"; }

meute() { "$FIXTURE/bin/meute" "$@"; }
report() { python3 "$REPO/lib/report.py" "$@"; }

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
        "tier1": {"tools": "Read", "permission_mode": "acceptEdits", "writes_code": True},
        "tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False},
        "tier3": {"tools": "Read", "permission_mode": "acceptEdits", "writes_code": True},
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
  is  "reports: 4 unread"         "$(meute reports --new 2>/dev/null | grep -c '^NEW')" "4"
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
  meute promote alpha/audit-security-2026-08-28 -f 1 >/dev/null 2>&1
  after="$(md5sum "$FIXTURE/repos.yaml" | cut -d' ' -f1)"
  is "promote: repos.yaml never written" "$after" "$before"

  ticket="$(python3 -c "
import yaml; d = yaml.safe_load(open('$FIXTURE/state/tickets.yaml'))
t = d['tickets']['alpha'][0]; print(t['id'], t['specced'], t['source'])")"
  is  "promote: ticket id derived"  "$(cut -d' ' -f1 <<< "$ticket")" "AL-1"
  is  "promote: specced is true"    "$(cut -d' ' -f2 <<< "$ticket")" "True"
  has "promote: records its source" "$ticket" "alpha/audit-security-2026-08-28"
  has "promote: report is actioned" "$(meute reports --all 2>/dev/null | grep '2026-08-28')" "actioned"

  local queued
  queued="$(MEUTE_ROOT="$FIXTURE" python3 "$REPO/lib/manifest.py" queue "$FIXTURE/repos.yaml" weekly \
            | jq -r 'select(.tier=="tier3") | .key')"
  is "promote: ticket reaches the tier-3 queue" "$queued" "alpha/draft-ticket/AL-1"

  is "promote: bad finding number fails" \
     "$(meute promote alpha/audit-security-2026-08-28 -f 99 >/dev/null 2>&1; echo $?)" "1"
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
  meute dismiss beta/gen-tests-2026-08-27 -m "not worth it" >/dev/null 2>&1
  has "dismiss: state recorded" "$(meute reports --all 2>/dev/null | grep 'gen-tests        2026-08-27')" "dismissed"
  has "dismiss: reason kept"    "$(cat "$FIXTURE/state/reports")" "not worth it"

  rm "$FIXTURE/reports/alpha/audit-security-2026-08-20.md"
  local out; out="$(meute reports --all 2>&1)"
  hasnt "stale row for a deleted report is skipped" "$out" "2026-08-20"

  has "status: runs without error" "$(meute status 2>&1)" "tier-3 in flight"
  is  "unknown command exits 1"    "$(meute frobnicate >/dev/null 2>&1; echo $?)" "1"
}

# Compares against a snapshot taken before the suite ran, rather than demanding a
# clean tree: the operator may legitimately have uncommitted state, and this must
# still catch the suite itself writing outside its fixture.
test_real_repo_untouched() {
  local now; now="$(git -C "$REPO" status --porcelain -- state reports | sort | tr -d ' \n')"
  is "the real state/ and reports/ were never touched" "$now" "$REAL_STATE_BEFORE"
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
        "tier1": {"tools": "Read", "permission_mode": "acceptEdits", "writes_code": True},
        "tier2-scout": {"tools": "Read,Bash", "permission_mode": "dontAsk", "writes_code": False},
        "tier3": {"tools": "Read", "permission_mode": "acceptEdits", "writes_code": True},
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
  out="$(MEUTE_QUOTA_STUB=55 "$REPO/bin/quota.sh")"
  is "quota: stub value is reported" "$out" "55"

  out="$(MEUTE_QUOTA_STUB=55 "$REPO/bin/quota.sh" --with-source)"
  is "quota: --with-source names the source" "$out" "55 stub"

  out="$(MEUTE_QUOTA_CMD='echo 42' "$REPO/bin/quota.sh" --with-source)"
  is "quota: configured probe wins" "$out" "42 MEUTE_QUOTA_CMD"

  # the safety property: a configured probe that fails must NOT fall back
  MEUTE_QUOTA_CMD='exit 3' "$REPO/bin/quota.sh" >/dev/null 2>&1; rc=$?
  is "quota: broken probe fails closed, never falls back to the stub" "$rc" "1"

  out="$(MEUTE_QUOTA_CMD='exit 3' "$REPO/bin/quota.sh" 2>&1 || true)"
  hasnt "quota: broken probe emits no number at all" "$out" "100"

  # non-numeric output is a broken source too
  MEUTE_QUOTA_CMD='echo banana' "$REPO/bin/quota.sh" >/dev/null 2>&1; rc=$?
  is "quota: non-numeric probe output is rejected" "$rc" "1"

  MEUTE_QUOTA_CMD='echo 250' "$REPO/bin/quota.sh" >/dev/null 2>&1; rc=$?
  is "quota: out-of-range probe output is rejected" "$rc" "1"

  # the adapter must fail cleanly when its backend is absent
  LUT_URL='http://127.0.0.1:9' "$REPO/contrib/quota-llm-usage-tracker.sh" >/dev/null 2>&1; rc=$?
  is "quota: llm-usage-tracker adapter fails closed when unreachable" "$rc" "1"
}


test_doctor() {
  local out rc
  out="$(meute doctor 2>&1)"; rc=$?
  is  "doctor: exits 0 on a healthy checkout" "$rc" "0"
  has "doctor: checks binaries"               "$out" "binaries"
  has "doctor: probes auth"                   "$out" "auth"
  has "doctor: reports the quota source"      "$out" "quota gate"
  has "doctor: emits a crontab block"         "$out" "crontab -e"
  has "doctor: the block sets PATH"           "$out" "PATH="
  has "doctor: warns an unwired quota gate"   "$out" "does NOT fire"
}

# ------------------------------------------------------------------- main ---
printf 'meute test suite\n'
REAL_STATE_BEFORE="$(git -C "$REPO" status --porcelain -- state reports | sort | tr -d ' \n')"
setup
test_summaries
test_listing
test_show_marks_read
test_promote
test_cap
test_dismiss_and_edges
test_community_gates
test_quota_gate
test_doctor
test_real_repo_untouched
printf '\n%s passed, %s failed\n' "$PASS" "$FAILED"
(( FAILED == 0 ))
