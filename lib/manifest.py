#!/usr/bin/env python3
"""Manifest reader for the meute fleet runner.

bin/run.sh shells out to this for anything that needs real YAML parsing.
Everything it prints is either JSON or JSON Lines so the caller can consume it
with jq instead of splitting fields by hand.

Subcommands
    validate <manifest>              -- schema check; exit 2 and explain on failure
    policy   <manifest>              -- policy block as a single JSON object
    queue    <manifest> <slot>       -- candidate work items, one JSON object per line
    plan-queue <manifest> <file> <slot>
                                      -- validated, read-only entries staged by `meute plan --enqueue`
    render   <template> KEY=VAL ...  -- substitute {{KEY}} placeholders, print to stdout
    list-repos <manifest>            -- name+path for every repo, one JSON object per line
    list-tasks <manifest>            -- name+tier+writes_code+tools+plan_class for every task,
                                        one JSON object per line
    list-images <manifest>           -- runtime+image tag+digest for every repo, one JSON
                                        object per line; unvalidated on purpose
    add-repo <manifest> <json>       -- append a repo; refuses to write repos.yaml
    set-image-digest <manifest> <repo> <digest>
                                     -- pin a repo's image.digest; refuses to write repos.yaml

The queue is *candidates only*. Gating that depends on live repo state (weekly
community share, tier-3 in-flight cap, cursor position) belongs to run.sh.
"""

from __future__ import annotations

import datetime
import json
import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - environment problem, not a data problem
    sys.exit("meute: PyYAML is required (pip install --user PyYAML)")

SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
VALID_SLOTS = ("daily", "weekly")
REQUIRED_TIER_KEYS = ("tools", "permission_mode", "writes_code")

# PRP-004 s4.1. Where a run executes, and what a tier's container may reach.
# `network` is a tier key and nothing else's: the blast radius of a task is
# the tier's to state, and a repo or ticket must not be able to widen it.
VALID_RUNTIMES = ("host", "container")
VALID_NETWORKS = ("none", "proxied")
VALID_ENGINES = ("claude", "codex")
# Atelier's immutable tag for this repo's overlay image, or the shared base
# image when the repo has no overlay. Anything else -- `latest`, a registry
# prefix, another project's overlay -- is not a pin.
IMAGE_TAG = re.compile(r"^agent-([A-Za-z0-9._-]+):g[0-9a-f]+$")
IMAGE_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
# The owner's GitHub repository, `owner/name`. It is the only source of the
# push URL and the `-R` for gh; nothing derives it from `git remote`.
OWNER_REPO = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")

# state/stages rows (PRP-004 s4.3): a tier-3 ticket advances one stage per
# fire. `preflight` and `build` appear in state/log's stage= column only; a
# row exists once a build has committed, so its stage is one of these.
ROW_STAGES = ("review", "resolve", "review-2", "publish", "done")
STAGES_COLUMNS = ("stage", "branch", "base", "build_report", "engine")
# A branch is reviewed by the engine that did not write it.
OTHER_ENGINE = {"claude": "codex", "codex": "claude"}

POLICY_DEFAULTS = {
    "quota_floor_percent": 30,
    "weekly_runs": None,
    "weekly_cost_usd": None,
    "community_share": 0.20,
    "tier3_max_in_flight": 3,
    "branch_prefix": "meute",
    # systemd OnCalendar strings. One item runs per fire, so cadence is the
    # lever that turns "fleet coverage" into "how often each repo is seen".
    "daily_calendar": "*-*-* 03:17:00",
    "weekly_calendar": "Sat *-*-* 04:41:00",
}

ENTRY_DEFAULTS = {
    "engine": "claude",
    "model": "sonnet",
    "file_budget": 25,
    "timeout_seconds": 1800,
    "runtime": "host",
}


class ManifestError(Exception):
    """Raised for any manifest content the runner refuses to act on."""


def expand(path: str) -> str:
    return os.path.abspath(os.path.expanduser(os.path.expandvars(path)))


def repo_root(manifest: str) -> str:
    """Templates live in the meute checkout, not next to the manifest."""
    return os.environ.get("MEUTE_ROOT") or os.path.dirname(os.path.abspath(manifest))


def load(path: str) -> dict:
    if not os.path.isfile(path):
        raise ManifestError(f"manifest not found: {path}")
    with open(path, "r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    if data is None:
        raise ManifestError(f"manifest is empty: {path}")
    if not isinstance(data, dict):
        raise ManifestError("manifest root must be a mapping")
    if data.get("version") != 1:
        raise ManifestError(f"unsupported manifest version: {data.get('version')!r} (expected 1)")
    return data


def merged_policy(data: dict) -> dict:
    policy = dict(POLICY_DEFAULTS)
    supplied = data.get("policy") or {}
    if not isinstance(supplied, dict):
        raise ManifestError("policy: must be a mapping")
    policy.update(supplied)
    floor = policy["quota_floor_percent"]
    if not isinstance(floor, int) or not 0 <= floor <= 100:
        raise ManifestError("policy.quota_floor_percent: must be an integer 0-100")
    share = policy["community_share"]
    if not isinstance(share, (int, float)) or not 0.0 <= float(share) <= 1.0:
        raise ManifestError("policy.community_share: must be a number 0.0-1.0")
    cap = policy["tier3_max_in_flight"]
    if not isinstance(cap, int) or cap < 0:
        raise ManifestError("policy.tier3_max_in_flight: must be a non-negative integer")
    runs, cost = policy["weekly_runs"], policy["weekly_cost_usd"]
    if runs is not None and cost is not None:
        raise ManifestError(
            "policy: set weekly_runs or weekly_cost_usd, not both - "
            "two ceilings means neither is the ceiling")
    if runs is not None and (not isinstance(runs, int) or runs < 1):
        raise ManifestError("policy.weekly_runs: must be a positive integer")
    if cost is not None and (not isinstance(cost, (int, float)) or float(cost) <= 0):
        raise ManifestError("policy.weekly_cost_usd: must be a positive number")
    if not SAFE_NAME.match(str(policy["branch_prefix"])):
        raise ManifestError("policy.branch_prefix: must be a safe identifier")
    for key in ("daily_calendar", "weekly_calendar"):
        value = policy[key]
        # Validated for shape only; systemd is the authority on the grammar,
        # and install-timers runs `systemd-analyze calendar` on it.
        if not isinstance(value, str) or not value.strip() or "\n" in value:
            raise ManifestError(f"policy.{key}: must be a one-line systemd OnCalendar string")
    return policy


def merged_defaults(data: dict) -> dict:
    defaults = dict(ENTRY_DEFAULTS)
    supplied = data.get("defaults") or {}
    if not isinstance(supplied, dict):
        raise ManifestError("defaults: must be a mapping")
    defaults.update(supplied)
    if defaults["engine"] not in VALID_ENGINES:
        raise ManifestError("defaults.engine: must be 'claude' or 'codex'")
    if defaults["runtime"] not in VALID_RUNTIMES:
        raise ManifestError("defaults.runtime: must be 'host' or 'container'")
    return defaults


def checked_tiers(data: dict) -> dict:
    tiers = data.get("tiers")
    if not isinstance(tiers, dict) or not tiers:
        raise ManifestError("tiers: at least one tier must be declared")
    for name, tier in tiers.items():
        if not isinstance(tier, dict):
            raise ManifestError(f"tiers.{name}: must be a mapping")
        missing = [key for key in REQUIRED_TIER_KEYS if key not in tier]
        if missing:
            raise ManifestError(f"tiers.{name}: missing {', '.join(missing)}")
        if not isinstance(tier["writes_code"], bool):
            raise ManifestError(f"tiers.{name}.writes_code: must be true or false")
        # The web gate splits this on commas; a YAML list would read as "no
        # web tools" and wave a web tier through a plan that never allowed one.
        if not isinstance(tier["tools"], str):
            raise ManifestError(f"tiers.{name}.tools: must be a comma-separated string")
        checked_tier_network(name, tier)
    return tiers


def checked_tier_network(name: str, tier: dict) -> None:
    """Every tier states its egress, so a new tier cannot inherit one by omission.

    The one exception is a tier pinned to the host (tier2-web: WebFetch's
    domain wildcard cannot be expressed as a CONNECT allow-list), and there
    `network` means nothing -- a host run has the host's network -- so
    stating one is refused rather than ignored.
    """
    if "runtime" in tier and tier["runtime"] != "host":
        raise ManifestError(f"tiers.{name}.runtime: only 'host' may be set on a tier")
    if tier.get("runtime") == "host":
        if "network" in tier:
            raise ManifestError(f"tiers.{name}.network: meaningless on a runtime: host tier")
        return
    if "network" not in tier:
        raise ManifestError(
            f"tiers.{name}.network: required (none or proxied) unless the tier is runtime: host")
    if tier["network"] not in VALID_NETWORKS:
        raise ManifestError(f"tiers.{name}.network: must be 'none' or 'proxied'")


# What `meute plan` may stage against a never-enrolled repository, decided by
# the tier's tool list alone. "local" reads the checkout and nothing else.
# "web" also reaches the public internet -- it sends what it learned about a
# repository to third parties, so it is an explicit opt-in (--allow-web), never
# a default. Anything else is "other": Bash, Edit, an MCP server, a tool this
# file has never heard of. Those come with allowlists an operator reviewed for
# an enrolled project, so enrollment is the path and no plan flag opens it.
LOCAL_TOOLS = frozenset({"Read", "Grep", "Glob"})
WEB_TOOLS = frozenset({"WebSearch", "WebFetch"})


def tool_names(tools: str) -> frozenset:
    """Bare tool names from a comma-separated `tools` string.

    Compared by the prefix before "(", the CLI's own allowlist grammar, so
    `WebFetch(domain:x)` is WebFetch and not an unknown tool.
    """
    return frozenset(tool.strip().split("(", 1)[0].strip()
                     for tool in tools.split(",") if tool.strip())


def plan_tier_class(tier: dict) -> str:
    """local | web | other. Only for tiers that passed checked_tiers."""
    names = tool_names(tier["tools"])
    if names <= LOCAL_TOOLS:
        return "local"
    if names <= LOCAL_TOOLS | WEB_TOOLS:
        return "web"
    return "other"


def checked_tasks(data: dict, tiers: dict, root: str) -> dict:
    tasks = data.get("tasks")
    if not isinstance(tasks, dict) or not tasks:
        raise ManifestError("tasks: at least one task must be declared")
    for name, task in tasks.items():
        if not SAFE_NAME.match(name):
            raise ManifestError(f"tasks.{name}: name must match {SAFE_NAME.pattern}")
        if not isinstance(task, dict):
            raise ManifestError(f"tasks.{name}: must be a mapping")
        if task.get("tier") not in tiers:
            raise ManifestError(f"tasks.{name}.tier: unknown tier {task.get('tier')!r}")
        template = task.get("template")
        if not template:
            raise ManifestError(f"tasks.{name}.template: required")
        if not os.path.isfile(os.path.join(root, template)):
            raise ManifestError(f"tasks.{name}.template: file not found: {template}")
        for slot in task.get("slots") or []:
            if slot not in VALID_SLOTS:
                raise ManifestError(f"tasks.{name}.slots: unknown slot {slot!r}")
        if "network" in task:
            raise ManifestError(f"tasks.{name}.network: network is a tier key only")
        # build_entry's setting() would honour this silently; the runtime is
        # a property of the repository being worked on, not of the chore.
        if "runtime" in task:
            raise ManifestError(
                f"tasks.{name}.runtime: runtime is set per repo or in defaults, not per task")
    return tasks


def checked_projects(data: dict, key: str, tasks: dict, root: str = "") -> list:
    projects = data.get(key) or []
    if not isinstance(projects, list):
        raise ManifestError(f"{key}: must be a list")
    defaults = merged_defaults(data)
    seen = set()
    for project in projects:
        if not isinstance(project, dict):
            raise ManifestError(f"{key}: each entry must be a mapping")
        name = project.get("name")
        if not name or not SAFE_NAME.match(str(name)):
            raise ManifestError(f"{key}: entry name {name!r} must match {SAFE_NAME.pattern}")
        if name in seen:
            raise ManifestError(f"{key}: duplicate entry name {name!r}")
        seen.add(name)
        if not project.get("path"):
            raise ManifestError(f"{key}.{name}.path: required")
        if not project.get("spec"):
            raise ManifestError(f"{key}.{name}.spec: required (one line, injected into prompts)")
        if key == "community":
            # PRP-001 s9: no etiquette file, no contribution. A hard gate, not a
            # warning -- contributing to someone else's project without knowing
            # their AI policy is how contributors get banned.
            etiquette = project.get("etiquette")
            if not etiquette:
                raise ManifestError(
                    f"community.{name}.etiquette: required - write "
                    f"etiquette/{name}.yaml before adding this project")
            if not os.path.isfile(os.path.join(root, etiquette)):
                raise ManifestError(f"community.{name}.etiquette: file not found: {etiquette}")
            if not project.get("repo"):
                raise ManifestError(f"community.{name}.repo: required (owner/name, for gh queries)")
        for task_name in project.get("tasks") or []:
            if task_name not in tasks:
                raise ManifestError(f"{key}.{name}.tasks: undeclared task {task_name!r}")
        for ticket in project.get("tickets") or []:
            if not isinstance(ticket, dict) or not ticket.get("id"):
                raise ManifestError(f"{key}.{name}.tickets: every ticket needs an id")
            checked_ticket(f"{key}.{name}.tickets[{ticket['id']}]", ticket)
        checked_container_fields(key, name, project, defaults)
        files = project.get("worktree_files") or []
        if not isinstance(files, list):
            raise ManifestError(f"{key}.{name}.worktree_files: must be a list of relative paths")
        for rel in files:
            # Copied from the main checkout into every worktree. Relative and
            # inside the tree only: this exists for gitignored build plumbing
            # like local.properties, not for reaching anywhere else.
            if not isinstance(rel, str) or not rel or rel.startswith("/") \
                    or ".." in rel.split("/"):
                raise ManifestError(
                    f"{key}.{name}.worktree_files: {rel!r} must be a relative path inside the repo")
    return projects


def checked_ticket(where: str, ticket: dict) -> None:
    """The build engine is the ticket's to choose; the review engine never is.

    It is derived as the other engine when the stage entry is built, because
    a branch reviewed by the engine that wrote it is not a review. A field
    for it would be a way to make that happen.
    """
    if "network" in ticket:
        raise ManifestError(f"{where}.network: network is a tier key only")
    if "review_engine" in ticket:
        raise ManifestError(
            f"{where}.review_engine: not a field - the review engine is derived from engine")
    if "engine" in ticket and ticket["engine"] not in VALID_ENGINES:
        raise ManifestError(f"{where}.engine: must be 'claude' or 'codex'")


def checked_container_fields(key: str, name: str, project: dict, defaults: dict) -> None:
    """PRP-004 s4.1 rules 1-4, 8, 9 for one repos:/community: entry."""
    where = f"{key}.{name}"
    if "runtime" in project and project["runtime"] not in VALID_RUNTIMES:
        raise ManifestError(f"{where}.runtime: must be 'host' or 'container'")
    if "network" in project:
        raise ManifestError(f"{where}.network: network is a tier key only")
    # Missing is an error, not a default: an image that was not pinned is a
    # run in whatever `podman` resolves the tag to today.
    runtime = project.get("runtime") or defaults["runtime"]
    image = project.get("image")
    if runtime == "container" and not isinstance(image, dict):
        raise ManifestError(
            f"{where}.image: tag and digest are required when runtime is container")
    if image is not None:
        checked_image(where, name, image, runtime)
    push = project.get("push", False)
    if not isinstance(push, bool):
        raise ManifestError(f"{where}.push: must be true or false")
    if push and key != "repos":
        raise ManifestError(f"{where}.push: only repos: entries may push")
    if project.get("auto_merge", False) is not False:
        raise ManifestError(
            f"{where}.auto_merge: true is not supported - a draft PR is where meute stops")
    if key == "repos" and "repo" in project and not OWNER_REPO.match(str(project["repo"])):
        raise ManifestError(f"{where}.repo: {project['repo']!r} must be owner/name")
    if push and not project.get("repo"):
        raise ManifestError(f"{where}.repo: required (owner/name) when push is true")


def checked_image(where: str, name: str, image: dict, runtime: str) -> None:
    """Both halves of the pin when a container needs it; each half's shape whenever present."""
    if not isinstance(image, dict):
        raise ManifestError(f"{where}.image: must be a mapping with tag and digest")
    for field in ("tag", "digest"):
        if runtime == "container" and not image.get(field):
            raise ManifestError(f"{where}.image.{field}: required when runtime is container")
    tag, digest = image.get("tag"), image.get("digest")
    if tag is not None:
        match = IMAGE_TAG.match(str(tag))
        if not match or match.group(1) not in (name, "base"):
            raise ManifestError(
                f"{where}.image.tag: {tag!r} must be agent-{name}:g<hex> or agent-base:g<hex>")
    if digest is not None and not IMAGE_DIGEST.match(str(digest)):
        raise ManifestError(f"{where}.image.digest: must match {IMAGE_DIGEST.pattern}")


def tickets_path(root: str) -> str:
    return os.path.join(root, "state", "tickets.yaml")


def load_machine_tickets(root: str) -> dict:
    """Tickets written by `meute promote`.

    These live in state/tickets.yaml rather than repos.yaml on purpose: PyYAML
    cannot round-trip a file without destroying its comments, and repos.yaml is
    mostly hand-written documentation. Machine-written state gets its own file.
    """
    path = tickets_path(root)
    if not os.path.isfile(path):
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    tickets = data.get("tickets") or {}
    if not isinstance(tickets, dict):
        raise ManifestError("state/tickets.yaml: 'tickets' must map repo name -> list")
    return tickets


def stages_path(root: str) -> str:
    return os.path.join(root, "state", "stages")


def load_stages(root: str) -> dict:
    """Where every in-flight tier-3 ticket stands, keyed `<repo>/<ticket>`.

    lib/state.sh kv_set_row format: the key, then STAGES_COLUMNS, tab-separated.
    Hand-written and machine-written tickets alike are looked up here; neither
    ticket source is touched to record progress. A row the builder cannot read
    stops the queue -- the alternative is guessing which stage to run.
    """
    path = stages_path(root)
    if not os.path.isfile(path):
        return {}
    rows = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            fields = line.split("\t")
            key = fields[0]
            if len(fields) != 1 + len(STAGES_COLUMNS):
                raise ManifestError(
                    f"state/stages: {key}: expected {', '.join(STAGES_COLUMNS)}")
            row = dict(zip(STAGES_COLUMNS, fields[1:]))
            if row["stage"] not in ROW_STAGES:
                raise ManifestError(f"state/stages: {key}: unknown stage {row['stage']!r}")
            if row["engine"] not in VALID_ENGINES:
                raise ManifestError(f"state/stages: {key}: engine must be claude or codex")
            rows[key] = row
    return rows


def with_machine_tickets(project: dict, machine: dict) -> dict:
    """Copy of `project` whose ticket list also carries the machine-written ones."""
    extra = machine.get(project["name"]) or []
    if not extra:
        return project
    own = list(project.get("tickets") or [])
    seen = {str(ticket.get("id")) for ticket in own}
    for ticket in extra:
        identifier = str(ticket.get("id"))
        if identifier in seen:
            raise ManifestError(
                f"ticket id {identifier!r} for {project['name']} exists in both "
                "repos.yaml and state/tickets.yaml - resolve the clash by hand")
        seen.add(identifier)
    return {**project, "tickets": own + list(extra)}


def derive_ticket_id(repo: str, existing: list) -> str:
    """<INITIALS>-<n>, continuing from the highest n already used for this repo."""
    parts = [p for p in re.split(r"[^A-Za-z0-9]+", repo) if p]
    initials = "".join(p[0] for p in parts[:2]).upper() if len(parts) > 1 else repo[:2].upper()
    highest = 0
    for ticket in existing:
        match = re.search(r"(\d+)$", str(ticket.get("id", "")))
        if match:
            highest = max(highest, int(match.group(1)))
    return f"{initials}-{highest + 1}"


def load_etiquette(root: str, project: dict) -> dict:
    """A community project's contribution policy. Absent file is a hard error."""
    rel = project.get("etiquette")
    if not rel:
        return {}
    path = os.path.join(root, rel)
    with open(path, "r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    if not isinstance(data, dict):
        raise ManifestError(f"{rel}: must be a mapping")
    policy = data.get("autonomous_agents", "allowed")
    if policy not in ("allowed", "banned"):
        raise ManifestError(f"{rel}.autonomous_agents: must be 'allowed' or 'banned'")
    return data


def bans_autonomous_agents(etiquette: dict) -> bool:
    """Some projects welcome AI-assisted work but forbid agent-authored contributions.

    ripgrep's AI_POLICY.md is the motivating case: 'Autonomous agents are not
    allowed to be used for contributing to this project.' Those are two separate
    axes, so `ai_policy` alone cannot express it. When agents are banned the
    project still permits read-only analysis, so scouting stays legal -- but
    nothing that authors a contribution may run.
    """
    return etiquette.get("autonomous_agents") == "banned"


def build_entry(kind: str, project: dict, task_name: str, task: dict,
                tier_name: str, tier: dict, defaults: dict, root: str) -> dict:
    """Flatten manifest layers into the single record run.sh consumes."""
    def setting(field):
        for source in (task, project, defaults):
            if field in source and source[field] is not None:
                return source[field]
        return None

    def allowlist():
        for source in (task, project, tier):
            if source.get("allowed_tools"):
                return source["allowed_tools"]
        return ""

    image = project.get("image") if isinstance(project.get("image"), dict) else None
    return {
        "kind": kind,
        "repo": project["name"],
        "path": expand(project["path"]),
        "spec": project["spec"],
        "default_branch": project.get("default_branch", ""),
        "upstream": project.get("repo", ""),
        "etiquette": project.get("etiquette", ""),
        "task": task_name,
        "tier": tier_name,
        "template": os.path.join(root, task["template"]),
        "tools": tier["tools"],
        "permission_mode": tier["permission_mode"],
        "allowed_tools": allowlist(),
        "writes_code": bool(tier["writes_code"]),
        "engine": setting("engine"),
        "model": setting("model"),
        "file_budget": setting("file_budget"),
        "timeout_seconds": setting("timeout_seconds"),
        "lenses": task.get("lenses") or [],
        "worktree_files": list(project.get("worktree_files") or []),
        # PRP-004: where this runs and in what. `network` is the tier's word
        # on egress and is empty for a host-pinned tier, which has the host's.
        "runtime": resolved_runtime(project, tier, defaults),
        "image": {"tag": str(image.get("tag", "")), "digest": str(image.get("digest", ""))}
                 if image else None,
        "network": tier.get("network", ""),
        "push": bool(project.get("push", False)),
        "stage_entry": False,
    }


def resolved_runtime(project: dict, tier: dict, defaults: dict) -> str:
    """host | container. A tier pinned to the host wins over the repo's choice."""
    if tier.get("runtime") == "host":
        return "host"
    return project.get("runtime") or defaults["runtime"]


def build_queue(data: dict, slot: str, root: str) -> list:
    """Personal repos first, community second - the 80/20 ordering is structural."""
    defaults = merged_defaults(data)
    tiers = checked_tiers(data)
    tasks = checked_tasks(data, tiers, root)
    entries = []
    machine = load_machine_tickets(root)
    stages = load_stages(root)
    for kind, key in (("personal", "repos"), ("community", "community")):
        for project in checked_projects(data, key, tasks, root):
            project = with_machine_tickets(project, machine)
            etiquette = load_etiquette(root, project) if kind == "community" else {}
            # A ticket mid-pipeline goes ahead of the repo's new work: its
            # branch is already one of the counted ones, and finishing it is
            # what frees the slot.
            in_flight, fresh = [], []
            for task_name in project.get("tasks") or []:
                task = tasks[task_name]
                slots = task.get("slots") or list(VALID_SLOTS)
                if slot not in slots:
                    continue
                tier_name = task["tier"]
                # Enforced here, not asked of the model: a project that bans
                # autonomous agents never gets a contribution-authoring task in
                # the queue at all.
                if bans_autonomous_agents(etiquette) and tiers[tier_name]["writes_code"]:
                    continue
                entry = build_entry(kind, project, task_name, task, tier_name,
                                    tiers[tier_name], defaults, root)
                if task.get("requires_specced_ticket"):
                    for item in expand_tickets(entry, project, stages, want_specced=True):
                        (in_flight if item["stage_entry"] else fresh).append(item)
                elif task.get("requires_candidate_ticket"):
                    fresh.extend(expand_tickets(entry, project, stages, want_specced=False))
                else:
                    fresh.append({**entry, "key": f"{entry['repo']}/{task_name}",
                                  "ticket_id": "", "ticket_title": "", "ticket_notes": ""})
            entries.extend(in_flight + fresh)
    return entries


def build_plan_queue(data: dict, path: str, slot: str, root: str) -> list:
    """Expand the explicit, machine-owned portfolio plan into runner entries.

    The plan file deliberately contains only repo paths, safe synthetic names,
    and task names.  All executable settings still come from the manifest, and
    this boundary refuses every writing tier even if someone edits state by
    hand.  It is therefore safe for the normal scheduler to prefer a staged
    plan without enrolling those repositories in repos.local.yaml.
    """
    if not os.path.isfile(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            staged = json.load(handle)
    except json.JSONDecodeError as error:
        raise ManifestError(f"{path}: invalid plan queue JSON: {error.msg}") from error
    if not isinstance(staged, dict) or staged.get("version") != 1:
        raise ManifestError(f"{path}: expected plan queue version 1")
    declarations = staged.get("entries")
    if not isinstance(declarations, list):
        raise ManifestError(f"{path}: entries must be a list")
    allow_web = staged.get("allow_web", False)
    if not isinstance(allow_web, bool):
        raise ManifestError(f"{path}: allow_web must be true or false")

    defaults = merged_defaults(data)
    tiers = checked_tiers(data)
    tasks = checked_tasks(data, tiers, root)
    # A portfolio plan normally stages several read-only lenses for the same
    # discovered repository.  The executable identity is (synthetic name,
    # task), not the repository name alone; reject only duplicate identities
    # so an accidental repeated work item cannot run twice.
    entries, keys = [], set()
    for number, declared in enumerate(declarations, start=1):
        if not isinstance(declared, dict):
            raise ManifestError(f"{path}: entries[{number}] must be a mapping")
        name, repo_path, task_name = declared.get("name"), declared.get("path"), declared.get("task")
        if not isinstance(name, str) or not SAFE_NAME.match(name):
            raise ManifestError(f"{path}: entries[{number}].name must be a safe identifier")
        if not isinstance(repo_path, str) or not os.path.isabs(repo_path):
            raise ManifestError(f"{path}: entries[{number}].path must be an absolute path")
        if not isinstance(task_name, str) or task_name not in tasks:
            raise ManifestError(f"{path}: entries[{number}].task is not declared: {task_name!r}")
        key = f"plan/{name}/{task_name}"
        if key in keys:
            raise ManifestError(f"{path}: duplicate staged entry key {key!r}")
        keys.add(key)
        task = tasks[task_name]
        tier_name = task["tier"]
        if tiers[tier_name]["writes_code"]:
            raise ManifestError(
                f"{path}: entries[{number}].task {task_name!r} writes code and cannot be staged")
        tier_class = plan_tier_class(tiers[tier_name])
        if tier_class == "other":
            raise ManifestError(
                f"{path}: entries[{number}].task {task_name!r} uses tools plan cannot stage")
        if tier_class == "web" and not allow_web:
            raise ManifestError(
                f"{path}: entries[{number}].task {task_name!r} uses web tools and the plan did not allow them")
        if slot != "all" and slot not in (task.get("slots") or list(VALID_SLOTS)):
            continue
        spec = declared.get("spec") or "Unconfigured repository staged for read-only analysis."
        if not isinstance(spec, str) or not spec.strip() or "\n" in spec:
            raise ManifestError(f"{path}: entries[{number}].spec must be a non-empty one-line string")
        project = {"name": name, "path": repo_path, "spec": spec, "tasks": [task_name]}
        entry = build_entry("plan", project, task_name, task, tier_name,
                            tiers[tier_name], defaults, root)
        entry.update({"key": key, "ticket_id": "",
                      "ticket_title": "", "ticket_notes": ""})
        entries.append(entry)
    return entries


def expand_tickets(entry: dict, project: dict, stages: dict, want_specced: bool = True) -> list:
    """One queue entry per ticket on the right side of the human gate.

    want_specced=True  -- tier 3: only tickets a human marked specced: true.
                          A ticket with a live state/stages row yields its next
                          stage entry instead of a build.
    want_specced=False -- the reproduce stage: candidates awaiting that decision.
                          Stages are tier 3's pipeline; candidates never have one.

    The build engine is settled here and not in build_entry's setting(): that
    runs with no ticket in scope, and the ticket outranks task, repo and defaults.
    """
    out = []
    for ticket in project.get("tickets") or []:
        if bool(ticket.get("specced")) is not want_specced:
            continue
        ticket_id = str(ticket["id"])
        item = {**entry,
                "ticket_id": ticket_id,
                "ticket_title": ticket.get("title", ""),
                "ticket_notes": ticket.get("notes", ""),
                "key": f"{entry['repo']}/{entry['task']}/{ticket_id}",
                "engine": ticket.get("engine") or entry["engine"]}
        row = stages.get(f"{entry['repo']}/{ticket_id}") if want_specced else None
        if row and row["stage"] != "done":
            item = stage_entry(item, row)
        out.append(item)
    return out


def stage_entry(item: dict, row: dict) -> dict:
    """The ticket's next stage as a queue item (PRP-004 s4.3).

    The engine is written into the entry because eligible() and main gate
    quota on it: a review is charged to the reviewing engine's pool, not the
    builder's. Publish runs no engine at all. The cap exemption is the
    `stage_entry` flag itself -- run.sh reads it in eligible().
    """
    stage = row["stage"]
    if stage in ("review", "review-2"):
        engine, tier = OTHER_ENGINE[row["engine"]], "tier3-review"
    elif stage == "resolve":
        engine, tier = row["engine"], "tier3"
    else:
        engine, tier = "", item["tier"]
    return {**item,
            "stage_entry": True,
            "stage": stage,
            "branch": row["branch"],
            "base": row["base"],
            "build_report": row["build_report"],
            "engine": engine,
            "tier": tier,
            "key": f"{item['key']}/{stage}"}


def cmd_validate(args: list) -> int:
    manifest = args[0]
    root = repo_root(manifest)
    data = load(manifest)
    merged_policy(data)
    for slot in VALID_SLOTS:
        build_queue(data, slot, root)
    print(f"ok: {manifest}")
    return 0


def cmd_policy(args: list) -> int:
    data = load(args[0])
    print(json.dumps(merged_policy(data)))
    return 0


def cmd_queue(args: list) -> int:
    manifest, slot = args[0], args[1]
    if slot not in VALID_SLOTS:
        raise ManifestError(f"unknown slot {slot!r} (expected one of {', '.join(VALID_SLOTS)})")
    root = repo_root(manifest)
    for entry in build_queue(load(manifest), slot, root):
        print(json.dumps(entry))
    return 0


def cmd_plan_queue(args: list) -> int:
    manifest, path, slot = args[0], args[1], args[2]
    if slot not in (*VALID_SLOTS, "all"):
        raise ManifestError(f"unknown slot {slot!r} (expected daily, weekly, or all)")
    root = repo_root(manifest)
    for entry in build_plan_queue(load(manifest), path, slot, root):
        print(json.dumps(entry))
    return 0


def cmd_render(args: list) -> int:
    template, assignments = args[0], args[1:]
    variables = {}
    for assignment in assignments:
        if "=" not in assignment:
            raise ManifestError(f"render: expected KEY=VALUE, got {assignment!r}")
        key, value = assignment.split("=", 1)
        variables[key] = value
    with open(template, "r", encoding="utf-8") as handle:
        body = handle.read()
    unresolved = set(re.findall(r"\{\{([A-Z0-9_]+)\}\}", body)) - set(variables)
    if unresolved:
        raise ManifestError(f"render: template {template} needs {', '.join(sorted(unresolved))}")
    for key, value in variables.items():
        body = body.replace("{{" + key + "}}", value)
    sys.stdout.write(body)
    return 0


def cmd_add_ticket(args: list) -> int:
    """Append one machine-written ticket. Never touches repos.yaml."""
    manifest, repo_name, payload = args[0], args[1], args[2]
    root = repo_root(manifest)
    data = load(manifest)
    tasks = checked_tasks(data, checked_tiers(data), root)

    project = None
    for key in ("repos", "community"):
        for candidate in checked_projects(data, key, tasks, root):
            if candidate["name"] == repo_name:
                project = candidate
    if project is None:
        raise ManifestError(f"unknown repo {repo_name!r} - not in repos.yaml")

    try:
        ticket = json.loads(payload)
    except json.JSONDecodeError as error:
        raise ManifestError(f"add-ticket: payload is not valid JSON: {error}") from error
    if not isinstance(ticket, dict) or not ticket.get("title"):
        raise ManifestError("add-ticket: ticket needs at least a title")

    path = tickets_path(root)
    stored = {}
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as handle:
            stored = yaml.safe_load(handle) or {}
    tickets = stored.get("tickets") or {}
    existing = list(tickets.get(repo_name) or [])

    known = existing + list(project.get("tickets") or [])
    if not ticket.get("id"):
        ticket["id"] = derive_ticket_id(repo_name, known)
    if str(ticket["id"]) in {str(t.get("id")) for t in known}:
        raise ManifestError(f"ticket id {ticket['id']!r} already exists for {repo_name}")
    ticket.setdefault("specced", True)

    updated = {**stored, "tickets": {**tickets, repo_name: existing + [ticket]}}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("# Tickets written by `meute promote`. Machine-owned - edit repos.yaml\n"
                     "# for hand-authored tickets instead; this file is rewritten wholesale.\n")
        yaml.safe_dump(updated, handle, sort_keys=False, default_flow_style=False)
    print(ticket["id"])
    return 0


def cmd_list_repos(args: list) -> int:
    """Raw name+path for every configured repo, personal and community.

    Deliberately does not validate or expand tasks/tickets -- `meute discover`
    only needs this to dedup against paths already configured, and a manifest
    with one broken entry elsewhere must not block that.
    """
    data = load(args[0])
    for key in ("repos", "community"):
        for project in data.get(key) or []:
            if not isinstance(project, dict) or not project.get("path"):
                continue
            print(json.dumps({
                "kind": key,
                "name": project.get("name", ""),
                "path": expand(str(project["path"])),
            }))
    return 0


def cmd_list_tasks(args: list) -> int:
    """name + tier + writes_code + tools + plan_class for every declared task.

    `meute discover`'s picker keys on writes_code; `meute plan` keys on
    plan_class, decided here so the planner and the runner-side validator
    (build_plan_queue) can never disagree about which tiers a plan may stage.
    """
    data = load(args[0])
    tiers = checked_tiers(data)
    tasks = data.get("tasks")
    if not isinstance(tasks, dict):
        raise ManifestError("tasks: must be a mapping")
    for name, task in tasks.items():
        tier = tiers.get(task.get("tier")) if isinstance(task, dict) else None
        print(json.dumps({
            "name": name,
            "tier": task.get("tier") if isinstance(task, dict) else None,
            "writes_code": bool(tier["writes_code"]) if tier else None,
            "tools": tier.get("tools") if tier else None,
            "plan_class": plan_tier_class(tier) if tier else None,
        }))
    return 0


def cmd_add_repo(args: list) -> int:
    """Append one repo to a personal manifest. Refuses to touch repos.yaml.

    repos.yaml is the tracked schema doc, hand-written and commented; PyYAML
    cannot round-trip it without destroying those comments (see
    load_machine_tickets's docstring for the same reasoning applied to
    tickets). repos.local.yaml is gitignored and already machine-editable --
    that split is exactly why this command exists as a separate path instead
    of extending add-ticket.
    """
    manifest, payload = args[0], args[1]
    refuse_tracked_manifest("add-repo", manifest)
    root = repo_root(manifest)

    try:
        fields = json.loads(payload)
    except json.JSONDecodeError as error:
        raise ManifestError(f"add-repo: payload is not valid JSON: {error}") from error
    if not isinstance(fields, dict):
        raise ManifestError("add-repo: payload must be a JSON object")
    name = fields.get("name")
    if not name or not SAFE_NAME.match(str(name)):
        raise ManifestError(f"add-repo: name {name!r} must match {SAFE_NAME.pattern}")
    if not fields.get("path"):
        raise ManifestError("add-repo: path is required")
    if not fields.get("spec"):
        raise ManifestError("add-repo: spec is required (one line, injected into every prompt)")

    data = load(manifest)
    new_path = expand(str(fields["path"]))
    for key in ("repos", "community"):
        for project in data.get(key) or []:
            if not isinstance(project, dict):
                continue
            if project.get("name") == name:
                raise ManifestError(f"add-repo: name {name!r} is already configured under {key}")
            if project.get("path") and expand(str(project["path"])) == new_path:
                raise ManifestError(
                    f"add-repo: path {new_path!r} is already configured as "
                    f"{project.get('name')!r} under {key}")

    new_project = {"name": name, "path": fields["path"], "spec": fields["spec"]}
    if fields.get("default_branch"):
        new_project["default_branch"] = fields["default_branch"]
    new_project["tasks"] = list(fields.get("tasks") or [])

    new_data = {**data, "repos": list(data.get("repos") or []) + [new_project]}
    validate_merged(new_data, root)
    write_with_backup(manifest, new_data)
    print(name)
    return 0


def refuse_tracked_manifest(command: str, manifest: str) -> None:
    """Every machine writer of a manifest shares one refusal, so none can forget it."""
    if os.path.basename(manifest) == "repos.yaml":
        raise ManifestError(
            f"{command}: refusing to write repos.yaml (tracked schema doc, hand-commented). "
            "Create repos.local.yaml first -- e.g. `cp repos.yaml repos.local.yaml` -- "
            "it's gitignored, so no PR is needed for what you add to it.")


def validate_merged(new_data: dict, root: str) -> None:
    """The *merged* document, the same way `validate` does, before touching disk.

    A bad payload must never leave the real file corrupt or half-written.
    """
    tiers = checked_tiers(new_data)
    tasks = checked_tasks(new_data, tiers, root)
    checked_projects(new_data, "repos", tasks, root)
    merged_policy(new_data)
    for slot in VALID_SLOTS:
        build_queue(new_data, slot, root)


def write_with_backup(manifest: str, new_data: dict) -> None:
    backup = f"{manifest}.bak"
    with open(manifest, "r", encoding="utf-8") as handle:
        original = handle.read()
    with open(backup, "w", encoding="utf-8") as handle:
        handle.write(original)
    with open(manifest, "w", encoding="utf-8") as handle:
        yaml.safe_dump(new_data, handle, sort_keys=False, default_flow_style=False)


def find_project(data: dict, repo_name: str) -> tuple:
    """(section, entry) for a name, from the raw document. Unknown is an error."""
    for key in ("repos", "community"):
        for project in data.get(key) or []:
            if isinstance(project, dict) and project.get("name") == repo_name:
                return key, project
    raise ManifestError(f"unknown repo {repo_name!r} - not in the manifest")


def cmd_set_image_digest(args: list) -> int:
    """Pin one repo's image.digest. The only writer of that field.

    Reads the document raw rather than validated: the manifest that needs
    this is, by rule 1, exactly one that does not validate yet -- the tag is
    set and the digest is not. What must validate is the result.
    """
    manifest, repo_name, digest = args[0], args[1], args[2]
    refuse_tracked_manifest("set-image-digest", manifest)
    if not IMAGE_DIGEST.match(digest):
        raise ManifestError(f"set-image-digest: {digest!r} is not a sha256 digest")
    root = repo_root(manifest)
    data = load(manifest)
    section, project = find_project(data, repo_name)
    image = project.get("image") if isinstance(project.get("image"), dict) else {}
    if not image.get("tag"):
        raise ManifestError(
            f"set-image-digest: {repo_name} has no image.tag - the digest pins a tag; "
            f"set image.tag (Atelier's agent-{repo_name}:g<sha>) first")
    updated = {**project, "image": {**image, "digest": digest}}
    new_data = {**data, section: [updated if p is project else p for p in data[section]]}
    validate_merged(new_data, root)
    write_with_backup(manifest, new_data)
    print(digest)
    return 0


def cmd_list_images(args: list) -> int:
    """Raw runtime + image pin for every configured repo, personal and community.

    `meute image bump` and `doctor` read this. Like list-repos it does not
    validate -- the manifest that needs a digest bump is exactly one that
    fails rule 1 today, and doctor exists to report a broken manifest.
    """
    data = load(args[0])
    defaults = data.get("defaults") if isinstance(data.get("defaults"), dict) else {}
    for key in ("repos", "community"):
        for project in data.get(key) or []:
            if not isinstance(project, dict) or not project.get("name"):
                continue
            image = project.get("image") if isinstance(project.get("image"), dict) else {}
            print(json.dumps({
                "kind": key,
                "name": project["name"],
                "runtime": project.get("runtime") or defaults.get("runtime") or ENTRY_DEFAULTS["runtime"],
                "tag": str(image.get("tag") or ""),
                "digest": str(image.get("digest") or ""),
            }))
    return 0


def cmd_mark_delivered(args: list) -> int:
    """Retire a machine-written ticket once tier 3 has produced a branch for it.

    Without this a ticket stays `specced: true` forever and every weekly slot
    re-drafts work that is already sitting on a branch awaiting review.
    Hand-written tickets in repos.yaml are left alone -- that file is yours.
    """
    manifest, repo_name, ticket_id, branch = args[0], args[1], args[2], args[3]
    root = repo_root(manifest)
    path = tickets_path(root)
    if not os.path.isfile(path):
        return 0
    with open(path, "r", encoding="utf-8") as handle:
        stored = yaml.safe_load(handle) or {}
    tickets = stored.get("tickets") or {}
    entries = tickets.get(repo_name) or []
    found = False
    updated = []
    for ticket in entries:
        if str(ticket.get("id")) == str(ticket_id) and ticket.get("specced"):
            ticket = {**ticket, "specced": False,
                      "delivered_branch": branch,
                      "delivered": datetime.date.today().isoformat()}
            found = True
        updated.append(ticket)
    if not found:
        return 0
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("# Tickets written by `meute promote`. Machine-owned - edit repos.yaml\n"
                     "# for hand-authored tickets instead; this file is rewritten wholesale.\n")
        yaml.safe_dump({**stored, "tickets": {**tickets, repo_name: updated}},
                       handle, sort_keys=False, default_flow_style=False)
    print(ticket_id)
    return 0


COMMANDS = {
    "validate": (cmd_validate, 1),
    "policy": (cmd_policy, 1),
    "queue": (cmd_queue, 2),
    "plan-queue": (cmd_plan_queue, 3),
    "render": (cmd_render, 1),
    "add-ticket": (cmd_add_ticket, 3),
    "mark-delivered": (cmd_mark_delivered, 4),
    "list-repos": (cmd_list_repos, 1),
    "list-tasks": (cmd_list_tasks, 1),
    "list-images": (cmd_list_images, 1),
    "add-repo": (cmd_add_repo, 2),
    "set-image-digest": (cmd_set_image_digest, 3),
}


def main(argv: list) -> int:
    if len(argv) < 2 or argv[1] not in COMMANDS:
        sys.stderr.write(__doc__ or "")
        return 2
    handler, minimum = COMMANDS[argv[1]]
    args = argv[2:]
    if len(args) < minimum:
        return fail(f"{argv[1]}: expected at least {minimum} argument(s)")
    try:
        return handler(args)
    except ManifestError as error:
        return fail(str(error))
    except OSError as error:
        return fail(f"{error.filename}: {error.strerror}")


def fail(message: str) -> int:
    sys.stderr.write(f"meute/manifest: {message}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
