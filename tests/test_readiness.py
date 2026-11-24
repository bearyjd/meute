"""Exercise readiness v1 through the public Meute CLI with disposable repos."""

from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


MEUTE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MEUTE / "lib"))
import readiness  # noqa: E402
import report as report_lib  # noqa: E402

REF = "refs/heads/topic"
PURPOSES = ("docs", "codemap", "baseline", "acceptance", "audits")
FINDING = "sample/audit-1#1"
LOCATION, TITLE = "src/a.py:3", "Unsafe thing"
T0 = datetime(2026, 12, 1, 12, 0, tzinfo=timezone.utc)


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
        self.evidence_root = self.root / "evidence"
        self.evidence_root.mkdir()
        self.reports = self.layout / "reports/sample"
        self.assessment = {name: {"affirmed": True, "findings": {}} for name in ("security", "cleanup")}
        self.write_inputs()

    def disk_inventory(self):
        base = self.layout / "reports"
        return {
            str(path.relative_to(base)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(base.glob("*/*.md")) if path.is_file()
        }

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
            "report_inventory": self.disk_inventory(),
            "evidence_root": str(self.evidence_root),
            "attested_digests": [],
            "assessment": self.assessment,
            "deferrals": [],
            "accepted_conditions": [],
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

    # ----- 4.2 fixtures ---------------------------------------------------

    def report_text(self, count=1, repo="sample"):
        findings = "".join(
            f"### [HIGH] {TITLE} {n}\n- **Location:** `src/a.py:{n}`\n\n" if n > 1 else
            f"### [HIGH] {TITLE}\n- **Location:** `{LOCATION}`\n\n" for n in range(1, count + 1)
        )
        return (f"---\nrepo: {repo}\ntask: audit\nlens: security\nstatus: ok\n"
                f"started: 2026-01-01T00:00:00Z\nbase: sample@{self.base_commit}\n---\n"
                f"# Audit\n\n## Findings\n\n{findings}")

    def put_report(self, name="audit-1", directory="sample", **kwargs):
        target = self.layout / "reports" / directory
        target.mkdir(parents=True, exist_ok=True)
        (target / f"{name}.md").write_text(self.report_text(**kwargs), encoding="utf-8")
        return target / f"{name}.md"

    def put_zero_report(self, name="clean"):
        path = self.reports / f"{name}.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"---\nrepo: sample\ntask: audit\nstatus: ok\nstarted: 2026-01-02T00:00:00Z\n---\n"
                        "# Audit\n\nNothing found.\n", encoding="utf-8")
        return path

    def evidence_doc(self, kind, **overrides):
        return {"version": 1, "purpose": kind, **self.scope, "revision": self.base_commit,
                "outcome": "ok", "result": "pass", **overrides}

    def put_evidence(self, purpose, doc=None, *, name=None, directory=None, replace=False):
        directory = directory or self.evidence_root
        path = directory / (name or f"{purpose}.json")
        data = json.dumps(doc if doc is not None else self.evidence_doc(purpose)).encode()
        path.write_bytes(data)
        reference = {"ref": str(path) if directory != self.evidence_root else path.name,
                     "revision": self.base_commit, "sha256": hashlib.sha256(data).hexdigest()}
        self.record["evidence"][purpose] = [reference] if replace or not self.record["evidence"][purpose] \
            else [*self.record["evidence"][purpose], reference]
        return path

    def assess(self, applicable=False, ordinals=(1,), **extra):
        findings = {
            f"sample/audit-1#{n}": {
                "fingerprint": report_lib.fingerprint(
                    "sample", LOCATION if n == 1 else f"src/a.py:{n}", TITLE if n == 1 else f"{TITLE} {n}"),
                "applicable": applicable if n == 1 else extra.get("second", applicable),
            } for n in ordinals
        }
        self.assessment = {"security": {"affirmed": True, "findings": findings},
                           "cleanup": {"affirmed": True, "findings": {}}}

    def make_ready(self, **assess):
        self.put_report()
        self.assess(**assess)
        for purpose in PURPOSES:
            self.put_evidence(purpose, replace=True)
        self.write_inputs()

    def set_state(self, key, state):
        (self.layout / "state").mkdir(exist_ok=True)
        with (self.layout / "state/reports").open("a", encoding="utf-8") as handle:
            handle.write(f"{key}\t{state}\t2026-01-03\tnote\n")

    def set_resolved(self, key):
        """The state `meute resolve` really writes: actioned with a resolved note."""
        (self.layout / "state").mkdir(exist_ok=True)
        with (self.layout / "state/reports").open("a", encoding="utf-8") as handle:
            handle.write(f"{key}\tactioned\t2026-01-03\tresolved: fixed it\n")

    def fix(self, key=FINDING, **overrides):
        return {"id": key, "fingerprint": self.assessment["security"]["findings"][key]["fingerprint"],
                **overrides}

    def put_native(self, *, commit=None, status="ok", log_extra=b""):
        commit = commit or self.base_commit
        started = "2026-01-01T00:00:00Z"
        report = (f"---\nrepo: sample\ntask: sample/1\nslot: a\nengine: claude\nauth: sub\n"
                  f"base: sample@{commit}\nstarted: {started}\nstatus: {status}\n---\n# Audit\n").encode()
        (self.reports).mkdir(parents=True, exist_ok=True)
        (self.reports / "native.md").write_bytes(report)
        binding = {"task": "sample/1", "ref": "reports/sample/native.md", "source": "meute-runner",
                   "engine": "claude", "auth": "sub", "commit": commit, "started_at": started,
                   "outcome": status, "report_sha256": hashlib.sha256(report).hexdigest()}
        run_id = "a" * 32
        (self.layout / "state/evidence").mkdir(parents=True, exist_ok=True)
        (self.layout / "state/evidence" / f"{run_id}.json").write_text(json.dumps(binding), encoding="utf-8")
        code = {"ok": "ok", "error": "failed"}[status]
        line = (f"{started}\tweek=1\tslot=a\tcode={code}\tdur=5s\truntime=x\timage=y\tstage=z\tpr=n"
                f"\trepo=sample\ttask=sample/1\tengine=claude\tauth=sub\tstatus={status}"
                f"\treport=reports/sample/native.md\n").encode()
        (self.layout / "state/log").write_bytes(line + log_extra)
        self.put_evidence("audits", self.evidence_doc("audits", native={"run_id": run_id}), replace=True)
        self.write_inputs()

    def deferral(self, expires, finding=FINDING, **overrides):
        item = {"finding": finding, "fingerprint": self.assessment["security"]["findings"][finding]["fingerprint"],
                **self.scope, "reason": "tracked elsewhere", "expires_at": expires}
        return {**item, **overrides}

    def run_inline(self, *, now=T0, **options):
        clock = options.pop("clock", None) or (lambda: now)
        code, result = readiness.validate(
            self.record_path, self.policy_path, self.manifest, clock=clock, root=self.layout, **options)
        return code, result

    def assert_pending(self, reason, **options):
        code, result = self.run_inline(**options)
        self.assertEqual((code, result["status"]), (1, "pending"), result)
        return self.assert_reason(result, reason)

    def tree(self):
        return {str(p.relative_to(self.root)): p.read_bytes()
                for p in sorted(self.root.rglob("*")) if p.is_file() and ".git/" not in str(p)}

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
        self.assert_reason(result, "evidence_missing")
        self.assertEqual(result["status"], "pending")
        self.assertIsNotNone(datetime.fromisoformat(result["observed_at"]).utcoffset())
        self.assertEqual(self.assert_reason(result, "ref_matches")["observed_commit"], self.base_commit)
        self.assertEqual(self.assert_reason(result, "commands_not_executed")["commands"], [
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

    # ----- 4.2 acceptance -------------------------------------------------

    def test_fully_evidenced_fixture_is_ready_and_stable(self):
        self.make_ready()
        first = self.run_validate(code=0)
        self.assertEqual(first["status"], "ready")
        self.assertTrue(all(item["status"] == "passed" for item in first["checks"]))
        self.assertEqual(first["observed_at"][-6:], "+00:00")
        _, one = self.run_inline()
        _, two = self.run_inline()
        self.assertEqual(one["checks"], two["checks"])
        self.assertEqual(one, two)

    def test_zero_finding_report_is_accepted(self):
        self.make_ready()
        self.put_zero_report()
        self.write_inputs()
        self.assertEqual(self.run_validate(code=0)["status"], "ready")

    def test_ready_validation_does_not_mutate_anything(self):
        self.make_ready()
        self.set_state("sample/other#1", "promoted")
        before = self.tree()
        self.run_validate(code=0)
        self.assertEqual(before, self.tree())
        self.assertFalse((self.layout / "state/finding-status").exists())

    def test_hidden_finding_unaccounted_for_is_pending(self):
        self.make_ready()
        self.set_state(FINDING, "dismissed")
        self.assessment["security"]["findings"] = {}
        self.write_inputs()
        item = self.assert_pending("assessment_incomplete")
        self.assertEqual(item["findings"], [FINDING])

    def test_hidden_applicable_finding_still_blocks(self):
        self.make_ready(applicable=True)
        self.set_state(FINDING, "dismissed")
        self.assert_reason(self.run_validate(), "finding_open")

    def test_open_applicable_finding_is_pending_and_nonapplicable_is_not(self):
        self.make_ready(applicable=True)
        self.assert_reason(self.run_validate(), "finding_open")
        self.make_ready(applicable=False)
        self.assertEqual(self.run_validate(code=0)["status"], "ready")

    def test_unaffirmed_or_stale_fingerprint_assessment_is_pending(self):
        self.make_ready()
        self.assessment["cleanup"]["affirmed"] = False
        self.write_inputs()
        self.assert_reason(self.run_validate(), "assessment_not_affirmed")
        self.assess()
        self.assessment["security"]["findings"][FINDING]["fingerprint"] = "0" * 40
        self.write_inputs()
        self.assert_reason(self.run_validate(), "assessment_fingerprint_mismatch")

    def test_zero_finding_report_added_then_removed_is_pending(self):
        self.make_ready()
        added = self.put_zero_report()
        item = self.assert_pending("inventory_report_added")
        self.assertEqual(item["reports"], [{"path": "sample/clean.md", "reason": "inventory_report_added"}])
        self.write_inputs()
        self.assertEqual(self.run_validate(code=0)["status"], "ready")
        added.unlink()
        self.assert_reason(self.run_validate(), "inventory_report_removed")

    def test_malformed_and_unreadable_reports_are_pending_without_findings(self):
        self.make_ready()
        bad = self.reports / "broken.md"
        bad.write_bytes(b"no front matter at all\n")
        self.write_inputs()
        self.assert_reason(self.run_validate(), "report_malformed")
        bad.write_bytes(b"---\nrepo: sample\n---\n\xff\xfe\n")
        self.write_inputs()
        self.assert_reason(self.run_validate(), "report_malformed")
        bad.unlink()
        bad.symlink_to(self.root / "nowhere")
        self.write_inputs()
        self.assert_reason(self.run_validate(), "report_unreadable")

    def test_path_and_header_repo_mismatch_is_pending(self):
        self.make_ready()
        self.put_report("mislabelled", repo="other", count=0)
        self.write_inputs()
        self.assert_reason(self.run_validate(), "report_repo_mismatch")
        (self.reports / "mislabelled.md").unlink()
        self.put_report("foreign", directory="elsewhere", count=0)
        self.write_inputs()
        item = self.assert_reason(self.run_validate(), "report_repo_mismatch")
        self.assertEqual(item["reports"][0]["path"], "elsewhere/foreign.md")

    def test_changed_report_bytes_are_pending(self):
        self.make_ready()
        path = self.reports / "audit-1.md"
        path.write_bytes(path.read_bytes() + b"\nextra\n")
        self.assert_reason(self.run_validate(), "inventory_report_changed")

    def test_expired_and_exact_expiry_deferrals_do_not_defer(self):
        self.make_ready(applicable=True)
        expiry = T0 + timedelta(hours=1)
        stamp = expiry.isoformat().replace("+00:00", "Z")
        self.write_policy(deferrals=[self.deferral(stamp)])
        self.assertEqual(self.run_inline(now=expiry - timedelta(microseconds=1))[1]["status"], "ready")
        self.assert_pending("deferral_expired", now=expiry)
        self.assert_pending("deferral_expired", now=expiry + timedelta(seconds=1))

    def test_deferral_expiring_during_evaluation_is_pending(self):
        self.make_ready(applicable=True)
        expiry = T0 + timedelta(minutes=5)
        self.write_policy(deferrals=[self.deferral(expiry.isoformat())])
        ticks = iter([T0, expiry])
        self.assert_pending("deferral_expired_at_final", clock=lambda: next(ticks))

    def test_naive_or_non_utc_deferral_expiry_is_invalid(self):
        self.make_ready(applicable=True)
        for stamp in ("2099-01-01T00:00:00", "2099-01-01T00:00:00+02:00", "2099-01-01"):
            with self.subTest(stamp=stamp):
                self.write_policy(deferrals=[self.deferral(stamp)])
                self.assert_reason(self.run_validate(code=2), "policy_rules_invalid")

    def test_deferral_covers_only_its_named_finding_and_scope(self):
        self.make_ready(applicable=True, ordinals=(1, 2))
        self.put_report(count=2)
        later = "2099-01-01T00:00:00Z"
        self.write_policy(deferrals=[self.deferral(later)])
        item = self.assert_pending("finding_open")
        self.assertEqual(item["findings"], [{"id": "sample/audit-1#2", "reason": "finding_open"}])
        self.write_policy(deferrals=[self.deferral(later), self.deferral(later, "sample/audit-1#2")])
        self.assertEqual(self.run_inline()[1]["status"], "ready")
        self.write_policy(deferrals=[self.deferral(later, plan_revision="plan/v2"),
                                     self.deferral(later, "sample/audit-1#2", slice_id="other")])
        self.assert_pending("finding_open")

    def test_claimed_fix_needs_evidence_naming_the_finding(self):
        self.make_ready(applicable=True)
        self.set_resolved(FINDING)
        self.assert_reason(self.run_validate(), "fix_unverified")
        self.put_evidence("acceptance", self.evidence_doc("acceptance", fixes=[self.fix()]), replace=True)
        self.write_inputs()
        self.assertEqual(self.run_validate(code=0)["status"], "ready")

    def test_evidence_with_wrong_revision_failed_outcome_or_scope_is_pending(self):
        self.make_ready()
        cases = (
            ({"revision": "b" * 40}, "evidence_wrong_revision"),
            ({"outcome": "failed"}, "evidence_failed_outcome"),
            ({"result": "fail"}, "evidence_failed"),
            ({"plan_revision": "plan/v0"}, "evidence_wrong_scope"),
            ({"purpose": "docs"}, "evidence_wrong_purpose"),
        )
        for overrides, reason in cases:
            with self.subTest(reason=reason):
                self.put_evidence("acceptance", self.evidence_doc("acceptance", **overrides), replace=True)
                self.write_inputs()
                self.assert_reason(self.run_validate(), reason)

    def test_digest_mismatch_and_missing_evidence_are_pending(self):
        self.make_ready()
        (self.evidence_root / "docs.json").write_bytes(b"{}")
        self.assert_reason(self.run_validate(), "evidence_digest_mismatch")
        self.record["evidence"]["docs"] = []
        self.write_inputs()
        self.assert_reason(self.run_validate(), "evidence_missing")

    def test_unattested_copy_is_pending_until_operator_attests_its_digest(self):
        self.make_ready()
        copied = self.put_evidence("docs", directory=self.root, name="copy.json", replace=True)
        self.write_inputs()
        self.assert_reason(self.run_validate(), "evidence_unattested")
        self.write_policy(attested_digests=[hashlib.sha256(copied.read_bytes()).hexdigest()])
        self.assertEqual(self.run_validate(code=0)["status"], "ready")

    def test_exact_id_audit_envelope_alone_is_not_a_positive_result(self):
        self.make_ready()
        envelope = self.evidence_doc("audits")
        del envelope["result"]
        envelope["audit_claim_ids"] = {"ids": ["A-1", "A-2"]}
        self.put_evidence("audits", envelope, replace=True)
        self.write_inputs()
        self.assert_reason(self.run_validate(), "evidence_malformed")
        envelope = self.evidence_doc("audits")
        del envelope["result"]
        self.put_evidence("audits", envelope, replace=True)
        self.write_inputs()
        self.assert_reason(self.run_validate(), "evidence_result_missing")

    def test_native_evidence_without_trusted_runner_state_is_pending(self):
        self.make_ready()
        doc = self.evidence_doc("audits", native={"run_id": "0" * 32})
        self.put_evidence("audits", doc, replace=True)
        self.write_inputs()
        self.assert_reason(self.run_validate(), "evidence_native_unverified")

    def test_git_blob_evidence_is_verified_at_the_pinned_commit(self):
        doc = {key: value for key, value in self.evidence_doc("docs").items() if key != "revision"}
        (self.checkout / "docs.json").write_text(json.dumps(doc), encoding="utf-8")
        self.git("add", "docs.json")
        self.git("commit", "-qm", "evidence")
        self.record["base_commit"] = self.git("rev-parse", "HEAD")
        self.git("update-ref", REF, self.record["base_commit"])
        self.base_commit = self.record["base_commit"]
        self.make_ready()
        blob = self.git("rev-parse", "HEAD:docs.json")
        self.record["evidence"]["docs"] = [{"ref": "docs.json", "revision": self.base_commit, "git_blob": blob}]
        self.write_inputs()
        self.assertEqual(self.run_validate(code=0)["status"], "ready")
        self.record["evidence"]["docs"][0]["git_blob"] = "c" * 40
        self.write_inputs()
        self.assert_reason(self.run_validate(), "evidence_blob_mismatch")

    def test_missing_codemap_and_preexisting_baseline_failure_need_scoped_policy(self):
        self.make_ready()
        self.record["evidence"]["codemap"] = []
        self.write_inputs()
        self.assert_reason(self.run_validate(), "evidence_missing")
        rule = {"condition": "codemap_missing", **self.scope, "reason": "no codemap tooling"}
        self.write_policy(accepted_conditions=[{**rule, "slice_id": "other"}])
        self.assert_reason(self.run_validate(), "evidence_missing")
        self.write_policy(accepted_conditions=[rule])
        self.assertEqual(self.run_validate(code=0)["status"], "ready")
        failed = self.evidence_doc("baseline", result="fail", preexisting=True)
        self.put_evidence("baseline", failed, replace=True)
        self.write_inputs()
        self.assert_reason(self.run_validate(), "evidence_failed")
        self.write_policy(accepted_conditions=[
            rule, {**rule, "condition": "baseline_preexisting_failure", "reason": "documented"}])
        self.assertEqual(self.run_validate(code=0)["status"], "ready")

    def test_mutation_between_evaluation_and_final_recheck_is_pending(self):
        def mutate_ref():
            self.git("commit", "--allow-empty", "-qm", "same tree")
            self.git("update-ref", REF, self.git("rev-parse", "HEAD"))

        mutations = {
            "ref": mutate_ref,
            "manifest": lambda: self.manifest.write_bytes(self.manifest.read_bytes() + b"\n"),
            "policy": lambda: self.policy_path.write_bytes(self.policy_path.read_bytes() + b"\n"),
            "inventory": lambda: (self.reports / "audit-1.md").write_bytes(b"---\nrepo: sample\n---\nchanged\n"),
            "evidence": lambda: (self.evidence_root / "docs.json").write_bytes(b"{}"),
        }
        for key, mutate in mutations.items():
            with self.subTest(key=key):
                self.make_ready()
                self.git("update-ref", REF, self.base_commit)
                self.write_manifest(self.manifest, repos=[self.enrollment])
                self.write_inputs()
                self.assertEqual(self.run_inline()[0], 0)
                item = self.assert_pending("inputs_drifted", after_evaluation=mutate)
                self.assertIn(key, item["drifted"])

    def ready_with_fix(self, purpose="acceptance"):
        self.make_ready(applicable=True)
        self.set_resolved(FINDING)
        self.put_evidence(purpose, self.evidence_doc(purpose, fixes=[self.fix()]), replace=True)
        self.write_inputs()

    # ----- claimed fixes ---------------------------------------------------

    def test_real_resolve_state_with_bound_fix_is_ready(self):
        self.ready_with_fix()
        self.assertEqual(self.run_inline()[0], 0)
        self.ready_with_fix("audits")
        self.assertEqual(self.run_inline()[0], 0)

    def test_state_meute_never_writes_does_not_clear_a_blocker(self):
        self.ready_with_fix()
        (self.layout / "state/reports").unlink()
        self.set_state(FINDING, "resolved")
        self.assert_pending("finding_open")

    def test_actioned_without_resolved_note_is_open(self):
        self.ready_with_fix()
        (self.layout / "state/reports").unlink()
        self.set_state(FINDING, "actioned")
        self.assert_pending("finding_open")

    def test_fixes_from_docs_evidence_are_not_accepted(self):
        self.ready_with_fix()
        self.put_evidence("docs", self.evidence_doc("docs", fixes=[self.fix()]), replace=True)
        self.put_evidence("acceptance", replace=True)
        self.write_inputs()
        self.assert_pending("fix_unverified")

    def test_fixes_must_bind_the_fingerprint(self):
        self.ready_with_fix()
        for entry in (FINDING, self.fix(fingerprint="0" * 40), {"id": FINDING}):
            with self.subTest(entry=entry):
                self.put_evidence("acceptance", self.evidence_doc("acceptance", fixes=[entry]), replace=True)
                self.write_inputs()
                self.assert_pending("fix_unverified")

    # ----- decision state recheck -------------------------------------------

    def test_inbox_state_changed_after_evaluation_is_pending(self):
        self.ready_with_fix()
        self.assertEqual(self.run_inline()[0], 0)
        reopen = lambda: (self.layout / "state/reports").write_text(f"{FINDING}\tnew\t2026-01-04\tx\n")
        item = self.assert_pending("inputs_drifted", after_evaluation=reopen)
        self.assertIn("state", item["drifted"])

    def test_finding_status_changed_after_evaluation_is_pending(self):
        self.ready_with_fix()
        verdict = lambda: (self.layout / "state/finding-status").write_text(f"{FINDING}\tgone\tabc\t2026-01-04\t\n")
        item = self.assert_pending("inputs_drifted", after_evaluation=verdict)
        self.assertIn("state", item["drifted"])

    # ----- report parsing and scanning -------------------------------------

    def test_findings_section_with_unparseable_entries_is_malformed(self):
        self.make_ready()
        text = self.report_text().replace("### [HIGH] ", "### HIGH ").replace(f"- **Location:** `{LOCATION}`", "- **Location:** `x:1`")
        (self.reports / "bad.md").write_text(text.replace("audit", "audit2", 1), encoding="utf-8")
        self.write_inputs()
        self.assert_reason(self.run_validate(), "report_malformed")

    def test_symlinked_report_file_is_unreadable_not_skipped(self):
        self.make_ready()
        hidden = self.layout / "hidden.md"
        hidden.write_bytes((self.reports / "audit-1.md").read_bytes())
        (self.reports / "sneaky.md").symlink_to(hidden)
        self.write_inputs()
        item = self.assert_reason(self.run_validate(), "report_unreadable")
        self.assertIn({"path": "sample/sneaky.md", "reason": "report_unreadable"}, item["reports"])

    def test_symlinked_repo_directory_is_unreadable(self):
        self.make_ready()
        real = self.layout / "elsewhere"
        real.mkdir()
        (self.reports / "audit-1.md").rename(real / "audit-1.md")
        self.reports.rmdir()
        self.reports.symlink_to(real, target_is_directory=True)
        self.write_inputs()
        self.assert_reason(self.run_validate(), "report_unreadable")

    def test_md_directory_under_repo_is_unreadable(self):
        self.make_ready()
        (self.reports / "odd.md").mkdir()
        self.write_inputs()
        self.assert_reason(self.run_validate(), "report_unreadable")

    def test_symlinked_report_file_in_another_repo_directory_is_unreadable(self):
        self.make_ready()
        other = self.layout / "reports/other"
        other.mkdir()
        hidden = self.layout / "hidden.md"
        hidden.write_bytes((self.reports / "audit-1.md").read_bytes())
        (other / "sneaky.md").symlink_to(hidden)
        self.write_inputs()
        item = self.assert_reason(self.run_validate(), "report_unreadable")
        self.assertIn({"path": "other/sneaky.md", "reason": "report_unreadable"}, item["reports"])

    def test_symlinked_directory_under_reports_is_unreadable(self):
        self.make_ready()
        real = self.layout / "elsewhere"
        real.mkdir()
        (self.layout / "reports/other").symlink_to(real, target_is_directory=True)
        self.write_inputs()
        item = self.assert_reason(self.run_validate(), "report_unreadable")
        self.assertIn({"path": "other/", "reason": "report_unreadable"}, item["reports"])

    def test_findings_section_with_some_unparseable_entries_is_malformed(self):
        self.make_ready()
        text = self.report_text() + "\n### HIGH missing brackets\n- **Location:** `x:1`\n"
        (self.reports / "partial.md").write_text(text, encoding="utf-8")
        self.write_inputs()
        self.assert_reason(self.run_validate(), "report_malformed")

    def test_finding_style_heading_outside_findings_section_stays_clean(self):
        self.make_ready()
        text = self.report_text(count=0) + "None.\n\n## Notes\n\n### Background\nprose\n"
        (self.reports / "notes.md").write_text(text, encoding="utf-8")
        self.write_inputs()
        self.assertEqual(self.run_validate(code=0)["status"], "ready")

    def test_unreadable_unrelated_directory_is_ignored_and_noted(self):
        self.make_ready()
        other = self.layout / "reports/other"
        other.mkdir()
        other.chmod(0)
        self.addCleanup(other.chmod, 0o755)
        if os.access(other, os.R_OK):
            self.skipTest("permissions are not enforced for this user")
        self.write_inputs()
        result = self.run_validate(code=0)
        inventory = next(c for c in result["checks"] if c["check"] == "inventory")
        self.assertEqual(inventory["ignored_unreadable"], ["other/"])

    def test_severity_policy_is_not_a_policy_field(self):
        self.make_ready()
        self.write_policy(severity_policy=["CRITICAL"])
        self.assert_reason(self.run_validate(code=2), "policy_schema_invalid")

    def test_unreadable_enrolled_repo_directory_is_pending_json_not_a_traceback(self):
        self.make_ready()
        self.reports.chmod(0)
        self.addCleanup(self.reports.chmod, 0o755)
        if os.access(self.reports, os.R_OK):
            self.skipTest("permissions are not enforced for this user")
        self.write_inputs()
        self.assert_pending("report_unreadable")

    def test_unexpected_evaluation_error_is_pending_json(self):
        self.make_ready()
        original = readiness.evaluate
        self.addCleanup(setattr, readiness, "evaluate", original)
        def boom(*args):
            raise RuntimeError("/secret/path")
        readiness.evaluate = boom
        code, result = self.run_inline()
        self.assertEqual((code, result["status"]), (1, "pending"))
        self.assertNotIn("/secret/path", json.dumps(result))

    # ----- evidence trust --------------------------------------------------

    def test_evidence_through_a_symlinked_directory_out_of_root_is_unattested(self):
        self.make_ready()
        outside = self.root / "outside"
        outside.mkdir()
        (self.evidence_root / "link").symlink_to(outside, target_is_directory=True)
        data = json.dumps(self.evidence_doc("docs")).encode()
        (outside / "ev.json").write_bytes(data)
        self.record["evidence"]["docs"] = [{"ref": "link/ev.json", "revision": self.base_commit,
                                            "sha256": hashlib.sha256(data).hexdigest()}]
        self.write_inputs()
        self.assert_pending("evidence_unattested")

    def test_git_blob_is_not_trusted_for_run_purposes(self):
        doc = {key: value for key, value in self.evidence_doc("acceptance").items() if key != "revision"}
        (self.checkout / "acceptance.json").write_text(json.dumps(doc), encoding="utf-8")
        self.git("add", "acceptance.json")
        self.git("commit", "-qm", "evidence")
        self.record["base_commit"] = self.base_commit = self.git("rev-parse", "HEAD")
        self.git("update-ref", REF, self.base_commit)
        self.make_ready()
        self.record["evidence"]["acceptance"] = [{
            "ref": "acceptance.json", "revision": self.base_commit,
            "git_blob": self.git("rev-parse", "HEAD:acceptance.json")}]
        self.write_inputs()
        self.assert_pending("evidence_blob_untrusted")

    def test_native_evidence_with_runner_state_is_ready(self):
        self.make_ready()
        self.put_native()
        self.assertEqual(self.run_inline()[0], 0)

    def test_native_evidence_wrong_revision_and_failed_outcome_are_pending(self):
        self.make_ready()
        self.put_native(commit="b" * 40)
        self.assert_pending("evidence_wrong_revision")
        self.put_native(status="error")
        self.assert_pending("evidence_failed_outcome")

    def test_native_digest_change_after_evaluation_is_pending(self):
        self.make_ready()
        self.put_native()
        grow = lambda: (self.layout / "state/log").write_bytes(
            (self.layout / "state/log").read_bytes() + b"unrelated\tline\n")
        item = self.assert_pending("inputs_drifted", after_evaluation=grow)
        self.assertIn("evidence", item["drifted"])

    # ----- accepted conditions ----------------------------------------------

    def test_baseline_condition_does_not_accept_a_missing_codemap(self):
        self.make_ready()
        self.record["evidence"]["codemap"] = []
        self.write_inputs()
        rule = {"condition": "baseline_preexisting_failure", **self.scope, "reason": "documented"}
        self.write_policy(accepted_conditions=[rule])
        self.assert_pending("evidence_missing")
