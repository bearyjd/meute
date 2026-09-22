"""Every command that writes a manifest or state/tickets.yaml.

lib/manifest.py is the reader and the CLI; this is the machine-write path
behind `meute discover` (add-repo), `meute image bump` (set-image-digest),
`meute promote` (add-ticket) and the runner's mark-delivered. Kept apart so
the code that can alter repos.local.yaml is one short file with one rule
running through it: refuse repos.yaml, validate the document as it WILL be,
back the old one up, then write. Nothing here touches state/stages -- that
row is the runner's to advance.

Imported by manifest.py for its COMMANDS table, after every name imported
below exists there; import manifest first, never this module on its own.
"""

from __future__ import annotations

import datetime
import json
import os
import re

import yaml

from manifest import (
    IMAGE_DIGEST,
    SAFE_NAME,
    VALID_SLOTS,
    ManifestError,
    build_queue,
    checked_projects,
    checked_tasks,
    checked_tiers,
    expand,
    load,
    merged_policy,
    repo_root,
    tickets_path,
)


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
