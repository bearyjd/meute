"""lib/inbox.py names the report paths it could not read instead of dropping them."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MEUTE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MEUTE / "lib"))
import inbox  # noqa: E402

REPORT = "---\nrepo: {repo}\ntask: audit\nstatus: ok\n---\n# Audit\n\n## Findings\n\n### [LOW] Thing\n- **Location:** `a.py:1`\n"


class InboxUnreadableTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for repo in ("sample", "other"):
            (self.root / "reports" / repo).mkdir(parents=True)
            (self.root / "reports" / repo / "audit.md").write_text(REPORT.format(repo=repo), encoding="utf-8")
        self.addCleanup(setattr, inbox, "ROOT", inbox.ROOT)
        inbox.ROOT = str(self.root)

    def lock(self, path, mode):
        path.chmod(mode)
        self.addCleanup(path.chmod, 0o755)
        if os.access(path, os.R_OK | os.X_OK):
            self.skipTest("permissions are not enforced for this user")

    def cli(self, *args):
        return subprocess.run(
            [sys.executable, str(MEUTE / "lib/inbox.py"), *args], capture_output=True, text=True,
            env={**os.environ, "MEUTE_ROOT": str(self.root)}, timeout=30)

    def test_readable_tree_has_nothing_skipped_and_no_note(self):
        self.assertEqual(inbox.scan_report_ids(), (["other/audit", "sample/audit"], []))
        result = self.cli("counts")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "reports_new=2\n", ""))

    def test_unlistable_directory_is_skipped_and_named(self):
        self.lock(self.root / "reports/other", 0)
        self.assertEqual(inbox.scan_report_ids(), (["sample/audit"], ["other/"]))
        for name in ("load_status", "load_branches"):  # both shell out to bin/meute
            self.addCleanup(setattr, inbox, name, getattr(inbox, name))
            setattr(inbox, name, lambda: None)
        self.assertEqual(inbox.dump()["unreadable"], ["other/"])
        result = self.cli("counts")
        self.assertEqual((result.returncode, result.stdout), (0, "reports_new=1\n"))
        self.assertIn("meute: skipping unreadable reports path other/", result.stderr)
        result = self.cli("findings", "--all", "--json")
        self.assertEqual(result.returncode, 0)
        self.assertEqual([f["id"] for f in json.loads(result.stdout)], ["sample/audit#1"])
        self.assertIn("other/", result.stderr)

    def test_listable_but_unsearchable_directory_names_each_report(self):
        self.lock(self.root / "reports/other", 0o644)
        self.assertEqual(inbox.scan_report_ids(), (["sample/audit"], ["other/audit.md"]))

    def test_unsearchable_reports_root_names_every_directory(self):
        self.lock(self.root / "reports", 0o644)
        self.assertEqual(inbox.scan_report_ids(), ([], ["other/", "sample/"]))
        self.assertEqual(self.cli("counts").returncode, 0)

    def test_symlinked_reports_root_lists_nothing_like_find(self):
        (self.root / "reports").rename(self.root / "real")
        (self.root / "reports").symlink_to(self.root / "real", target_is_directory=True)
        self.assertEqual(inbox.scan_report_ids(), ([], ["reports/"]))

    def test_symlinked_report_directory_is_skipped_and_named(self):
        (self.root / "real").mkdir()
        (self.root / "real/audit.md").write_text(REPORT.format(repo="linked"), encoding="utf-8")
        (self.root / "reports/linked").symlink_to(self.root / "real", target_is_directory=True)
        (self.root / "reports/stray.txt").write_text("not a directory\n", encoding="utf-8")
        self.assertEqual(inbox.scan_report_ids(), (["other/audit", "sample/audit"], ["linked/"]))
        self.assertIn("meute: skipping unreadable reports path linked/", self.cli("counts").stderr)

    def test_dump_scans_reports_once_and_reports_both_lists(self):
        self.lock(self.root / "reports/other", 0)
        for name in ("load_status", "load_branches"):
            self.addCleanup(setattr, inbox, name, getattr(inbox, name))
            setattr(inbox, name, lambda: None)
        calls = []
        real = inbox.scan_report_ids
        self.addCleanup(setattr, inbox, "scan_report_ids", real)
        inbox.scan_report_ids = lambda *args: calls.append(args) or real(*args)
        dumped = inbox.dump()
        self.assertEqual(len(calls), 1)
        self.assertEqual((dumped["unreadable"], [r["id"] for r in dumped["reports"]]), (["other/"], ["sample/audit"]))

    def test_root_parameter_reads_another_tree_without_touching_the_global(self):
        (self.root / "state").mkdir()
        (self.root / "state/reports").write_text("sample/audit#1\tdismissed\t2026-01-03\twont-fix\n", encoding="utf-8")
        inbox.finding_status.write_status(str(self.root), {"other/audit#1": ["gone", "", "", ""]})
        inbox.ROOT = str(self.root / "nowhere")
        self.assertEqual(inbox.scan_report_ids(str(self.root)), (["other/audit", "sample/audit"], []))
        reports, findings = inbox.load_reports(str(self.root))
        self.assertEqual([r["id"] for r in reports], ["other/audit", "sample/audit"])
        self.assertEqual({f"{f['report']}#{f['n']}": (f["state"], f["verdict"]) for f in findings},
                         {"other/audit#1": ("new", "gone"), "sample/audit#1": ("dismissed", "")})
        self.assertEqual(inbox.ROOT, str(self.root / "nowhere"))
        self.assertEqual(inbox.load_reports(), ([], []))

    def test_missing_reports_root_is_simply_empty(self):
        inbox.ROOT = str(self.root / "nowhere")
        self.assertEqual(inbox.scan_report_ids(), ([], []))


if __name__ == "__main__":
    unittest.main()
