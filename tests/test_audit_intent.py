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
            '[[ "$*" == "auth status --json" ]] || exit 77\n'
            "echo '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"max\"}'\n"
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
        self.data["repos"] = [{
            "name": "target", "path": str(self.repo), "spec": "Fixture repo",
            "default_branch": "main", "tasks": ["audit-intent"],
        }]
        self.write_manifest()
        self.assertEqual(self.manifest_cmd("queue", "daily").stdout, "")
        entry = json.loads(self.manifest_cmd("queue", "weekly").stdout)
        self.assertEqual(entry["tier"], "tier2")
        self.assertEqual(entry["tools"], "Read,Grep,Glob")
        self.assertFalse(entry["writes_code"])
        self.invoke("bin/run.sh", "weekly", "--source", "manifest", "--repo", "target",
                    "--task", "audit-intent", "--dry-run", "--strict-exit")
        prompt = (self.harness / "state" / "dry-run-prompt.md").read_text()
        for expected in (self.sha, "Fixture repo", "README", "PRP", "intent:", "unverified"):
            with self.subTest(expected=expected):
                self.assertIn(expected, prompt)
        self.assertNotIn("{{BASE_SHA}}", prompt)
        self.assertEqual(self.git("for-each-ref", "--format=%(refname)", "refs/heads"), "refs/heads/main\n")

    def test_portfolio_setting_must_be_a_boolean(self):
        self.data["tasks"].setdefault("audit-intent", {
            "tier": "tier2", "template": "tasks/architecture-review.md",
        })["portfolio"] = "false"
        self.write_manifest()
        result = self.manifest_cmd("validate", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("tasks.audit-intent.portfolio", result.stderr)
