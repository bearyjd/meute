"""What `meute plan` may stage, and the queue it stages -- the runner's half.

lib/plan.sh is the shell half of the feature: the inventory, the ranking,
the staged state/plan-queue.json. It asks this module, through list-tasks'
plan_class, which tiers a plan may stage at all, and the runner asks again
through plan-queue when it expands that file. The decision is made here,
once, from the tier's tool list alone, so the planner and the runner-side
validator can never disagree about it.

Separate from manifest.py because it is a feature, not schema: a plan runs
against repositories nobody enrolled, so its rules -- read-only tiers only,
the web as an explicit opt-in, no tier that can shell out -- are stricter
than the manifest's and change with the plan, not with the schema. Imported
by manifest.py after every name below is defined there, so `from manifest
import` here resolves; import manifest first, never this module on its own.
"""

from __future__ import annotations

import json
import os

from manifest import (
    SAFE_NAME,
    VALID_SLOTS,
    ManifestError,
    build_entry,
    checked_tasks,
    checked_tiers,
    load,
    merged_defaults,
    repo_root,
)

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


def cmd_plan_queue(args: list) -> int:
    manifest, path, slot = args[0], args[1], args[2]
    if slot not in (*VALID_SLOTS, "all"):
        raise ManifestError(f"unknown slot {slot!r} (expected daily, weekly, or all)")
    root = repo_root(manifest)
    for entry in build_plan_queue(load(manifest), path, slot, root):
        print(json.dumps(entry))
    return 0
