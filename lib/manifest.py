#!/usr/bin/env python3
"""Manifest reader for the meute fleet runner.

bin/run.sh shells out to this for anything that needs real YAML parsing.
Everything it prints is either JSON or JSON Lines so the caller can consume it
with jq instead of splitting fields by hand.

Subcommands
    validate <manifest>              -- schema check; exit 2 and explain on failure
    policy   <manifest>              -- policy block as a single JSON object
    queue    <manifest> <slot>       -- candidate work items, one JSON object per line
    render   <template> KEY=VAL ...  -- substitute {{KEY}} placeholders, print to stdout

The queue is *candidates only*. Gating that depends on live repo state (weekly
community share, tier-3 in-flight cap, cursor position) belongs to run.sh.
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

SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
VALID_SLOTS = ("daily", "weekly")
REQUIRED_TIER_KEYS = ("tools", "permission_mode", "writes_code")

POLICY_DEFAULTS = {
    "quota_floor_percent": 30,
    "community_share": 0.20,
    "tier3_max_in_flight": 3,
    "branch_prefix": "meute",
}

ENTRY_DEFAULTS = {
    "engine": "claude",
    "model": "sonnet",
    "file_budget": 25,
    "timeout_seconds": 1800,
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
    if not SAFE_NAME.match(str(policy["branch_prefix"])):
        raise ManifestError("policy.branch_prefix: must be a safe identifier")
    return policy


def merged_defaults(data: dict) -> dict:
    defaults = dict(ENTRY_DEFAULTS)
    supplied = data.get("defaults") or {}
    if not isinstance(supplied, dict):
        raise ManifestError("defaults: must be a mapping")
    defaults.update(supplied)
    if defaults["engine"] not in ("claude", "codex"):
        raise ManifestError("defaults.engine: must be 'claude' or 'codex'")
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
    return tiers


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
    return tasks


def checked_projects(data: dict, key: str, tasks: dict) -> list:
    projects = data.get(key) or []
    if not isinstance(projects, list):
        raise ManifestError(f"{key}: must be a list")
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
        for task_name in project.get("tasks") or []:
            if task_name not in tasks:
                raise ManifestError(f"{key}.{name}.tasks: undeclared task {task_name!r}")
        for ticket in project.get("tickets") or []:
            if not isinstance(ticket, dict) or not ticket.get("id"):
                raise ManifestError(f"{key}.{name}.tickets: every ticket needs an id")
    return projects


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
    }


def build_queue(data: dict, slot: str, root: str) -> list:
    """Personal repos first, community second - the 80/20 ordering is structural."""
    defaults = merged_defaults(data)
    tiers = checked_tiers(data)
    tasks = checked_tasks(data, tiers, root)
    entries = []
    for kind, key in (("personal", "repos"), ("community", "community")):
        for project in checked_projects(data, key, tasks):
            for task_name in project.get("tasks") or []:
                task = tasks[task_name]
                slots = task.get("slots") or list(VALID_SLOTS)
                if slot not in slots:
                    continue
                tier_name = task["tier"]
                entry = build_entry(kind, project, task_name, task, tier_name,
                                    tiers[tier_name], defaults, root)
                if task.get("requires_specced_ticket"):
                    entries.extend(expand_tickets(entry, project))
                else:
                    entry["key"] = f"{entry['repo']}/{task_name}"
                    entry["ticket_id"] = ""
                    entry["ticket_title"] = ""
                    entry["ticket_notes"] = ""
                    entries.append(entry)
    return entries


def expand_tickets(entry: dict, project: dict) -> list:
    """Tier 3 only touches tickets the human explicitly marked specced: true."""
    out = []
    for ticket in project.get("tickets") or []:
        if not ticket.get("specced"):
            continue
        item = dict(entry)
        item["ticket_id"] = str(ticket["id"])
        item["ticket_title"] = ticket.get("title", "")
        item["ticket_notes"] = ticket.get("notes", "")
        item["key"] = f"{entry['repo']}/{entry['task']}/{item['ticket_id']}"
        out.append(item)
    return out


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


COMMANDS = {
    "validate": (cmd_validate, 1),
    "policy": (cmd_policy, 1),
    "queue": (cmd_queue, 2),
    "render": (cmd_render, 1),
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
