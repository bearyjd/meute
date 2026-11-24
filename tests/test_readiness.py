"""Exercise readiness v1 through the public Meute CLI with disposable repos."""

from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


MEUTE = Path(__file__).resolve().parents[1]
REF = "refs/heads/topic"


class ReadinessTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.layout = self.root / "meute"
        self.layout.mkdir()
        for directory in ("bin", "lib"):
            (self.layout / directory).symlink_to(MEUTE / directory, target_is_directory=True)
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        self.git("init", "-q", "-b", "main", "--object-format=sha1")
        self.git("commit", "--allow-empty", "-qm", "base")
        self.base_commit = self.git("rev-parse", "HEAD")
        self.git("update-ref", REF, self.base_commit)
        self.manifest = self.layout / "repos.yaml"
        self.enrollment = {"name": "sample", "path": str(self.checkout)}
        self.write_manifest(self.manifest, repos=[self.enrollment])
        self.record_path = self.root / "record.json"
        self.policy_path = self.root / "policy.json"
        self.scope = {"repo": "sample", "slice_id": "one-feature", "plan_revision": "plan/v1"}
        self.record = {
            "version": 1,
            **self.scope,
            "ref": REF,
            "base_commit": self.base_commit,
            "intent_ref": "planning/0001",
            "evidence": {purpose: [] for purpose in ("docs", "codemap", "baseline", "acceptance", "audits")},
        }
        self.write_inputs()

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", self.checkout, "-c", "user.name=Readiness Test",
             "-c", "user.email=readiness@example.invalid", *args],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    @staticmethod
    def write_manifest(path, **groups):
        path.write_text(yaml.safe_dump({"version": 1, **groups}), encoding="utf-8")

    def write_inputs(self, *, manifest=None, **policy_overrides):
        manifest = manifest or self.manifest
        self.record_path.write_text(json.dumps(self.record), encoding="utf-8")
        self.write_policy(manifest=manifest, **policy_overrides)

    def write_policy(self, *, manifest=None, **overrides):
        manifest = manifest or self.manifest
        policy = {
            "version": 1,
            **self.scope,
            "record_sha256": hashlib.sha256(self.record_path.read_bytes()).hexdigest(),
            "manifest_path": str(manifest.resolve()),
            "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
            "checkout": str(self.checkout),
            "report_inventory": {},
            **overrides,
        }
        self.policy_path.write_text(json.dumps(policy), encoding="utf-8")

    def run_validate(self, *, override=None, env=None, code=1, args=None):
        environment = {key: value for key, value in os.environ.items() if key != "MEUTE_MANIFEST"}
        if override is not None:
            environment["MEUTE_MANIFEST"] = str(override)
        environment.update(env or {})
        result = subprocess.run(
            [self.layout / "bin/meute", "readiness", "validate",
             *(args if args is not None else [self.record_path, "--owner-policy", self.policy_path])],
            cwd=self.root, env=environment, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, code, f"{result.stdout}\n{result.stderr}")
        return json.loads(result.stdout) if result.stdout else result.stderr

    def assert_reason(self, result, reason):
        self.assertEqual(result["version"], 1)
        return next(item for item in result["checks"] if item["reason"] == reason)

    def test_current_identity_is_pending_and_commands_are_data(self):
        marker = self.root / "should-not-exist"
        command = f"touch {marker}"
        self.record["evidence"]["baseline"] = [{
            "ref": "build.log", "revision": self.base_commit, "sha256": "a" * 64, "command": command,
        }]
        self.write_inputs()
        (self.layout / "state").mkdir()
        ticket = self.layout / "state/tickets.yaml"
        ticket.write_bytes(b"unchanged")
        before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        result = self.run_validate()
        self.assertEqual(result["status"], "pending")
        self.assertIsNotNone(datetime.fromisoformat(result["observed_at"]).utcoffset())
        self.assertEqual(self.assert_reason(result, "ref_matches")["observed_commit"], self.base_commit)
        self.assertEqual(self.assert_reason(result, "evidence_not_evaluated")["commands"], [
            {"purpose": "baseline", "ref": "build.log", "command": command},
        ])
        self.assertFalse(marker.exists())
        self.assertEqual(ticket.read_bytes(), b"unchanged")
        self.assertEqual(before, sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*")))

    def test_local_manifest_and_override_follow_cli_precedence(self):
        local = self.layout / "repos.local.yaml"
        local.write_bytes(self.manifest.read_bytes())
        self.assert_reason(self.run_validate(code=2), "manifest_path_mismatch")
        self.write_policy(manifest=local)
        self.assert_reason(self.run_validate(), "ref_matches")

        override = self.root / "override.yaml"
        override.write_bytes(local.read_bytes())
        self.write_policy(manifest=override)
        self.assert_reason(self.run_validate(override=override), "ref_matches")
        override.write_bytes(override.read_bytes() + b"\n")
        self.assert_reason(self.run_validate(override=override, code=2), "manifest_digest_mismatch")

    def test_enrollment_rejects_duplicate_name_and_canonical_path(self):
        alias = self.root / "alias"
        alias.symlink_to(self.checkout, target_is_directory=True)
        for duplicate in (self.enrollment, {"name": "different", "path": str(alias)}):
            with self.subTest(duplicate=duplicate):
                self.write_manifest(self.manifest, repos=[self.enrollment], community=[duplicate])
                self.write_policy()
                self.assert_reason(self.run_validate(code=2), "repo_enrollment_ambiguous")

    def test_checkout_remapping_and_parent_discovery_are_invalid(self):
        child = self.checkout / "child"
        child.mkdir()
        self.write_manifest(self.manifest, repos=[{"name": "sample", "path": str(child)}])
        self.write_policy()
        self.assert_reason(self.run_validate(code=2), "checkout_mismatch")
        self.write_policy(checkout=str(child))
        self.assert_reason(self.run_validate(code=2), "checkout_invalid")

    def test_git_repository_overrides_do_not_replace_enrollment(self):
        self.git("update-ref", "-d", REF)
        other_layout = self.root / "other"
        other_layout.mkdir()
        subprocess.run(["git", "clone", "-q", self.checkout, other_layout], check=True)
        subprocess.run(["git", "-C", other_layout, "update-ref", REF, self.base_commit], check=True)
        result = self.run_validate(env={
            "GIT_DIR": str(other_layout / ".git"),
            "GIT_WORK_TREE": str(self.checkout),
            "GIT_COMMON_DIR": str(other_layout / ".git"),
        })
        self.assert_reason(result, "ref_missing")

    def test_moved_ref_stays_pending_even_when_commits_share_a_tree(self):
        self.git("commit", "--allow-empty", "-qm", "same-tree successor")
        moved = self.git("rev-parse", "HEAD")
        self.assertEqual(self.git("rev-parse", "HEAD^{tree}"), self.git("rev-parse", f"{self.base_commit}^{{tree}}"))
        self.git("update-ref", REF, moved)
        observation = self.assert_reason(self.run_validate(), "ref_moved")
        self.assertEqual(observation["expected_commit"], self.base_commit)
        self.assertEqual(observation["observed_commit"], moved)

    def test_deleted_branch_is_pending_with_no_revision_dwim(self):
        self.git("update-ref", "-d", REF)
        for replacement in ("refs/tags/topic", "refs/remotes/origin/topic", "refs/heads/refs/heads/topic"):
            self.git("update-ref", replacement, self.base_commit)
        observation = self.assert_reason(self.run_validate(), "ref_missing")
        self.assertIsNone(observation["observed_commit"])
        self.assertEqual(observation["expected_commit"], self.base_commit)

    def test_symbolic_branch_does_not_confirm_literal_commit(self):
        self.git("symbolic-ref", REF, "refs/heads/main")
        self.assert_reason(self.run_validate(), "ref_symbolic")

    def test_later_git_worktrees_are_valid_canonical_enrollments(self):
        extra = self.root / "linked"
        self.git("worktree", "add", "-q", extra, "topic")
        self.assertTrue((extra / ".git").is_file())
        self.write_manifest(self.manifest, community=[{"name": "sample", "path": str(extra)}])
        self.write_policy(checkout=str(extra))
        self.assert_reason(self.run_validate(), "ref_matches")

    def test_revision_expressions_and_wrong_commit_length_are_invalid(self):
        for ref in ("topic", "refs/tags/topic", "refs/heads/topic^{commit}", "refs/heads/topic@{1}"):
            with self.subTest(ref=ref):
                self.record["ref"] = ref
                self.write_inputs()
                self.assert_reason(self.run_validate(code=2), "ref_invalid")
        self.record.update(ref=REF, base_commit="a" * 64)
        self.write_inputs()
        self.assert_reason(self.run_validate(code=2), "base_commit_format_invalid")

    def test_wrong_scope_and_bytes_are_invalid(self):
        for field in ("repo", "slice_id", "plan_revision"):
            with self.subTest(field=field):
                self.write_policy(**{field: "different"})
                self.assert_reason(self.run_validate(code=2), "policy_scope_mismatch")
        self.write_policy()
        self.record_path.write_bytes(self.record_path.read_bytes() + b"\n")
        self.assert_reason(self.run_validate(code=2), "record_digest_mismatch")
        self.record["repo"] = "foreign"
        self.write_inputs(repo="foreign")
        self.assert_reason(self.run_validate(code=2), "repo_not_enrolled")

    def test_malformed_documents_fail_closed(self):
        for key, value, reason in (
            ("version", True, "record_schema_invalid"),
            ("path", str(self.checkout), "record_schema_invalid"),
            ("base_commit", self.base_commit[:12], "record_identity_invalid"),
            ("evidence", {"baseline": "touch artifact"}, "record_evidence_invalid"),
        ):
            with self.subTest(key=key):
                original = dict(self.record)
                self.record[key] = value
                self.write_inputs()
                self.assert_reason(self.run_validate(code=2), reason)
                self.record = original
        self.write_inputs()
        duplicate = self.policy_path.read_text(encoding="utf-8").replace("{", '{"version": 1, ', 1)
        self.policy_path.write_text(duplicate, encoding="utf-8")
        self.assert_reason(self.run_validate(code=2), "policy_json_invalid")

    def test_manifest_merges_preserve_explicit_override_and_duplicates_fail(self):
        self.manifest.write_text(
            "version: 1\n"
            f"defaults: &enrollment {{name: other, path: {self.checkout}}}\n"
            "repos:\n  - <<: *enrollment\n    name: sample\n",
            encoding="utf-8",
        )
        self.write_policy()
        self.assert_reason(self.run_validate(), "ref_matches")
        self.manifest.write_bytes(self.manifest.read_bytes() + b"    name: foreign\n")
        self.write_policy()
        self.assert_reason(self.run_validate(code=2), "manifest_invalid")

    def test_malformed_explicit_yaml_scalars_are_invalid(self):
        for malformed in ("!!bool maybe", "!!timestamp hello", '!!int ""'):
            with self.subTest(malformed=malformed):
                self.write_manifest(self.manifest, repos=[self.enrollment])
                with self.manifest.open("a", encoding="utf-8") as handle:
                    handle.write(f"unused: {malformed}\n")
                self.write_policy()
                self.assert_reason(self.run_validate(code=2), "manifest_invalid")

    def test_policy_must_be_explicit_and_unique(self):
        error = self.run_validate(code=2, args=[self.record_path])
        self.assertIn("--owner-policy", error)
        error = self.run_validate(code=2, args=[
            self.record_path, "--owner-policy", self.policy_path, "--owner-policy", self.policy_path,
        ])
        self.assertIn("exactly once", error)
        result = self.run_validate(code=2, args=[self.record_path, "--owner-policy", self.record_path])
        self.assert_reason(result, "policy_not_separate")
