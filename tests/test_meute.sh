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
  is  "reports: 5 unread"         "$(meute reports --new 2>/dev/null | grep -c '^NEW')" "5"
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
  out="$(MEUTE_QUOTA_STUB=55 "$REPO/bin/quota.sh")"
  is "quota: stub value is reported" "$out" "55"

  out="$(MEUTE_QUOTA_STUB=55 "$REPO/bin/quota.sh" --with-source)"
  is "quota: --with-source names the source" "$out" "55 stub"

  out="$(MEUTE_QUOTA_CMD='echo 42' "$REPO/bin/quota.sh" --with-source)"
  # The source is the probe's basename, not the variable name: state/log should
  # say WHICH probe answered (quota-self-budget.sh vs a real pool reader).
  is "quota: configured probe wins, named by its command" "$out" "42 echo"

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

  # The default used to be :8000 -- plausible, and wrong: the tracker's own
  # `serve` command (backend/cli.py) binds :48372. Pin it against the error
  # message rather than the source line, so a future edit that changes the
  # literal without checking it against the tracker's real default still fails
  # this test instead of silently drifting again.
  local out
  out="$(env -u LUT_URL "$REPO/contrib/quota-llm-usage-tracker.sh" 2>&1 || true)"
  has "quota: llm-usage-tracker adapter defaults to the tracker's real port" "$out" "127.0.0.1:48372"
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
  has "doctor: warns an unwired quota gate"   "$out" "does NOT fire"
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

  install_with() {
    HOME="$home" PATH="$stub:$PATH" STUB_SHOW="$1" \
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
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False}},
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
    "tiers": {"tier2": {"tools": "Read", "permission_mode": "dontAsk", "writes_code": False}},
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
test_unit_path_line
test_dedup_dirs
test_timer_arming
test_install_timers
test_pause
test_hold_extend
test_engines
test_self_budget
test_manifest_ceiling
test_branch_prune
test_finding_level_triage
test_real_repo_untouched
printf '\n%s passed, %s failed\n' "$PASS" "$FAILED"
(( FAILED == 0 ))
