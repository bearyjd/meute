"""Read-only identity checks for a versioned feature readiness record."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

from evidence import OID, ROOT, SHA256, read_input, unique_object
from manifest import SAFE_NAME, expand, yaml
from readiness_eval import Context, evaluate, observe_mutable
from readiness_rules import validate_rules


MAX_INPUT_BYTES = 4 * 1024 * 1024
SCOPE = ("repo", "slice_id", "plan_revision")
PURPOSES = {"docs", "codemap", "baseline", "acceptance", "audits"}
RECORD_FIELDS = {"version", *SCOPE, "ref", "base_commit", "intent_ref", "evidence"}
POLICY_FIELDS = {
    "version", *SCOPE, "record_sha256", "manifest_path", "manifest_sha256",
    "checkout", "report_inventory", "evidence_root", "attested_digests",
    "assessment", "deferrals", "accepted_conditions",
}


class InvalidInput(ValueError):
    def __init__(self, reason: str, detail: str):
        super().__init__(detail)
        self.reason = reason


class ManifestLoader(yaml.SafeLoader):
    """Honor YAML merge defaults while rejecting duplicate explicit keys."""

    def construct_document(self, node):
        # Check explicit keys before SafeLoader flattens YAML merge mappings.
        seen = set()
        nodes = [node]
        while nodes:
            current = nodes.pop()
            if current in seen:
                continue
            seen.add(current)
            if isinstance(current, yaml.MappingNode):
                keys = set()
                for key_node, value_node in current.value:
                    if key_node.tag == "tag:yaml.org,2002:merge":
                        key = (key_node.tag, key_node.value)
                    elif key_node.tag == "tag:yaml.org,2002:value":
                        key = key_node.value
                    elif isinstance(key_node, yaml.ScalarNode):
                        key = self.construct_object(key_node)
                    else:
                        raise ValueError("expected scalar YAML keys")
                    if key in keys:
                        raise ValueError("duplicate YAML key")
                    keys.add(key)
                    nodes.append(value_node)
            elif isinstance(current, yaml.SequenceNode):
                nodes.extend(current.value)
        return super().construct_document(node)


def snapshot(path: Path, label: str) -> tuple[Path, bytes, tuple[int, int]]:
    try:
        canonical = path.resolve(strict=True)
        data, identity = read_input(canonical, MAX_INPUT_BYTES)
    except (OSError, ValueError, RuntimeError) as error:
        raise InvalidInput(f"{label}_unreadable", str(error)) from error
    return canonical, data, identity


def load_document(data: bytes, fields: set[str], label: str) -> dict:
    try:
        doc = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    except (ValueError, RecursionError) as error:
        raise InvalidInput(f"{label}_json_invalid", "Expected UTF-8 JSON with distinct keys") from error
    if not isinstance(doc, dict) or doc.keys() != fields:
        raise InvalidInput(f"{label}_schema_invalid", f"Expected fields: {', '.join(sorted(fields))}")
    if type(doc["version"]) is not int or doc["version"] != 1:
        raise InvalidInput(f"{label}_schema_invalid", "Expected version 1")
    return doc


def nonempty_text(value) -> bool:
    return isinstance(value, str) and bool(value) and value == value.strip() and value.isprintable()


def matches(pattern, value) -> bool:
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def parse_record(data: bytes) -> dict:
    record = load_document(data, RECORD_FIELDS, "record")
    if not (
        matches(SAFE_NAME, record["repo"]) and matches(SAFE_NAME, record["slice_id"])
        and all(nonempty_text(record[key]) for key in ("intent_ref", "plan_revision", "ref"))
        and matches(OID, record["base_commit"])
    ):
        raise InvalidInput("record_identity_invalid", "Expected a repo, slice, intent, plan, ref and full base commit")
    evidence = record["evidence"]
    if not isinstance(evidence, dict) or evidence.keys() != PURPOSES:
        raise InvalidInput("record_evidence_invalid", "Expected docs, codemap, baseline, acceptance and audits lists")
    for purpose, references in evidence.items():
        if not isinstance(references, list):
            raise InvalidInput("record_evidence_invalid", f"Expected an array for evidence.{purpose}")
        for reference in references:
            if not isinstance(reference, dict):
                raise InvalidInput("record_evidence_invalid", f"Expected an evidence reference for {purpose}")
            pins = reference.keys() & {"sha256", "git_blob"}
            if not (
                {"ref", "revision"} <= reference.keys() <= {"ref", "revision", "sha256", "git_blob", "command"}
                and all(nonempty_text(reference[key]) for key in ("ref", "revision"))
                and len(pins) == 1
                and ("sha256" not in reference or matches(SHA256, reference["sha256"]))
                and ("git_blob" not in reference or matches(OID, reference["git_blob"]))
                and ("command" not in reference or isinstance(reference["command"], str))
            ):
                raise InvalidInput("record_evidence_invalid", f"Invalid evidence reference for {purpose}")
    return record


def report_path(value: str) -> bool:
    if not nonempty_text(value):
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and ".." not in path.parts and str(path) == value and path.suffix == ".md"


def parse_policy(data: bytes) -> dict:
    policy = load_document(data, POLICY_FIELDS, "policy")
    if not (
        matches(SAFE_NAME, policy["repo"]) and matches(SAFE_NAME, policy["slice_id"])
        and nonempty_text(policy["plan_revision"])
        and all(matches(SHA256, policy[key]) for key in ("record_sha256", "manifest_sha256"))
        and all(nonempty_text(policy[key]) and Path(policy[key]).is_absolute()
                for key in ("manifest_path", "checkout"))
    ):
        raise InvalidInput("policy_identity_invalid", "Expected policy scope, digests and absolute paths")
    inventory = policy["report_inventory"]
    if not isinstance(inventory, dict) or any(
        not report_path(path) or not matches(SHA256, digest) for path, digest in inventory.items()
    ):
        raise InvalidInput("policy_inventory_invalid", "Expected relative Markdown report paths and SHA-256 digests")
    try:
        validate_rules(policy)
    except ValueError as error:
        raise InvalidInput("policy_rules_invalid", str(error)) from error
    return policy


def enrolled_checkout(data: bytes, repo: str, expected: str) -> Path:
    try:
        manifest = yaml.load(data.decode("utf-8"), Loader=ManifestLoader)
    # Some PyYAML scalar constructors raise ordinary Python exceptions for
    # malformed explicit tags instead of wrapping them in YAMLError.
    except (AttributeError, LookupError, RecursionError, TypeError, ValueError, yaml.YAMLError) as error:
        raise InvalidInput("manifest_invalid", "Expected unambiguous, well-formed UTF-8 YAML") from error
    if not isinstance(manifest, dict) or type(manifest.get("version")) is not int or manifest["version"] != 1:
        raise InvalidInput("manifest_invalid", "Expected a version 1 manifest")
    enrolled = []
    for group in ("repos", "community"):
        entries = manifest.get(group)
        if entries is None:
            continue
        if not isinstance(entries, list):
            raise InvalidInput("manifest_invalid", f"Expected a list for {group}")
        for entry in entries:
            if not (
                isinstance(entry, dict) and matches(SAFE_NAME, entry.get("name"))
                and nonempty_text(entry.get("path"))
            ):
                raise InvalidInput("manifest_invalid", f"Expected a name and path for each {group} entry")
            try:
                checkout = Path(expand(entry["path"])).resolve()
            except (OSError, RuntimeError) as error:
                raise InvalidInput("manifest_invalid", str(error)) from error
            enrolled.append((entry["name"], checkout))
    named = [checkout for name, checkout in enrolled if name == repo]
    if not named:
        raise InvalidInput("repo_not_enrolled", "Requested repo is absent from the manifest")
    if len(named) != 1 or sum(checkout == named[0] for _, checkout in enrolled) != 1:
        raise InvalidInput("repo_enrollment_ambiguous", "Expected a unique name and canonical checkout across enrollment lists")
    if str(named[0]) != expected:
        raise InvalidInput("checkout_mismatch", "Canonical enrolled checkout differs from operator policy")
    return named[0]


def local_git(checkout: Path, *args: str, text: bool = True) -> subprocess.CompletedProcess:
    # git -C still honors environment overrides for the repository and refs.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(
        GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1", GIT_ALLOW_PROTOCOL="",
        GIT_OPTIONAL_LOCKS="0", GIT_CEILING_DIRECTORIES=str(checkout.parent),
    )
    try:
        decoding = {"text": True, "encoding": "utf-8", "errors": "surrogateescape"} if text else {}
        return subprocess.run(["git", "-C", str(checkout), *args], env=env, capture_output=True,
                              timeout=10, **decoding)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise InvalidInput("git_unavailable", str(error)) from error


def checkout_format(checkout: Path) -> str:
    git_entry = checkout / ".git"
    if not (git_entry.is_dir() or git_entry.is_file()):
        raise InvalidInput("checkout_invalid", "Canonical enrollment must name the root of a Git worktree")
    tree = local_git(checkout, "rev-parse", "--show-toplevel")
    if tree.returncode or tree.stdout.removesuffix("\n") != str(checkout):
        raise InvalidInput("checkout_invalid", "Canonical enrollment must name the root of a Git worktree")
    fmt = local_git(checkout, "rev-parse", "--show-object-format")
    if fmt.returncode:
        raise InvalidInput("checkout_invalid", "Cannot read enrolled worktree object format")
    return fmt.stdout.strip()


def check_ref_format(checkout: Path, ref: str, base_commit: str, object_format: str) -> None:
    if not ref.startswith("refs/heads/") or local_git(checkout, "check-ref-format", ref).returncode:
        raise InvalidInput("ref_invalid", "Expected a literal fully qualified local branch ref under refs/heads/")
    lengths = {"sha1": 40, "sha256": 64}
    if lengths.get(object_format) != len(base_commit):
        raise InvalidInput("base_commit_format_invalid", "Base commit must match the enrolled repository's object format")


def observe_ref(checkout: Path, ref: str, expected: str) -> dict:
    refs = local_git(checkout, "for-each-ref", "--format=%(refname) %(objectname) %(symref)", "--", ref)
    observation = {"ref": ref, "expected_commit": expected, "observed_commit": None}
    if refs.returncode:
        return {"status": "pending", "reason": "ref_unavailable", **observation}
    for raw in refs.stdout.split("\n"):
        name, _, remainder = raw.partition(" ")
        if name != ref:
            continue
        observed, _, symref = remainder.partition(" ")
        observation["observed_commit"] = observed
        if symref:
            return {"status": "pending", "reason": "ref_symbolic", **observation}
        if observed != expected:
            return {"status": "pending", "reason": "ref_moved", **observation}
        obj = local_git(checkout, "cat-file", "-t", observed)
        if obj.returncode or obj.stdout != "commit\n":
            return {"status": "pending", "reason": "ref_commit_unavailable", **observation}
        return {"status": "passed", "reason": "ref_matches", **observation}
    return {"status": "pending", "reason": "ref_missing", **observation}


def identify(record_path: Path, policy_path: Path, manifest_path: Path, checks: list[dict]) -> dict:
    """The 4.1 identity checks. Raises InvalidInput tagged with the failing check."""
    check = "input"
    try:
        _, record_bytes, record_file = snapshot(record_path, "record")
        _, policy_bytes, policy_file = snapshot(policy_path, "policy")
        if record_file == policy_file:
            raise InvalidInput("policy_not_separate", "Record and operator policy must be separate files")
        record = parse_record(record_bytes)
        policy = parse_policy(policy_bytes)
        checks.append({"check": check, "status": "passed", "reason": "input_valid"})

        check = "policy"
        if any(record[key] != policy[key] for key in SCOPE):
            raise InvalidInput("policy_scope_mismatch", "Operator policy covers a different repo, slice or plan")
        if hashlib.sha256(record_bytes).hexdigest() != policy["record_sha256"]:
            raise InvalidInput("record_digest_mismatch", "Operator policy does not pin the parsed record bytes")
        canonical_manifest, manifest_bytes, _ = snapshot(manifest_path, "manifest")
        if str(canonical_manifest) != policy["manifest_path"]:
            raise InvalidInput("manifest_path_mismatch", "Operator policy selects a different manifest")
        if hashlib.sha256(manifest_bytes).hexdigest() != policy["manifest_sha256"]:
            raise InvalidInput("manifest_digest_mismatch", "Operator policy does not pin the effective manifest bytes")
        checks.append({"check": check, "status": "passed", "reason": "policy_bindings_match"})

        check = "enrollment"
        checkout = enrolled_checkout(manifest_bytes, record["repo"], policy["checkout"])
        object_format = checkout_format(checkout)
        checks.append({"check": check, "status": "passed", "reason": "enrollment_matches"})

        check = "ref"
        check_ref_format(checkout, record["ref"], record["base_commit"], object_format)
        checks.append({"check": check, **observe_ref(checkout, record["ref"], record["base_commit"])})
    except InvalidInput as error:
        error.check = check
        raise
    return {
        "record": record, "policy": policy, "checkout": checkout,
        "inputs": {
            "record": hashlib.sha256(record_bytes).hexdigest(), "policy": hashlib.sha256(policy_bytes).hexdigest(),
            "manifest": (str(canonical_manifest), hashlib.sha256(manifest_bytes).hexdigest()),
            "ref": {key: checks[-1][key] for key in ("status", "observed_commit")},
        },
    }


def commands_check(record: dict) -> dict:
    commands = [
        {"purpose": purpose, "ref": item["ref"], "command": item["command"]}
        for purpose, references in record["evidence"].items()
        for item in references if "command" in item
    ]
    return {"check": "commands", "status": "passed", "reason": "commands_not_executed", "commands": commands}


def _file_state(path: Path, label: str):
    try:
        canonical, data, _ = snapshot(path, label)
    except InvalidInput:
        return None
    return str(canonical), hashlib.sha256(data).hexdigest()


def observe_inputs(paths: tuple[Path, Path, Path], ctx: Context, checkout: Path) -> dict:
    """Re-read every mutable input as identify and evaluate first saw it."""
    record_path, policy_path, manifest_path = paths
    record, policy = _file_state(record_path, "record"), _file_state(policy_path, "policy")
    ref = observe_ref(checkout, ctx.record["ref"], ctx.record["base_commit"])
    return {
        "record": record and record[1], "policy": policy and policy[1],
        "manifest": _file_state(manifest_path, "manifest"),
        "ref": {key: ref[key] for key in ("status", "observed_commit")},
        **observe_mutable(ctx),
    }


def final_checks(observed: dict, baseline: dict, relied: list, now: datetime) -> list[dict]:
    drifted = sorted(key for key in baseline if observed[key] != baseline[key])
    recheck = {"check": "recheck", "status": "pending", "reason": "inputs_drifted", "drifted": drifted} if drifted \
        else {"check": "recheck", "status": "passed", "reason": "inputs_unchanged"}
    lapsed = any(now >= expiry for expiry in relied)
    expiry = {"check": "expiry", "status": "pending", "reason": "deferral_expired_at_final"} if lapsed \
        else {"check": "expiry", "status": "passed", "reason": "deferrals_current"}
    return [recheck, expiry]


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def validate(
    record_path: Path, policy_path: Path, manifest_path: Path, *,
    clock=utc_now, root: Path = ROOT, after_evaluation=lambda: None,
) -> tuple[int, dict]:
    checks: list[dict] = []
    result = {"version": 1, "checks": checks}
    try:
        identity = identify(record_path, policy_path, manifest_path, checks)
        record = identity["record"]
        result["scope"] = {key: record[key] for key in (*SCOPE, "intent_ref")}
        checkout = identity["checkout"]
        ctx = Context(root, record, identity["policy"], lambda *args, **kwargs: local_git(checkout, *args, **kwargs))
        evaluated, snapshot_state, relied = evaluate(ctx, clock())
        checks.extend((*evaluated, commands_check(record)))
        after_evaluation()
        observed = observe_inputs((record_path, policy_path, manifest_path), ctx, checkout)
        final = clock()
        checks.extend(final_checks(observed, {**identity["inputs"], **snapshot_state}, relied, final))
    except InvalidInput as error:
        checks.append({"check": getattr(error, "check", "input"), "status": "invalid",
                       "reason": error.reason, "detail": str(error)})
        result.update(status="invalid", observed_at=clock().isoformat())
        return 2, result
    except Exception as error:  # never a traceback or a path: the contract is structured status
        checks.append({"check": "evaluation", "status": "pending", "reason": "evaluation_failed",
                       "detail": type(error).__name__})
        result.update(status="pending", observed_at=clock().isoformat())
        return 1, result

    ready = all(item["status"] == "passed" for item in checks)
    result.update(status="ready" if ready else "pending", observed_at=final.isoformat())
    return (0 if ready else 1), result


def main(manifest_path: Path, args: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="meute readiness", allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True)
    validate_parser = commands.add_parser("validate", allow_abbrev=False)
    validate_parser.add_argument("record", type=Path)
    validate_parser.add_argument("--owner-policy", type=Path, required=True, action="append")
    options = parser.parse_args(args)
    if len(options.owner_policy) != 1:
        validate_parser.error("--owner-policy must be provided exactly once")
    code, result = validate(options.record, options.owner_policy[0], manifest_path)
    print(json.dumps(result))
    return code


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1]), sys.argv[2:]))
