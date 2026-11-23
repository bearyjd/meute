"""Exercise the publisher through the installed CLI entry point."""

import hashlib
import json
import subprocess
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

MEUTE = Path(__file__).resolve().parents[1] / "bin" / "meute"


class EvidenceExportTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.output = self.root / "snapshot.json"
        self.report = self.root / "review.md"
        self.commit = "a" * 40
        self.report.write_text(
            "---\nrepo: sample-repo\ntask: native-review\nslot: weekly\nengine: codex\n"
            f"auth: codex/chatgpt\nbase: main@{self.commit}\n"
            "started: 2025-01-02T03:04:05-05:00\nstatus: ok\n---\n"
            "Task: sample/0002\nPrivate review body.\n",
            encoding="utf-8",
        )
        self.provenance = {
            "task": "sample/0001",
            "ref": "reports/sample-repo/review.md",
            "source": "meute-runner",
            "engine": "codex",
            "auth": "codex/chatgpt",
            "commit": self.commit,
            "started_at": "2025-01-02T03:04:05-05:00",
            "outcome": "ok",
            "report_sha256": hashlib.sha256(self.report.read_bytes()).hexdigest(),
        }
        self.binding = self.write_provenance("source.json")
        self.log = self.root / "log"
        self.log_line = (
            f"{self.provenance['started_at']}\tweek=2025-01\tslot=weekly\tstatus=ok"
            "\tkind=personal\trepo=sample-repo\ttask=native-review\ttier=tier2"
            "\tlens=boundaries\tengine=codex\tauth=codex/chatgpt\tbranch=meute/review"
            f"\treport={self.provenance['ref']}\tcode=ok\tdur=1s"
            "\truntime=host\timage=-\tstage=-\tpr=-\n"
        )
        self.log.write_text(self.log_line, encoding="utf-8")

    def write_provenance(self, name, **overrides):
        path = self.root / name
        path.write_text(json.dumps(self.provenance | overrides), encoding="utf-8")
        return path

    def export(self, *bindings, output=None, log=None):
        args = [
            MEUTE, "evidence", "export", "--project", "sample",
            "--output", output or self.output,
        ]
        for binding in bindings or (self.binding,):
            if isinstance(binding, tuple):
                args.extend(["--record", *binding])
            else:
                args.extend(["--record", binding, self.report, log or self.log])
        return subprocess.run(args, capture_output=True, text=True, check=False)

    def test_exports_only_explicit_attribution_and_collapses_identical_rows(self):
        result = self.export(self.binding, self.binding)
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = json.loads(self.output.read_bytes())
        exported_at = datetime.fromisoformat(snapshot.pop("exported_at"))
        self.assertIsNotNone(exported_at.utcoffset())
        self.assertEqual(snapshot, {
            "version": 1,
            "project": "sample",
            "reports": [{
                "ref": self.provenance["ref"],
                "recorded_at": self.provenance["started_at"],
                "outcome": "ok",
                "task": "sample/0001",
            }],
        })

    def test_digest_mismatch_preserves_output_after_valid_row(self):
        self.output.write_bytes(b"previous snapshot\n")
        invalid = self.write_provenance("invalid.json", report_sha256="0" * 64)
        result = self.export(self.binding, invalid)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("digest", result.stderr)
        self.assertEqual(self.output.read_bytes(), b"previous snapshot\n")

    def test_rejects_duplicate_keys_and_conflicting_rows(self):
        duplicate = self.root / "duplicate.json"
        duplicate.write_text(
            '{"task": "sample/0001", ' + json.dumps(self.provenance)[1:],
            encoding="utf-8",
        )
        conflict = self.write_provenance("conflict.json", task="sample/0002")
        for bindings, message in [
            ((duplicate,), "duplicate"),
            ((self.binding, conflict), "conflicting"),
        ]:
            with self.subTest(message=message):
                result = self.export(*bindings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.output.exists())

    def test_rejects_foreign_task_and_mismatched_native_metadata(self):
        for overrides, message in [
            ({"task": "other/0001"}, "project"),
            ({"engine": "claude"}, "engine"),
            ({"source": "manual-anthropic-api"}, "meute-runner"),
        ]:
            with self.subTest(message=message):
                binding = self.write_provenance("invalid.json", **overrides)
                result = self.export(binding)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.output.exists())

    def test_destination_cannot_alias_an_input(self):
        source = self.report.read_bytes()
        self.output.hardlink_to(self.report)
        for target in [self.report, self.output, self.log]:
            with self.subTest(target=target):
                original = target.read_bytes()
                result = self.export(output=target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("input", result.stderr)
                self.assertEqual(target.read_bytes(), original)
        self.assertEqual(self.report.read_bytes(), source)

    def test_rejects_missing_ambiguous_partial_and_mismatched_terminal_records(self):
        for log, message in [
            ("", "missing"),
            (self.log_line.replace(self.provenance["started_at"], "2025-01-02T08:04:05Z"),
             "missing"),
            (self.log_line.replace("review.md", "other.md"), "missing"),
            (self.log_line * 2, "ambiguous"),
            (self.log_line.rstrip("\n"), "partial"),
            (self.log_line.replace("\tpr=-", ""), "partial"),
            (self.log_line.replace("\tpr=-", "\tpr=-\tstatus=ok"), "duplicate"),
            (self.log_line.replace("task=native-review", "task=wrong"), "task"),
            (self.log_line.replace("slot=weekly", "slot=daily"), "slot"),
            (self.log_line.replace("status=ok", "status=error"), "status"),
            (self.log_line.replace("code=ok", "code=died"), "code"),
        ]:
            with self.subTest(message=message):
                self.log.write_text(log, encoding="utf-8")
                result = self.export()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.output.exists())

    def test_missing_native_task_or_slot_preserves_existing_output(self):
        self.output.write_bytes(b"previous snapshot\n")
        original = self.report.read_bytes()
        for key, field in [("task", b"task: native-review\n"), ("slot", b"slot: weekly\n")]:
            with self.subTest(key=key):
                modified = original.replace(field, b"")
                self.report.write_bytes(modified)
                binding = self.write_provenance(
                    "missing.json", report_sha256=hashlib.sha256(modified).hexdigest()
                )
                result = self.export(binding)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"missing {key}", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertEqual(self.output.read_bytes(), b"previous snapshot\n")

    def test_same_snapshot_row_cannot_hide_conflicting_report_digests(self):
        other = self.root / "other"
        other.mkdir()
        report = other / self.report.name
        report.write_bytes(self.report.read_bytes() + b"Different report body.\n")
        binding = self.write_provenance(
            "other.json", report_sha256=hashlib.sha256(report.read_bytes()).hexdigest()
        )
        result = self.export(self.binding, (binding, report, self.log))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicting", result.stderr)
        self.assertFalse(self.output.exists())
