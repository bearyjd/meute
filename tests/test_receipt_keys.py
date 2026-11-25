"""lib/receipt_keys.py: the grammar, hashes and revision shared by every receipt PR."""

import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import receipt_keys as rk  # noqa: E402

TRAPS = ["alice\n", "k" * 8 + "\n", "ab\0cdefgh", "٣" * 8, "", " " * 8]


class GrammarTest(unittest.TestCase):
    def test_operator_accepts_and_rejects(self):
        for ok in ("local", "alice", "a.b_c@d:e-f", "x" * 64):
            self.assertTrue(rk.OPERATOR_RE.fullmatch(ok), ok)
        for bad in ("x" * 65, "a b", "a/b", *TRAPS):
            self.assertFalse(rk.OPERATOR_RE.fullmatch(bad), repr(bad))

    def test_key_accepts_and_rejects(self):
        for ok in ("k" * 8, "abc-DEF_1:2.3"[:12].replace("_", "-"), "k" * 128, "a:b.c-dddd"):
            self.assertTrue(rk.KEY_RE.fullmatch(ok), ok)
        for bad in ("k" * 7, "k" * 129, "k" * 8 + "/", "k@kkkkkkk", *TRAPS):
            self.assertFalse(rk.KEY_RE.fullmatch(bad), repr(bad))

    def test_report_id_accepts_real_ids_and_rejects_the_rest(self):
        for ok in ("alpha/name.md", "alpha/audit-security-2026-08-30", "a.b/c_d"):
            self.assertTrue(rk.REPORT_ID_RE.fullmatch(ok) and rk.valid_report_id(ok), ok)
        for bad in ("r1", "a/b/c", "./x", "a/..", "a/b..c", "../a", "a/", "/a", "a/.",
                    "alpha/x\n", "a/b\0", "٣/x", ""):
            self.assertFalse(rk.valid_report_id(bad), repr(bad))


class HashTest(unittest.TestCase):
    def test_scope_hash_shape_and_independence(self):
        want = hashlib.sha256(b"op\0finding.resolve\0kkkkkkkk").hexdigest()
        self.assertEqual(rk.scope_hash("op", "finding.resolve", "kkkkkkkk"), want)
        seen = {rk.scope_hash("op", name, "kkkkkkkk") for name in rk.OPERATIONS}
        self.assertEqual(len(seen), len(rk.OPERATIONS))
        self.assertEqual(set(rk.OPERATIONS), {"finding.resolve", "finding.dismiss", "run.select",
                                              "run.start", "run.stop", "run.reconcile"})
        self.assertNotEqual(rk.scope_hash("a", "finding.resolve", "kkkkkkkk"),
                            rk.scope_hash("b", "finding.resolve", "kkkkkkkk"))

    def test_payload_hash_ignores_key_order_and_escapes_non_ascii(self):
        self.assertEqual(rk.payload_hash({"a": 1, "b": "x"}), rk.payload_hash({"b": "x", "a": 1}))
        canon = json.dumps({"a": "é"}, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        self.assertEqual(rk.payload_hash({"a": "é"}), hashlib.sha256(canon.encode()).hexdigest())
        self.assertNotEqual(rk.payload_hash({"a": 1}), rk.payload_hash({"a": 2}))


class RevisionTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / "reports"

    def test_absent_iff_not_a_row(self):
        self.assertEqual(rk.revision({}, "a/b#1"), "r1:absent")
        self.assertEqual(rk.read_rows(str(self.path)), {})
        self.path.write_bytes(b"a/b#1\n")  # a key-only row is a decision, not absence
        rows = rk.read_rows(str(self.path))
        self.assertEqual(rk.revision(rows, "a/b#1"),
                         "r1:" + hashlib.sha256(b"\t\t").hexdigest())
        self.assertEqual(rk.revision(rows, "a/b#2"), "r1:absent")

    def test_full_sha256_of_state_when_note_and_never_the_defaulted_row(self):
        self.path.write_bytes(b"a/b#1\tactioned\t2026-01-01T00:00:00+00:00\tresolved: x\n")
        rev = rk.revision(rk.read_rows(str(self.path)), "a/b#1")
        want = hashlib.sha256(b"actioned\t2026-01-01T00:00:00+00:00\tresolved: x").hexdigest()
        self.assertEqual(rev, "r1:" + want)
        self.assertEqual(len(rev), 3 + 64)
        self.assertNotEqual(rk.revision({}, "a/b#9"), "r1:" + hashlib.sha256(b"new\t\t").hexdigest())

    def test_first_row_wins_and_bytes_are_not_decoded(self):
        self.path.write_bytes(b"k#1\tdismissed\tw\tn1\xff\nk#1\tactioned\tw\tn2\n"
                              b"other\x85\xe2\x80\xa8\tx\ty\tz\r\n")
        rows = rk.read_rows(str(self.path))
        self.assertEqual(rows[b"k#1"], (b"dismissed", b"w", b"n1\xff"))
        self.assertEqual(rk.revision(rows, "k#1"),
                         "r1:" + hashlib.sha256(b"dismissed\tw\tn1\xff").hexdigest())
        # split on LF only: the CR stays in the note, U+2028 stays in the key
        self.assertEqual(rows[b"other\x85\xe2\x80\xa8"], (b"x", b"y", b"z\r"))

    def test_unterminated_last_row_is_read(self):
        self.path.write_bytes(b"k#1\ta\tb\tc")
        self.assertEqual(rk.read_rows(str(self.path))[b"k#1"], (b"a", b"b", b"c"))


class FsSelftestAndFlagTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.state = Path(tmp.name) / "state"
        self.state.mkdir()

    def test_selftest_passes_on_a_normal_filesystem(self):
        self.assertTrue(rk.fs_selftest(str(self.state))["ok"])
        self.assertEqual(os.listdir(self.state), [])

    def test_selftest_fails_when_link_overwrites(self):
        def overwriting_link(src, dst, *a, **kw):
            os.replace(src, dst)
        with mock.patch("os.link", overwriting_link):
            self.assertFalse(rk.fs_selftest(str(self.state))["ok"])

    def test_writes_disabled_without_a_valid_flag(self):
        flag = self.state / "fleet-writes.enabled"
        self.assertFalse(rk.writes_enabled(str(self.state)))
        flag.touch()
        self.assertFalse(rk.writes_enabled(str(self.state)))
        for body in ("{", "[]", '"yes"', json.dumps({"m2_ack": False, "selftest": {"ok": True}}),
                     json.dumps({"m2_ack": "true", "selftest": {"ok": True}}),
                     json.dumps({"selftest": {"ok": True}}),
                     json.dumps({"m2_ack": True}),
                     json.dumps({"m2_ack": True, "selftest": {"ok": False}})):
            flag.write_text(body)
            self.assertFalse(rk.writes_enabled(str(self.state)), body)


if __name__ == "__main__":
    unittest.main()
