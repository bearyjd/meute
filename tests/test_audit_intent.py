"""Exercise audit-intent through the native manifest, planner and runner."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


class AuditIntentTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.harness = self.home / "harness"
        self.harness.mkdir()
        for name in ("bin", "lib", "tasks"):
            (self.harness / name).symlink_to(ROOT / name, target_is_directory=True)
        (self.harness / "state").mkdir()
        self.manifest = self.harness / "repos.local.yaml"
        self.data = yaml.safe_load((ROOT / "repos.yaml").read_text())
        self.repo = self.home / "target"
        self.repo.mkdir()
        (self.repo / "README.md").write_text("# Fixture\nSupports a queue.\n")
        self.git("init", "-q", "-b", "main")
        self.git("add", "README.md")
        self.git("-c", "user.name=fixture", "-c", "user.email=fixture@example.test",
                 "commit", "-qm", "Fixture")
        self.sha = self.git("rev-parse", "HEAD").strip()
        stub = self.home / "stub"
        stub.mkdir()
        claude = stub / "claude"
        claude.write_text(
            "#!/usr/bin/env bash\n"
            'if [[ "$*" == "auth status --json" ]]; then\n'
            "  echo '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"max\"}'\n"
            "  exit 0\n"
            "fi\n"
            '[[ "$1" == "-p" && -n "${AUDIT_STUB_REPORT:-}" ]] || exit 77\n'
            '[[ "$(git rev-parse HEAD)" == "$AUDIT_STUB_SHA" ]] || exit 78\n'
            'printf "%s\\n" "$2" > "$AUDIT_STUB_PROMPT"\n'
            'cat README.md > "$AUDIT_STUB_SOURCE"\n'
            'jq -n --rawfile result "$AUDIT_STUB_REPORT" \'{result: $result, is_error: false}\'\n'
        )
        claude.chmod(0o700)
        load = self.home / "loadavg"
        load.write_text("0.10 0.10 0.10 1/100 1\n")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("MEUTE_")}
        self.env.update(
            PATH=f"{stub}{os.pathsep}{os.environ['PATH']}",
            MEUTE_CLAUDE_QUOTA_CMD="echo 100",
            MEUTE_SCOPE="off",
            MEUTE_LOADAVG=str(load),
            MEUTE_NCPU="4",
        )
        self.write_manifest()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", self.repo, *args], text=True)

    def write_manifest(self):
        self.manifest.write_text(yaml.safe_dump(self.data, sort_keys=False))

    def invoke(self, *args, check=True, input=None):
        return subprocess.run(
            args, cwd=self.harness, env=self.env, input=input, text=True,
            capture_output=True, check=check, timeout=20,
        )

    def manifest_cmd(self, command, *args, check=True):
        return self.invoke(sys.executable, "lib/manifest.py", command, self.manifest, *args,
                           check=check)

    def enroll(self):
        self.data["repos"] = [{
            "name": "target", "path": str(self.repo), "spec": "Fixture repo",
            "default_branch": "main", "tasks": ["audit-intent"],
        }]
        self.write_manifest()

    def runner(self, *args, check=True):
        result = self.invoke("bin/run.sh", "weekly", "--source", "manifest", "--repo", "target",
                             "--task", "audit-intent", "--strict-exit", *args, check=check)
        self.assertEqual(list((self.harness / "state" / "tmp").iterdir()), [])
        return result

    def audit_tool(self, *args, check=True, input=None):
        return self.invoke(sys.executable, "lib/audit_intent.py", *args, check=check, input=input)

    def save_claims(self, revision=None):
        claim = {"path": "README.md", "section": "fixture", "key": "queue",
                 "title": "Supports a queue", "start_line": 1, "end_line": 2}
        claims = {"version": 1, "revision": revision or self.sha, "claims": [
            claim, {**claim, "key": "source", "id": "REQ/7", "title": "Shares the same source"},
        ]}
        path = self.home / "claims.json"
        path.write_text(json.dumps(claims))
        return path

    def stub_report(self, ids=None, *, version=1):
        report = self.home / "engine-report.md"
        prompt = self.home / "engine-prompt.md"
        self.env.update(AUDIT_STUB_REPORT=str(report), AUDIT_STUB_SHA=self.sha,
                        AUDIT_STUB_PROMPT=str(prompt), AUDIT_STUB_SOURCE=str(self.home / "readme.md"))
        body = "## Summary\n\nShared evidence in README.md:1–2.\n\n## Coverage\n\nREADME.md\n"
        if ids is not None:
            payload = {"version": version, "results": [{"id": value, "verdict": "implemented"}
                                                       for value in ids]}
            body += f"\n```audit-intent-results\n{json.dumps(payload)}\n```\n"
        report.write_text(body)
        return prompt

    def report(self):
        reports = (self.harness / "reports" / "target").glob("*.md")
        return max(reports, key=lambda path: path.stat().st_mtime_ns)

    def test_registered_task_never_appears_in_the_portfolio_or_staged_queue(self):
        self.assertEqual(self.data["tasks"]["audit-intent"]["portfolio"], False)
        planned = json.loads(self.invoke("bin/meute", "plan", "--json", self.home).stdout)
        tasks = {item["task"] for item in planned["items"]}
        self.assertIn("audit-security", tasks)
        self.assertNotIn("audit-intent", tasks)
        self.invoke("bin/meute", "plan", "--enqueue", "--allow-web", "--only", self.repo,
                    self.home)
        queue = json.loads((self.harness / "state" / "plan-queue.json").read_text())
        tasks = {entry["task"] for entry in queue["entries"]}
        self.assertIn("market-comparison", tasks)
        self.assertNotIn("audit-intent", tasks)

    def test_forged_staged_audit_intent_is_refused(self):
        forged = self.harness / "state" / "forged.json"
        forged.write_text(json.dumps({
            "version": 1, "allow_web": True,
            "entries": [{"name": "target", "path": str(self.repo), "task": "audit-intent"}],
        }))
        result = self.manifest_cmd("plan-queue", forged, "weekly", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires explicit enrollment", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_discover_requires_explicit_task_selection(self):
        result = self.invoke("bin/meute", "discover", self.home, input="1\n\nFixture repo\n")
        self.assertRegex(result.stderr, r"\[ \]\s+\d+\) audit-intent")
        saved = yaml.safe_load(self.manifest.read_text())
        self.assertEqual(len(saved["repos"]), 1)
        self.assertNotIn("audit-intent", saved["repos"][0]["tasks"])

    def test_explicit_weekly_enrollment_renders_the_pinned_audit(self):
        self.enroll()
        self.assertEqual(self.manifest_cmd("queue", "daily").stdout, "")
        entry = json.loads(self.manifest_cmd("queue", "weekly").stdout)
        self.assertEqual(entry["tier"], "tier2")
        self.assertEqual(entry["tools"], "Read,Grep,Glob")
        self.assertFalse(entry["writes_code"])
        self.runner("--dry-run")
        prompt = (self.harness / "state" / "dry-run-prompt.md").read_text()
        for expected in (self.sha, "Fixture repo", "README", "PRP", "intent:", "unverified"):
            with self.subTest(expected=expected):
                self.assertIn(expected, prompt)
        self.assertNotIn("{{BASE_SHA}}", prompt)
        self.assertEqual(self.git("for-each-ref", "--format=%(refname)", "refs/heads"), "refs/heads/main\n")

    def test_exact_ids_replay_from_two_normal_runner_reports(self):
        self.enroll()
        claim_file = self.save_claims()
        prepared = self.audit_tool("prepare", claim_file, self.repo, self.sha).stdout
        self.assertEqual(prepared, self.audit_tool("prepare", claim_file, self.repo, self.sha).stdout)
        ids = [claim["id"] for claim in json.loads(prepared)["claims"]]
        self.assertRegex(ids[1], r"^intent:[0-9a-f]{64}$")
        self.assertEqual(ids[0], "REQ/7")
        for returned_ids in (ids, ids[::-1]):
            prompt = self.stub_report(returned_ids)
            self.runner("--audit-claims", claim_file)
            self.assertIn(prepared, prompt.read_text())
            self.assertIn("audit_claim_ids: verified", self.report().read_text())
            replay = json.loads(self.audit_tool("verify", claim_file, self.report()).stdout)
            self.assertEqual(replay, {"audit_claim_ids": "verified", "ids": ids})
        self.assertEqual(len(list((self.harness / "reports" / "target").glob("*.md"))), 2)
        modified = json.loads(claim_file.read_text())
        modified["claims"][0]["title"] = "New display title"
        claim_file.write_text(json.dumps(modified))
        prepared_again = self.audit_tool("prepare", claim_file, self.repo, self.sha).stdout
        self.assertEqual(ids, [claim["id"] for claim in json.loads(prepared_again)["claims"]])
        replay = self.audit_tool("verify", claim_file, self.report(), check=False)
        self.assertEqual(replay.returncode, 1)
        self.assertIn("different claim list", replay.stdout)

    def test_invalid_result_fails_runner_and_preserves_markdown(self):
        self.enroll()
        claim_file = self.save_claims()
        ids = [claim["id"] for claim in json.loads(self.audit_tool(
            "prepare", claim_file, self.repo, self.sha).stdout)["claims"]]
        for actual, version, reason in (
            (ids[:1], 1, "missing audit claim IDs"),
            (ids + ids[:1], 1, "duplicate audit claim IDs"),
            (ids + ["UNKNOWN"], 1, "unknown audit claim IDs"),
            (ids + ["invalid ID"], 1, "has a malformed ID"),
            (ids, True, "expected a version 1 audit results document"),
            (None, 1, "expected exactly one audit-intent-results block"),
        ):
            with self.subTest(reason=reason):
                self.stub_report(actual, version=version)
                run = self.runner("--audit-claims", claim_file, check=False)
                self.assertEqual(run.returncode, 1, run.stderr)
                self.assertIn(reason, run.stderr)
                report = self.report()
                self.assertIn("audit_claim_ids: unverified", report.read_text())
                self.assertIn("## Summary", report.read_text())
                replay = self.audit_tool("verify", claim_file, report, check=False)
                self.assertEqual(replay.returncode, 1)
                self.assertEqual(json.loads(replay.stdout)["audit_claim_ids"], "unverified")

    def test_results_require_one_final_standalone_block(self):
        claim_file = self.save_claims()
        ids = [claim["id"] for claim in json.loads(self.audit_tool(
            "prepare", claim_file, self.repo, self.sha).stdout)["claims"]]
        self.stub_report(ids)
        body = Path(self.env["AUDIT_STUB_REPORT"]).read_text()
        block = body[body.index("```audit-intent-results"):]
        for malformed, reason in (
            ("````markdown\n" + block, "expected exactly one"),
            ("<!--\n" + block, "expected exactly one"),
            (body + block, "expected exactly one"),
            (body + "Trailing prose\n", "block must end the report"),
            (body.replace('"version": 1', '"version": 1, "version": 1'), "duplicate JSON field"),
        ):
            with self.subTest(reason=reason):
                result = self.audit_tool("check-output", claim_file, check=False, input=malformed)
                self.assertEqual(result.returncode, 1)
                self.assertIn(reason, result.stderr)

    def test_bad_claim_list_stops_before_dispatch(self):
        self.enroll()
        prompt = self.stub_report([])
        for field, value, reason in (
            ("path", "missing.md", "not a tracked regular file"),
            ("path", "../README.md", "invalid repo-relative path"),
            ("path", "untracked.md", "not a tracked regular file"),
            ("end_line", 3, "exceed the pinned file"),
            ("id", "REQ/7", "duplicate input IDs"),
            ("id", "bad id", "malformed ID"),
            ("revision", "0" * 40, "does not match selected audit commit"),
        ):
            with self.subTest(field=field, value=value):
                (self.repo / "untracked.md").touch()
                claim_file = self.save_claims()
                data = json.loads(claim_file.read_text())
                target = data if field == "revision" else data["claims"][0]
                target[field] = value
                claim_file.write_text(json.dumps(data))
                run = self.runner("--audit-claims", claim_file, check=False)
                self.assertEqual(run.returncode, 1, run.stderr)
                self.assertIn(reason, run.stderr)
                self.assertFalse(prompt.exists())

    def test_claim_list_and_prompt_size_limits_cleanup_after_rejection(self):
        self.enroll()
        claim_file = self.save_claims()
        original = claim_file.read_bytes()
        full = original.ljust(16 * 1024)
        claim_file.write_bytes(full)
        self.runner("--audit-claims", claim_file, "--dry-run")
        prompt = self.harness / "state" / "dry-run-prompt.md"
        valid_prompt = prompt.read_bytes()

        data = json.loads(original)
        normalized_large = {**data, "claims": [{**data["claims"][0], "title": "é" * 3500}]}
        too_many = {**data, "claims": [{**data["claims"][0], "id": f"REQ-{i}"} for i in range(26)]}
        for contents, reason in (
            (full + b" ", "claim list exceeds 16 KiB"),
            (json.dumps(normalized_large, ensure_ascii=False).encode(), "normalized claim list exceeds 16 KiB"),
            (json.dumps(too_many).encode(), "must contain 1 to 25 claims"),
        ):
            with self.subTest(reason=reason):
                claim_file.write_bytes(contents)
                run = self.runner("--audit-claims", claim_file, "--dry-run", check=False)
                self.assertEqual(run.returncode, 1, run.stderr)
                self.assertIn(reason, run.stderr)
                self.assertEqual(prompt.read_bytes(), valid_prompt)

        claim_file.write_bytes(original)
        self.data["repos"][0]["spec"] = "x" * (96 * 1024)
        self.write_manifest()
        run = self.runner("--audit-claims", claim_file, "--dry-run", check=False)
        self.assertEqual(run.returncode, 1, run.stderr)
        self.assertIn("pinned audit prompt exceeds 96 KiB", run.stderr)
        self.assertEqual(prompt.read_bytes(), valid_prompt)

    def test_pinned_audit_never_overlays_dirty_source(self):
        self.enroll()
        self.data["repos"][0]["worktree_files"] = ["README.md"]
        self.write_manifest()
        tracked = (self.repo / "README.md").read_text()
        (self.repo / "README.md").write_text("Dirty source overlay\n")
        claim_file = self.save_claims()
        ids = [claim["id"] for claim in json.loads(self.audit_tool(
            "prepare", claim_file, self.repo, self.sha).stdout)["claims"]]
        self.stub_report(ids)
        run = self.runner("--audit-claims", claim_file)
        self.assertIn("without worktree file overlays", run.stderr)
        captured = Path(self.env["AUDIT_STUB_SOURCE"])
        self.assertEqual(captured.read_text(), tracked)
        self.stub_report()
        self.runner()
        self.assertEqual(captured.read_text(), "Dirty source overlay\n")

    def test_free_form_and_preexisting_reports_remain_readable(self):
        self.enroll()
        claim_file = self.save_claims()
        self.stub_report()
        self.runner()
        report = self.report()
        text = report.read_text()
        self.assertIn("audit_claim_ids: unvalidated", text)
        for saved in (text, text.replace("audit_claim_ids: unvalidated\n", "")):
            report.write_text(saved)
            read = self.invoke(sys.executable, "lib/report.py", "meta", report)
            self.assertEqual(json.loads(read.stdout)["task"], "audit-intent")
            replay = self.audit_tool("verify", claim_file, report, check=False)
            self.assertEqual(replay.returncode, 1)
            self.assertEqual(json.loads(replay.stdout)["audit_claim_ids"], "unvalidated")

    def test_portfolio_setting_must_be_a_boolean(self):
        self.data["tasks"].setdefault("audit-intent", {
            "tier": "tier2", "template": "tasks/architecture-review.md",
        })["portfolio"] = "false"
        self.write_manifest()
        result = self.manifest_cmd("validate", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("tasks.audit-intent.portfolio", result.stderr)
