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
    list-stages <manifest>           -- every state/stages row, one JSON object per line,
                                        flagged when its key names no ticket
    add-repo <manifest> <json>       -- append a repo; refuses to write repos.yaml
    set-image-digest <manifest> <repo> <digest>
                                     -- pin a repo's image.digest; refuses to write repos.yaml

The queue is *candidates only*. Gating that depends on live repo state (weekly
community share, tier-3 in-flight cap, cursor position) belongs to run.sh.

This file is the schema, the reader and the CLI. Two features live beside it
and are dispatched from here: lib/stages.py turns state/stages rows into
stage entries for the queue, and lib/manifest_write.py holds every command
that writes repos.local.yaml or state/tickets.yaml.
"""

from __future__ import annotations

import json
import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - environment problem, not a data problem
    sys.exit("meute: PyYAML is required (pip install --user PyYAML)")

# Run as `python3 lib/manifest.py` this module is `__main__`, yet lib/stages.py
# and lib/manifest_write.py import it as `manifest`. Without this alias Python
# would load a second copy under that name, with a second ManifestError that
# main()'s except clause below would never catch.
if __name__ == "__main__":
    sys.modules["manifest"] = sys.modules[__name__]

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
    # Nothing under PRP-004 s4.1 has a fleet-wide value: egress is a tier's to
    # declare and the pin and the push are a repo's. A defaults key here would
    # be read by nothing and look like it was honoured.
    if "network" in supplied:
        raise ManifestError("defaults.network: set per tier, not in defaults")
    for key in ("image", "push", "auto_merge"):
        if key in supplied:
            raise ManifestError(f"defaults.{key}: set per repo, not in defaults")
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
    auto_merge = project.get("auto_merge", False)
    if not isinstance(auto_merge, bool):
        raise ManifestError(f"{where}.auto_merge: must be true or false")
    if auto_merge:
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


def with_machine_tickets(project: dict, machine: dict) -> dict:
    """Copy of `project` whose ticket list also carries the machine-written ones.

    The machine-written source passes the same ticket gate as repos.yaml
    (PRP-001 s10): expand_tickets honours a ticket's `engine`, and a field
    the validator never saw is a field nobody chose.
    """
    extra = machine.get(project["name"]) or []
    if not extra:
        return project
    own = list(project.get("tickets") or [])
    seen = {str(ticket.get("id")) for ticket in own}
    for ticket in extra:
        if not isinstance(ticket, dict) or not ticket.get("id"):
            raise ManifestError(f"state/tickets.yaml[{project['name']}]: every ticket needs an id")
        identifier = str(ticket.get("id"))
        checked_ticket(f"state/tickets.yaml[{project['name']}][{identifier}]", ticket)
        if identifier in seen:
            raise ManifestError(
                f"ticket id {identifier!r} for {project['name']} exists in both "
                "repos.yaml and state/tickets.yaml - resolve the clash by hand")
        seen.add(identifier)
    return {**project, "tickets": own + list(extra)}


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
    warn_orphan_rows(stages, ticket_keys(data, tasks, root))
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
                    for item in expand_tickets(entry, project, stages, tiers, want_specced=True):
                        (in_flight if item["stage_entry"] else fresh).append(item)
                elif task.get("requires_candidate_ticket"):
                    fresh.extend(expand_tickets(entry, project, stages, tiers, want_specced=False))
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


# The stage machine and the machine-write path import this module's schema
# by name, so they are imported here, below every definition they need: at
# this point `from manifest import ...` inside them resolves, and the queue
# builder and COMMANDS above and below see their functions as plain names.
from stages import (  # noqa: E402
    cmd_list_stages,
    expand_tickets,
    load_stages,
    ticket_keys,
    warn_orphan_rows,
)
from manifest_write import (  # noqa: E402
    cmd_add_repo,
    cmd_add_ticket,
    cmd_mark_delivered,
    cmd_set_image_digest,
)


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
    "list-stages": (cmd_list_stages, 1),
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
