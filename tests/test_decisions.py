"""Durable finding decisions (PR 3.1a): `resolve`/`dismiss -f N --request-key K`."""

import contextlib
import fcntl
import hashlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import unittest
from unittest import mock

from decisions_helpers import (REPORT_A, REPORT_B, REPORT_EMPTY, SOURCE, Fixture, clean_env,
                               parse)

sys.path.insert(0, str(SOURCE / "lib"))
import receipt_keys as rk  # noqa: E402

ABSENT = "r1:absent"
K1, K2, K3 = "key-00001", "key-00002", "key-00003"
KEY_A1 = f"{REPORT_A}#1"
T0 = 1_800_000_000
DAY = 86400
STEPS = ("5", "6t", "6w", "6", "7", "8", "9")


def hooked(step, **extra):
    return dict(MEUTE_TEST="1", MEUTE_DECISIONS_FAIL_AFTER=step, **extra)


class Base(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture(self)

    def apply(self, key=K1, rev=ABSENT, n=1, rid=REPORT_A, message="fixed upstream", **kw):
        proc = self.fx.resolve(rid, n, key, rev, message=message, **kw)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return parse(proc)

    def legacy(self, *args):
        proc = self.fx.meute(*args)
        self.assertEqual(proc.returncode, 0, proc.stderr)


# ------------------------------------------------------------------ 1-3 ---
class RevisionTest(Base):
    def test_revision_absent_without_a_row(self):
        self.assertEqual(self.fx.revision(REPORT_A, 1), ABSENT)

    def test_revision_changes_on_a_legacy_write_and_matches_findings_json(self):
        self.fx.write_rows(b"other#9\n" + f"{REPORT_B}#1\tdismissed\t\t\n".encode())
        before = self.fx.revision(REPORT_A, 1)
        self.legacy("resolve", REPORT_A, "-f", "1", "-m", "x")
        after = self.fx.revision(REPORT_A, 1)
        self.assertNotEqual(before, after)
        listed = json.loads(self.fx.meute("findings", "--json", "--all").stdout)
        by_id = {f["id"]: f["revision"] for f in listed}
        self.assertEqual(by_id[KEY_A1], after)
        self.assertEqual(by_id[f"{REPORT_B}#1"], self.fx.revision(REPORT_B, 1))
        self.assertEqual(by_id[f"{REPORT_A}#2"], ABSENT)
        row = self.fx.rows_for(KEY_A1)[0].split(b"\t")
        self.assertEqual(after, "r1:" + hashlib.sha256(b"\t".join(row[1:4])).hexdigest())

    def test_never_decided_finding_reads_absent_everywhere_and_first_decision_succeeds(self):
        listed = json.loads(self.fx.meute("findings", "--json", "--all").stdout)
        self.assertTrue(listed and all(f["revision"] == ABSENT for f in listed))
        self.assertNotEqual(listed[0]["revision"], "r1:" + hashlib.sha256(b"new\t\t").hexdigest())
        # dump() builds its findings with load_reports
        code = ("import json,sys,inbox;json.dump([f['revision'] for f in inbox.load_reports()[1]],sys.stdout)")
        out = subprocess.run([sys.executable, "-B", "-c", code], cwd=SOURCE / "lib",
                             env=clean_env(MEUTE_ROOT=str(self.fx.root)), capture_output=True, text=True)
        self.assertEqual(json.loads(out.stdout), [ABSENT] * 4, out.stderr)
        self.apply(rev=listed[0]["revision"])

    def test_claim_leaves_the_revision_alone(self):
        self.legacy("claim", REPORT_A, "-f", "2", "--pr", "https://example.test/pr/1")
        self.assertEqual(self.fx.revision(REPORT_A, 2), ABSENT)

    def test_findings_json_keeps_every_existing_key(self):
        listed = json.loads(self.fx.meute("findings", "--json", "--all").stdout)
        self.assertEqual(sorted(listed[0]), sorted(
            ["id", "report", "n", "fingerprint", "repo", "severity", "title", "location", "base",
             "state", "inherited", "verdict", "pr", "revision"]))


# ------------------------------------------------------------------ 4-9 ---
class AcceptanceTest(Base):
    def test_stale_decision_fails(self):
        first = self.apply(K1)["receipt"]
        rows_before = self.fx.rows()
        proc = self.fx.resolve(REPORT_A, 1, K2, ABSENT)
        self.assertEqual(proc.returncode, 3)
        body = parse(proc)
        self.assertEqual(body["error"], "stale_revision")
        self.assertEqual(body["current_revision"], first["after_revision"])
        self.assertEqual(self.fx.rows(), rows_before)
        self.assertEqual(len(self.fx.receipt_files()), 1)

    def test_retry_after_lost_response_returns_the_same_receipt_after_the_revision_advanced(self):
        first = self.apply(K1)
        self.legacy("dismiss", REPORT_A, "-f", "1", "-r", "other")
        rows_before = self.fx.rows()
        files_before = [p.read_bytes() for p in self.fx.receipt_files()]
        again = self.fx.resolve(REPORT_A, 1, K1, ABSENT)
        self.assertEqual(again.returncode, 0, again.stdout)
        body = parse(again)
        self.assertEqual(body["receipt"]["receipt_id"], first["receipt"]["receipt_id"])
        self.assertTrue(body["replayed"])
        self.assertFalse(first["replayed"])
        self.assertEqual(self.fx.rows(), rows_before)
        self.assertEqual([p.read_bytes() for p in self.fx.receipt_files()], files_before)

    def test_conflicting_key_reuse_fails_for_other_text_other_n_other_report(self):
        self.apply(K1, message="a")
        rows, receipts = self.fx.rows(), [p.read_bytes() for p in self.fx.receipt_files()]
        for args in ((REPORT_A, 1, "b"), (REPORT_A, 2, "a"), (REPORT_B, 1, "a")):
            proc = self.fx.resolve(args[0], args[1], K1, ABSENT, message=args[2])
            self.assertEqual(proc.returncode, 4, proc.stdout)
            self.assertEqual(parse(proc), {"error": "key_conflict"})
        self.assertEqual(self.fx.rows(), rows)
        self.assertEqual([p.read_bytes() for p in self.fx.receipt_files()], receipts)

    def test_same_key_under_the_other_operation_is_independent(self):
        res = self.apply(K1)["receipt"]
        stale = self.fx.dismiss(REPORT_A, 1, K1, ABSENT)
        self.assertEqual(stale.returncode, 3)
        ok = self.fx.dismiss(REPORT_A, 1, K1, res["after_revision"], reason="duplicate")
        self.assertEqual(ok.returncode, 0, ok.stdout)
        dis = parse(ok)["receipt"]
        self.assertNotEqual(dis["receipt_id"], res["receipt_id"])
        self.assertEqual((res["disposition"], dis["disposition"]), ("actioned", "dismissed"))
        self.assertEqual(len(self.fx.receipt_files()), 2)

    def test_operator_scoping_two_operators_two_receipts(self):
        a = self.apply(K1, operator="alice")["receipt"]
        b = self.apply(K1, rev=a["after_revision"], operator="bob", message="other")["receipt"]
        self.assertNotEqual(a["receipt_id"], b["receipt_id"])
        self.assertEqual(len(self.fx.receipt_files()), 2)
        self.assertEqual((a["operator"], b["operator"]), ("alice", "bob"))
        replay = parse(self.fx.resolve(REPORT_A, 1, K1, ABSENT, operator="bob", message="other"))
        self.assertEqual(replay["receipt"]["receipt_id"], b["receipt_id"])

    def test_operator_default_is_env_then_local(self):
        self.assertEqual(self.apply(K1)["receipt"]["operator"], "local")
        got = parse(self.fx.resolve(REPORT_A, 2, K1, ABSENT, MEUTE_OPERATOR="carol"))
        self.assertEqual(got["receipt"]["operator"], "carol")
        flag = parse(self.fx.resolve(REPORT_A, 3, K1, ABSENT, operator="dave", MEUTE_OPERATOR="carol"))
        self.assertEqual(flag["receipt"]["operator"], "dave")

    def test_lib_level_same_disposition_for_both_surfaces(self):
        import decisions
        cli = self.apply(K1)["receipt"]
        code, body = decisions.run_decide(
            str(self.fx.root), "resolve", "local", K1, REPORT_A, "1", "fixed upstream", "",
            "", ABSENT, {})
        self.assertEqual(code, 0)
        self.assertEqual(body["receipt"]["receipt_id"], cli["receipt_id"])
        self.assertEqual(body["receipt"]["disposition"], "actioned")
        self.assertTrue(body["replayed"])

    def test_receipt_shape_and_modes(self):
        rec = self.apply(K1)["receipt"]
        self.assertEqual(sorted(rec), sorted([
            "version", "receipt_id", "operation", "operator", "request_key", "payload_sha256",
            "report_id", "n", "finding_key", "expected_revision", "before_revision", "after_revision",
            "disposition", "phase", "created_at", "expires_at"]))
        self.assertEqual(rec["phase"], "complete")
        self.assertEqual(rec["after_revision"], self.fx.revision(REPORT_A, 1))
        self.assertEqual(rec["before_revision"], ABSENT)
        self.assertEqual(rec["expires_at"] - rec["created_at"], 30 * DAY)
        want = rk.payload_hash({"report_id": REPORT_A, "n": 1, "reason": "", "message": "fixed upstream", "pr": ""})
        self.assertEqual(rec["payload_sha256"], want)
        path = self.fx.receipt_files()[0]
        self.assertEqual(path.name, rk.scope_hash("local", "finding.resolve", K1) + ".json")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        for d in (self.fx.state / "receipts", self.fx.receipts):
            self.assertEqual(stat.S_IMODE(d.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.fx.reports_file.stat().st_mode), 0o600)
        stored = json.loads(path.read_text())
        self.assertEqual({k: v for k, v in stored.items() if not k.startswith("row_")}, rec)
        self.assertEqual(stored["row_state"], "actioned")
        self.assertEqual(stored["row_note"], "resolved: fixed upstream")
        self.assertNotIn(b".tmp-", b" ".join(p.name.encode() for p in self.fx.receipts.iterdir()))


class LegacyUnchangedTest(Base):
    def _shim(self):
        shim = self.fx.root / "shim"
        shim.mkdir()
        (shim / "date").write_text(
            '#!/bin/sh\ncase "$1" in --iso-8601=seconds) echo 2026-01-02T03:04:05+00:00;; '
            f'*) exec {shutil.which("date")} "$@";; esac\n')
        (shim / "date").chmod(0o755)
        return shim

    def test_legacy_bytes_are_golden_including_a_non_utf8_row(self):
        shim = self._shim()
        self.fx.write_rows(b"keep#1\tx\ty\tnote \xff\xfe\nalpha/audit-a#2\tnew\t\told")
        env = dict(PATH=f"{shim}:{os.environ['PATH']}")
        outs = []
        for args in (("resolve", REPORT_A, "-f", "1", "-m", "fixed it"),
                     ("dismiss", REPORT_A, "-f", "2", "-r", "wont-fix", "-m", "meh"),
                     ("resolve", REPORT_B, "-f", "1", "--pr", "https://example.test/p/1"),
                     ("dismiss", REPORT_A, "-f", "3", "-r", "other")):
            proc = self.fx.meute(*args, **env)
            outs.append((proc.returncode, proc.stdout, proc.stderr))
        t = "2026-01-02T03:04:05+00:00"
        self.assertEqual(self.fx.rows(), b"keep#1\tx\ty\tnote \xff\xfe\n" + (
            f"{REPORT_A}#1\tactioned\t{t}\tresolved: fixed it\n"
            f"{REPORT_A}#2\tdismissed\t{t}\twont-fix: meh\n"
            f"{REPORT_B}#1\tactioned\t{t}\tresolved: pr: https://example.test/p/1\n"
            f"{REPORT_B}\tactioned\t{t}\t\n"
            f"{REPORT_A}#3\tdismissed\t{t}\tother\n"
            f"{REPORT_A}\tactioned\t{t}\t\n").encode())
        self.assertEqual([o[0] for o in outs], [0, 0, 0, 0])
        self.assertEqual(outs[0][2], f"meute: resolved finding 1 of {REPORT_A}\n")
        self.assertEqual(outs[1][2], f"meute: dismissed finding 2 of {REPORT_A} (wont-fix)\n")
        self.assertEqual(outs[0][1], "")
        self.assertFalse((self.fx.state / "receipts").exists())

    def test_legacy_with_a_preexisting_receipts_dir_does_not_touch_it(self):
        self.fx.receipts.mkdir(parents=True)
        (self.fx.receipts / "keep.json").write_text("{}")
        self.legacy("resolve", REPORT_A, "-f", "1", "-m", "x")
        self.assertEqual([p.name for p in self.fx.receipts.iterdir()], ["keep.json"])

    def test_legacy_whole_report_and_error_paths_are_unchanged(self):
        proc = self.fx.meute("resolve", REPORT_A, "-f", "1")
        self.assertEqual((proc.returncode, proc.stderr),
                         (1, "meute: resolve: -m <text> or --pr <url> is required (what was done)\n"))
        proc = self.fx.meute("dismiss", REPORT_A, "-f", "1", "-r", "bogus")
        self.assertEqual(proc.returncode, 1)
        self.legacy("resolve", REPORT_B, "-m", "whole")
        self.assertIn(f"{REPORT_B}\tactioned\t", self.fx.rows().decode())
        # the legacy grep -qw fragment match still passes without a request key
        self.legacy("dismiss", REPORT_A, "-f", "2", "-r", "wont")


# ---------------------------------------------------------------- 10-13 ---
class CrashTest(Base):
    def run_crash(self, step, op="resolve"):
        call = self.fx.resolve if op == "resolve" else self.fx.dismiss
        crashed = call(REPORT_B, 1, K1, ABSENT, **hooked(step))
        self.assertEqual(crashed.returncode, 70, (step, crashed.stdout, crashed.stderr))
        return crashed

    def test_every_step_boundary_recovers_once_with_the_same_receipt(self):
        for op in ("resolve", "dismiss"):
            for step in STEPS:
                with self.subTest(op=op, step=step):
                    self.fx = Fixture(self)
                    self.run_crash(step, op)
                    on_disk = self.fx.only_receipt()
                    call = self.fx.resolve if op == "resolve" else self.fx.dismiss
                    retry = call(REPORT_B, 1, K1, ABSENT)  # the OLD revision: replay never checks it
                    self.assertEqual(retry.returncode, 0, (retry.stdout, retry.stderr))
                    body = parse(retry)
                    self.assertEqual(body["receipt"]["receipt_id"], on_disk["receipt_id"])
                    self.assertEqual(body["receipt"]["phase"], "complete")
                    self.assertTrue(body["replayed"])
                    rows = self.fx.rows_for(f"{REPORT_B}#1")
                    self.assertEqual(len(rows), 1)
                    self.assertEqual(rows[0].split(b"\t")[2].decode(), on_disk["row_when"])
                    self.assertEqual(rows[0].split(b"\t")[1].decode(),
                                     "actioned" if op == "resolve" else "dismissed")
                    self.assertEqual(len(self.fx.rows_for(REPORT_B)), 1)
                    self.assertTrue(self.fx.rows_for(REPORT_B)[0].startswith(f"{REPORT_B}\tactioned\t".encode()))
                    self.assertEqual(len(self.fx.receipt_files()), 1)
                    self.assertEqual(self.fx.revision(REPORT_B, 1), body["receipt"]["after_revision"])
                    third = call(REPORT_B, 1, K1, ABSENT)
                    self.assertEqual(parse(third)["receipt"]["receipt_id"], on_disk["receipt_id"])

    def test_report_row_is_read_until_the_last_finding_then_actioned(self):
        crashed = self.fx.resolve(REPORT_A, 1, K1, ABSENT, **hooked("7"))
        self.assertEqual(crashed.returncode, 70)
        self.assertEqual(self.fx.rows_for(REPORT_A), [])
        self.assertEqual(self.fx.resolve(REPORT_A, 1, K1, ABSENT).returncode, 0)
        self.assertIn(b"\tread\t", self.fx.rows_for(REPORT_A)[0])

    def test_crash_before_the_row_swap_leaves_the_kv_temp_that_only_a_hard_exit_leaves(self):
        self.run_crash("6t")
        temps = [p for p in self.fx.state.iterdir() if p.name.startswith(".kv.")]
        self.assertEqual(len(temps), 1, "a hard exit must not run the writer's cleanup")
        self.assertEqual(self.fx.rows_for(f"{REPORT_B}#1"), [])
        self.assertEqual(self.fx.resolve(REPORT_B, 1, K1, ABSENT).returncode, 0)

    def test_replay_in_state_written_never_rewrites_the_finding_row(self):
        self.run_crash("7")
        self.assertEqual(self.fx.only_receipt()["phase"], "state_written")
        self.legacy("dismiss", REPORT_B, "-f", "1", "-r", "other", "-m", "someone else")
        legacy_rows = self.fx.rows_for(f"{REPORT_B}#1")
        self.assertEqual(len(legacy_rows), 1)
        retry = self.fx.resolve(REPORT_B, 1, K1, ABSENT)
        self.assertEqual(retry.returncode, 0, (retry.stdout, retry.stderr))
        body = parse(retry)
        self.assertEqual((body["receipt"]["phase"], body["replayed"]), ("complete", True))
        self.assertEqual(self.fx.rows_for(f"{REPORT_B}#1"), legacy_rows)

    def test_pending_receipt_with_a_superseded_row_is_indeterminate_and_kept(self):
        for step in ("5", "6"):
            with self.subTest(step=step):
                self.fx = Fixture(self)
                self.run_crash(step)
                path = self.fx.receipt_files()[0]
                before = path.read_bytes()
                self.legacy("dismiss", REPORT_B, "-f", "1", "-r", "other")
                rows = self.fx.rows()
                proc = self.fx.resolve(REPORT_B, 1, K1, ABSENT)
                self.assertEqual(proc.returncode, 5, proc.stdout)
                body = parse(proc)
                self.assertEqual(body["error"], "indeterminate")
                self.assertEqual(body["receipt"]["phase"], "pending")
                self.assertEqual(body["current_revision"], self.fx.revision(REPORT_B, 1))
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual(self.fx.rows(), rows)
                fresh = self.fx.resolve(REPORT_B, 1, K2, body["current_revision"])
                self.assertEqual(fresh.returncode, 0, fresh.stdout)


class HookInertTest(Base):
    def test_fault_hook_and_test_knobs_are_inert_without_meute_test_1(self):
        for value in (None, "0", ""):
            with self.subTest(meute_test=value):
                self.fx = Fixture(self)
                env = dict(MEUTE_DECISIONS_FAIL_AFTER="5", MEUTE_NOW="1")
                if value is not None:
                    env["MEUTE_TEST"] = value
                proc = self.fx.resolve(REPORT_B, 1, K1, ABSENT, **env)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                rec = self.fx.only_receipt()
                self.assertEqual(rec["phase"], "complete")
                self.assertGreater(rec["created_at"], 1_700_000_000)  # real clock, not MEUTE_NOW=1
                self.assertEqual(len(self.fx.rows_for(f"{REPORT_B}#1")), 1)
                relaxed = self.fx.resolve(REPORT_A, 1, K2, ABSENT, MEUTE_DECISIONS_LOCK_WAIT="0.5", **env)
                self.assertEqual(relaxed.returncode, 2, relaxed.stdout)
                self.assertEqual(parse(relaxed)["error"], "invalid_config")
        live = self.fx.resolve(REPORT_A, 1, K3, ABSENT, **hooked("5"))
        self.assertEqual(live.returncode, 70)


# ------------------------------------------------------------------ 14-15 ---
class ConcurrencyTest(Base):
    def test_two_processes_same_key_apply_once(self):
        argv = [str(self.fx.root / "bin" / "meute"), "resolve", REPORT_B, "-f", "1", "-m", "x",
                "--request-key", K1, "--expected-revision", ABSENT]
        procs = [subprocess.Popen(argv, cwd=self.fx.root, env=clean_env(), stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True) for _ in range(4)]
        outs = [(p.communicate()[0], p.returncode) for p in procs]
        self.assertEqual([rc for _, rc in outs], [0, 0, 0, 0])
        ids = {json.loads(o)["receipt"]["receipt_id"] for o, _ in outs}
        self.assertEqual(len(ids), 1)
        self.assertEqual(sorted(json.loads(o)["replayed"] for o, _ in outs), [False, True, True, True])
        self.assertEqual(len(self.fx.rows_for(f"{REPORT_B}#1")), 1)

    def test_legacy_writers_in_parallel_lose_no_rows(self):
        legacy = [subprocess.Popen([str(self.fx.root / "bin" / "meute"), "dismiss", REPORT_A, "-f",
                                    str(100 + i), "-r", "other"], cwd=self.fx.root, env=clean_env(),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for i in range(20)]
        mine = self.fx.resolve(REPORT_A, 1, K1, ABSENT)
        for p in legacy:
            p.wait()
        self.assertEqual(mine.returncode, 0, mine.stdout)
        for i in range(20):
            self.assertEqual(len(self.fx.rows_for(f"{REPORT_A}#{100 + i}")), 1, i)
        self.assertEqual(len(self.fx.rows_for(KEY_A1)), 1)


# ------------------------------------------------------------------ 16 ---
class ValidationTest(Base):
    def untouched(self, proc, code=2):
        self.assertEqual(proc.returncode, code, proc.stdout + proc.stderr)
        self.assertFalse((self.fx.state / "receipts").exists())
        self.assertEqual(self.fx.rows(), b"")

    def base(self, *drop, **over):
        spec = dict(rid=REPORT_A, f="1", m="text", key="key-valid1", rev=ABSENT)
        spec.update(over)
        args = ["resolve", spec["rid"]]
        if spec["f"] is not None:
            args += ["-f", spec["f"]]
        if spec["m"] is not None:
            args += ["-m", spec["m"]]
        args += ["--request-key", spec["key"]]
        if spec["rev"] is not None:
            args += ["--expected-revision", spec["rev"]]
        return args

    def test_decisions_py_owned_checks_exit_2_and_write_nothing(self):
        cases = {
            "no revision": self.base(rev=None),
            "no -f": self.base(f=None),
            "short key": self.base(key="short"),
            "long key": self.base(key="k" * 129),
            "bad key char": self.base(key="key/00001"),
            "tab in text": self.base(m="a\tb"),
            "newline in text": self.base(m="a\nb"),
            "control in text": self.base(m="a\x01b"),
            "n too big": self.base(f="4"),
            "leading zero": self.base(f="007"),
            "zero": self.base(f="0"),
            "non-ascii digit": self.base(f="٣"),
            "non number": self.base(f="abc"),
            "missing report": self.base(rid="alpha/nope"),
            "empty report id": self.base(rid=""),
            "bad id shape": self.base(rid="r1"),
            "no findings section": self.base(rid=REPORT_EMPTY),
            "no text no pr": self.base(m=None),
            "blank text": self.base(m="   "),
            "bad pr": self.base(m=None) + ["--pr", "ftp://x/y"],
            "pr with space": self.base(m=None) + ["--pr", "https://x/y z"],
            "bad operator": self.base() + ["--operator", "bad op!"],
            "operator newline": self.base() + ["--operator", "alice\n"],
            "key newline": self.base(key="key-valid1\n"),
        }
        for name, args in cases.items():
            with self.subTest(name):
                self.untouched(self.fx.meute(*args))
        for reason in ("fix", "positive", "wont", "other other", "OTHER"):
            with self.subTest(reason=reason):
                self.untouched(self.fx.meute("dismiss", REPORT_A, "-f", "1", "-r", reason, "--request-key",
                                             "key-valid1", "--expected-revision", ABSENT))
        self.untouched(self.fx.meute("dismiss", REPORT_A, "-f", "1", "--request-key", "key-valid1",
                                     "--expected-revision", ABSENT))

    def test_argument_loop_errors_exit_1(self):
        for args, needle in (
                (["resolve", REPORT_A, "-f", "1", "-m", "x", "--expected-revision", ABSENT],
                 "need --request-key"),
                (["resolve", REPORT_A, "-f", "1", "-m", "x", "--operator", "bob"], "need --request-key"),
                (["dismiss", REPORT_A, "-f", "1", "-r", "other", "--operator", "bob"], "need --request-key"),
                (["resolve", REPORT_A, "-f", "1", "-m", "x", "--request-key"], "--request-key needs"),
                (["resolve", REPORT_A, "-f", "1", "--bogus", "x", "--request-key", "key-valid1"],
                 "unknown argument --bogus"),
                (["resolve", "-f", "1", "-m", "x", "--request-key", "key-valid1",
                  "--expected-revision", ABSENT], "unknown argument 1")):
            with self.subTest(args=args):
                proc = self.fx.meute(*args)
                self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
                self.assertIn(needle, proc.stderr)
                self.assertEqual(self.fx.rows(), b"")

    def test_resolve_with_only_a_pr_reaches_the_receipt_path_unmerged(self):
        proc = self.fx.meute("resolve", REPORT_A, "-f", "1", "--pr", "https://example.test/p/1",
                             "--request-key", K1, "--expected-revision", ABSENT)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        want = rk.payload_hash({"report_id": REPORT_A, "n": 1, "reason": "", "message": "",
                                "pr": "https://example.test/p/1"})
        self.assertEqual(parse(proc)["receipt"]["payload_sha256"], want)

    def test_text_is_stripped_before_hashing(self):
        first = self.apply(K1, message="  padded  ")["receipt"]
        again = parse(self.fx.resolve(REPORT_A, 1, K1, ABSENT, message="padded"))
        self.assertEqual(again["receipt"]["receipt_id"], first["receipt_id"])
        self.assertIn(b"\tresolved: padded\n", self.fx.rows())


class NoteParityTest(Base):
    CASES = (("text", ["-m", "fixed it"]), ("pr", ["--pr", "https://example.test/p/1"]),
             ("both", ["-m", "fixed it", "--pr", "https://example.test/p/1"]))

    @staticmethod
    def note_of(fx, key):
        return fx.rows_for(key)[0].split(b"\t")[3]

    def test_resolve_note_is_byte_equal_to_legacy(self):
        for name, flags in self.CASES:
            with self.subTest(name):
                legacy, durable = Fixture(self), Fixture(self)
                legacy_proc = legacy.meute("resolve", REPORT_A, "-f", "1", *flags)
                self.assertEqual(legacy_proc.returncode, 0)
                proc = durable.meute("resolve", REPORT_A, "-f", "1", *flags, "--request-key", K1,
                                     "--expected-revision", ABSENT)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertEqual(self.note_of(durable, KEY_A1), self.note_of(legacy, KEY_A1))
                self.assertEqual(durable.rows_for(REPORT_B), legacy.rows_for(REPORT_B))
                no_when = lambda fx: [f for i, f in enumerate(fx.rows_for(KEY_A1)[0].split(b"\t")) if i != 2]  # noqa: E731
                self.assertEqual(no_when(durable), no_when(legacy))
        self.assertNotIn(b"resolved:  ", self.fx.rows())

    def test_dismiss_note_is_byte_equal_to_legacy(self):
        for flags in ([], ["-m", "not useful"]):
            with self.subTest(flags=flags):
                legacy, durable = Fixture(self), Fixture(self)
                legacy.meute("dismiss", REPORT_A, "-f", "1", "-r", "duplicate", *flags)
                proc = durable.meute("dismiss", REPORT_A, "-f", "1", "-r", "duplicate", *flags,
                                     "--request-key", K1, "--expected-revision", ABSENT)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertEqual(self.note_of(durable, KEY_A1), self.note_of(legacy, KEY_A1))

    def test_report_row_matches_legacy_across_every_finding(self):
        legacy, durable = Fixture(self), Fixture(self)
        for n in (1, 2, 3):
            legacy.meute("resolve", REPORT_A, "-f", str(n), "-m", "x")
            proc = durable.resolve(REPORT_A, n, f"key-0000{n}", ABSENT, message="x")
            self.assertEqual(proc.returncode, 0, proc.stdout)
            self.assertEqual(durable.rows_for(REPORT_A)[0].split(b"\t")[1],
                             legacy.rows_for(REPORT_A)[0].split(b"\t")[1])
        self.assertEqual(durable.rows_for(REPORT_A)[0].split(b"\t")[1], b"actioned")
        self.assertEqual(durable.rows_for(REPORT_A)[0].split(b"\t")[3], b"")


# -------------------------------------------------------------- 16c bytes ---
class RowBytesTest(Base):
    STORES = {
        "missing": None,
        "empty": b"",
        "unterminated": b"a#1\tx\ty\tz",
        "terminated": b"a#1\tx\ty\tz\n",
        "dup rows": b"k#1\told\tw\tn\nz\tq\nk#1\told2\tw\tn\n",
        "cr and u2028": b"other\tx\ty\tnote\r\xe2\x80\xa8tail\nk#1\ta\tb\tc\r\n",
        "non-utf8": b"bad\xff\tx\ty\tnote \xfe\xfd\nk#1\ta\tb\tc\n",
        "blank line": b"\n\nk#1\ta\tb\tc\n",
        "key only": b"k#1\nother\n",
        "no trailing note": b"k#1\ta\tb\t\nzz\ta\tb\t",
    }
    ROWS = (("k#1", "actioned", "2026-01-02T03:04:05+00:00", "resolved: x"),
            ("k#1", "dismissed", "2026-01-02T03:04:05+00:00", ""),
            ("new#key", "actioned", "2026-01-02T03:04:05+00:00", "n\r "))

    def test_writer_is_byte_identical_to_kv_set_row(self):
        import decisions
        for name, content in self.STORES.items():
            for key, state, when, note in self.ROWS:
                with self.subTest(store=name, row=(key, note)):
                    paths = []
                    for tag in ("awk", "py"):
                        d = self.fx.root / f"golden-{tag}-{len(list(self.fx.root.iterdir()))}"
                        d.mkdir()
                        p = d / "reports"
                        if content is not None:
                            p.write_bytes(content)
                        paths.append(p)
                    subprocess.run(["bash", "-c", 'source "$1"; kv_set_row "$2" "$3" "$4" "$5" "$6"', "_",
                                    str(SOURCE / "lib" / "state.sh"), str(paths[0]), key, state, when, note],
                                   check=True, env=clean_env())
                    decisions.write_row(str(paths[1]), key, state, when, note)
                    self.assertEqual(paths[1].read_bytes(), paths[0].read_bytes())

    def test_full_decide_over_a_file_with_a_non_utf8_row(self):
        raw = b"bad\xff\tx\ty\tnote \xfe\n" + REPORT_A.encode() + b"#2\tdismissed\tw\tn\xff"
        self.fx.write_rows(raw)
        self.assertEqual(self.fx.revision(REPORT_A, 1), ABSENT)
        rev2 = self.fx.revision(REPORT_A, 2)
        self.assertEqual(rev2, "r1:" + hashlib.sha256(b"dismissed\tw\tn\xff").hexdigest())
        rec = self.apply(K1)["receipt"]
        self.assertEqual(rec["before_revision"], ABSENT)
        self.assertEqual(self.fx.revision(REPORT_A, 2), rev2)
        rows = self.fx.rows()
        self.assertTrue(rows.startswith(b"bad\xff\tx\ty\tnote \xfe\n"))
        self.assertIn(b"\tn\xff\n", rows)
        self.assertEqual(len(self.fx.rows_for(KEY_A1)), 1)
        # the non-UTF-8 row survives a report-row rewrite too
        self.assertEqual(len(self.fx.rows_for(REPORT_A)), 1)
        replay = self.fx.resolve(REPORT_A, 1, K1, ABSENT)
        self.assertEqual(replay.returncode, 0)
        stale = self.fx.resolve(REPORT_A, 2, K2, ABSENT)
        self.assertEqual((stale.returncode, parse(stale)["current_revision"]), (3, rev2))


# ------------------------------------------------------------- 17-19 ---
class FailClosedTest(Base):
    def test_corrupt_unknown_or_malformed_receipt_exits_70_and_is_never_touched(self):
        path = self.fx.receipts / (rk.scope_hash("local", "finding.resolve", K1) + ".json")
        self.fx.receipts.mkdir(parents=True)
        for content in (b'{"version": 1, "recei', b"", b"[]", b'{"version": 9}',
                        b'{"version": 1, "expires_at": "soon"}', b"\xff\xfe"):
            with self.subTest(content=content):
                path.write_bytes(content)
                for extra in ({}, dict(MEUTE_TEST="1", MEUTE_NOW=str(T0 * 3))):
                    proc = self.fx.resolve(REPORT_A, 1, K1, ABSENT, **extra)
                    self.assertEqual(proc.returncode, 70, proc.stdout)
                    self.assertEqual(path.read_bytes(), content)
                self.assertEqual(self.fx.rows(), b"")

    def test_gc_skips_unreadable_files_and_removes_expired_ones(self):
        self.fx.receipts.mkdir(parents=True)
        (self.fx.receipts / "bad.json").write_bytes(b"{nope")
        (self.fx.receipts / "v2.json").write_text(json.dumps({"version": 2, "expires_at": 1}))
        for i in range(3):
            (self.fx.receipts / f"old{i}.json").write_text(json.dumps(self.good_receipt()))
        self.apply(K1)
        names = sorted(p.name for p in self.fx.receipts.iterdir() if not p.name.startswith(".tmp-"))
        self.assertIn("bad.json", names)
        self.assertIn("v2.json", names)
        self.assertEqual([n for n in names if n.startswith("old")], [])

    MALFORMED = (b'{"version":1,"expires_at":true}', b'{"version":1,"expires_at":5}', b"[]", b"",
                 b"\xff\xfe", b'{"version":1,"phase":"complete","expires_at":5}')

    def test_gc_never_deletes_a_receipt_it_cannot_read(self):
        self.fx.receipts.mkdir(parents=True)
        planted = {f"bad{i}.json": c for i, c in enumerate(self.MALFORMED)}
        for name, content in planted.items():
            (self.fx.receipts / name).write_bytes(content)
        (self.fx.receipts / "expired.json").write_text(json.dumps(self.good_receipt(expires_at=1)))
        self.apply(K1)
        for name, content in planted.items():
            self.assertEqual((self.fx.receipts / name).read_bytes(), content, name)
        self.assertFalse((self.fx.receipts / "expired.json").exists())

    def test_lookup_of_each_malformed_receipt_is_exit_70_and_kept(self):
        path = self.fx.receipts / (rk.scope_hash("local", "finding.resolve", K1) + ".json")
        self.fx.receipts.mkdir(parents=True)
        for content in self.MALFORMED:
            with self.subTest(content=content):
                path.write_bytes(content)
                proc = self.fx.resolve(REPORT_A, 1, K1, ABSENT, MEUTE_TEST="1", MEUTE_NOW=str(T0 * 3))
                self.assertEqual(proc.returncode, 70, proc.stdout)
                self.assertEqual(path.read_bytes(), content)

    def good_receipt(self, **over):
        rec = {"version": 1, "phase": "complete", "receipt_id": "x", "payload_sha256": "x",
               "before_revision": "x", "row_state": "x", "row_when": "x", "row_note": "x",
               "expires_at": 1}
        return {**rec, **over}

    def test_gc_is_bounded_to_fifty_files_and_cleans_old_temp_files(self):
        self.fx.receipts.mkdir(parents=True)
        for i in range(60):
            (self.fx.receipts / f"old{i:02}.json").write_text(json.dumps(self.good_receipt()))
        self.apply(K1)
        left = [p for p in self.fx.receipts.iterdir() if p.name.startswith("old")]
        self.assertEqual(len(left), 10)
        self.assertEqual(len(self.fx.receipt_files()), 11)
        tmp = self.fx.receipts / ".tmp-orphan"
        tmp.write_text("x")
        os.utime(tmp, (1, 1))
        fresh = self.fx.receipts / ".tmp-fresh"
        fresh.write_text("x")
        self.apply(K2, n=2)
        self.assertFalse(tmp.exists())
        self.assertTrue(fresh.exists())


class LockTest(Base):
    def hold(self):
        self.fx.state.mkdir(exist_ok=True)
        fh = open(self.fx.state / "reports.lock", "ab")
        self.addCleanup(fh.close)
        fcntl.flock(fh, fcntl.LOCK_EX)
        return fh

    def test_busy_when_the_legacy_lock_is_held(self):
        self.hold()
        proc = self.fx.resolve(REPORT_A, 1, K1, ABSENT, MEUTE_TEST="1", MEUTE_DECISIONS_LOCK_WAIT="0.5")
        self.assertEqual(proc.returncode, 75, proc.stdout + proc.stderr)
        self.assertEqual(parse(proc), {"error": "busy"})
        self.assertEqual(self.fx.receipt_files(), [])
        self.assertEqual(self.fx.rows(), b"")

    def test_legacy_writer_and_receipt_mode_share_one_lock_file(self):
        fh = self.hold()
        got = []
        import threading
        t = threading.Thread(target=lambda: got.append(
            self.fx.resolve(REPORT_A, 1, K1, ABSENT, MEUTE_TEST="1", MEUTE_DECISIONS_LOCK_WAIT="5")))
        t.start()
        t.join(1.0)
        self.assertTrue(t.is_alive(), "receipt mode must wait on state/reports.lock")
        fcntl.flock(fh, fcntl.LOCK_UN)
        t.join(20)
        self.assertEqual(got[0].returncode, 0, got[0].stdout)

    def test_invalid_lock_wait_is_a_config_error_before_the_lock(self):
        self.hold()
        for bad in ("0", "-1", "abc", "nan", "inf", "", "1e3", " 1", "61"):
            with self.subTest(bad=bad):
                proc = self.fx.resolve(REPORT_A, 1, K1, ABSENT, MEUTE_TEST="1", MEUTE_DECISIONS_LOCK_WAIT=bad)
                self.assertEqual(proc.returncode, 2, proc.stdout)
                self.assertEqual(parse(proc), {"error": "invalid_config", "var": "MEUTE_DECISIONS_LOCK_WAIT"})
        for bad in ("0.5", "0.2"):
            proc = self.fx.resolve(REPORT_A, 1, K1, ABSENT, MEUTE_DECISIONS_LOCK_WAIT=bad)
            self.assertEqual(proc.returncode, 2, proc.stdout)
        self.assertEqual(self.fx.receipt_files(), [])


class TtlTest(Base):
    def clock(self, t, **extra):
        return dict(MEUTE_TEST="1", MEUTE_NOW=str(t), **extra)

    def test_invalid_ttl_is_a_config_error_with_no_state_change(self):
        for bad in ("0", "-3", "abc", "1.5", "366", "", " 5", "+5", "1e1"):
            for extra in ({}, dict(MEUTE_TEST="1")):
                with self.subTest(bad=bad, extra=extra):
                    proc = self.fx.resolve(REPORT_A, 1, K1, ABSENT, MEUTE_RECEIPT_TTL_DAYS=bad, **extra)
                    self.assertEqual(proc.returncode, 2, proc.stdout)
                    self.assertEqual(parse(proc), {"error": "invalid_config", "var": "MEUTE_RECEIPT_TTL_DAYS"})
                    self.assertEqual(self.fx.rows(), b"")
                    self.assertFalse((self.fx.state / "receipts").exists())
        for good in ("1", "365", "30"):
            fx = Fixture(self)
            proc = fx.resolve(REPORT_A, 1, K1, ABSENT, MEUTE_RECEIPT_TTL_DAYS=good)
            self.assertEqual(proc.returncode, 0)
            rec = parse(proc)["receipt"]
            self.assertEqual(rec["expires_at"] - rec["created_at"], int(good) * DAY)

    def test_expiry_is_numeric_utc_epoch_across_a_dst_change(self):
        start = 1_772_366_400  # 2026-03-01T12:00Z; US DST starts 2026-03-08
        proc = self.fx.resolve(REPORT_A, 1, K1, ABSENT, TZ="America/New_York", **self.clock(start))
        rec = parse(proc)["receipt"]
        self.assertEqual((rec["created_at"], rec["expires_at"]), (start, start + 30 * DAY))

    def test_expired_receipt_is_absent_so_a_late_replay_is_stale_not_a_double_apply(self):
        first = parse(self.fx.resolve(REPORT_A, 1, K1, ABSENT, **self.clock(T0)))["receipt"]
        live = self.fx.resolve(REPORT_A, 1, K1, ABSENT, **self.clock(T0 + 30 * DAY - 1))
        self.assertTrue(parse(live)["replayed"])
        rows = self.fx.rows()
        late = self.fx.resolve(REPORT_A, 1, K1, ABSENT, **self.clock(T0 + 30 * DAY))
        self.assertEqual(late.returncode, 3, late.stdout)
        self.assertEqual(parse(late)["current_revision"], first["after_revision"])
        self.assertEqual(self.fx.rows(), rows)
        self.assertEqual(self.fx.receipt_files(), [])  # the expired file is gone, not left to hit EEXIST

    def test_expired_file_at_the_path_never_exits_70_a_valid_new_request_succeeds(self):
        first = parse(self.fx.resolve(REPORT_A, 1, K1, ABSENT, **self.clock(T0)))["receipt"]
        again = self.fx.resolve(REPORT_A, 1, K1, first["after_revision"], **self.clock(T0 + 31 * DAY))
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        fresh = parse(again)
        self.assertFalse(fresh["replayed"])
        self.assertNotEqual(fresh["receipt"]["receipt_id"], first["receipt_id"])
        self.assertEqual(fresh["receipt"]["created_at"], T0 + 31 * DAY)
        self.assertEqual(len(self.fx.receipt_files()), 1)

    def test_expired_pending_receipt_is_also_treated_as_absent(self):
        self.fx.resolve(REPORT_A, 1, K1, ABSENT, **hooked("5", MEUTE_NOW=str(T0)))
        proc = self.fx.resolve(REPORT_A, 1, K1, ABSENT, **self.clock(T0 + 40 * DAY))
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertFalse(parse(proc)["replayed"])


# --------------------------------------------------- in-process guarantees ---
class InProcessTest(Base):
    def call_main(self, *argv, env=None):
        import decisions
        out = io.StringIO()
        base = {"MEUTE_ROOT": str(self.fx.root), "PYTHONDONTWRITEBYTECODE": "1"}
        with mock.patch.dict(os.environ, {**base, **(env or {})}, clear=False), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            os.environ.pop("MEUTE_TEST", None)
            code = decisions.main(list(argv))
        return code, out.getvalue()

    def decide_argv(self, key=K1, n="1"):
        return ["decide", "resolve", f"--id={REPORT_A}", f"--finding={n}", "--message=m",
                f"--request-key={key}", f"--expected-revision={ABSENT}"]

    def test_an_uncaught_exception_exits_70_never_1_and_the_retry_completes(self):
        import decisions
        real = decisions.replace_receipt

        def boom(path, rec, *a, **kw):
            if rec["phase"] == "state_written":
                raise RuntimeError("injected")
            return real(path, rec, *a, **kw)
        with mock.patch.object(decisions, "replace_receipt", boom):
            code, out = self.call_main(*self.decide_argv())
        self.assertEqual(code, 70)
        self.assertEqual(json.loads(out)["error"], "internal")
        self.assertEqual(len(self.fx.rows_for(KEY_A1)), 1)  # the row was applied: retry with the SAME key
        code, out = self.call_main(*self.decide_argv())
        self.assertEqual(code, 0, out)
        self.assertEqual(json.loads(out)["receipt"]["phase"], "complete")
        self.assertEqual(len(self.fx.rows_for(KEY_A1)), 1)

    def test_main_never_exits_1_even_when_the_report_library_blows_up(self):
        import decisions
        with mock.patch.object(decisions, "run_decide", side_effect=ValueError("x")):
            code, out = self.call_main(*self.decide_argv())
        self.assertEqual(code, 70)

    def test_row_write_fsyncs_the_file_before_the_swap_and_the_directory_after(self):
        events = []
        real_fsync, real_replace = os.fsync, os.replace

        def where(fd):
            try:
                return os.readlink(f"/proc/self/fd/{fd}")
            except OSError:
                return "?"

        def fsync(fd):
            events.append(("fsync", where(fd)))
            return real_fsync(fd)

        def replace(src, dst, *a, **kw):
            events.append(("replace", str(dst)))
            return real_replace(src, dst, *a, **kw)
        with mock.patch("os.fsync", fsync), mock.patch("os.replace", replace):
            code, out = self.call_main(*self.decide_argv())
        self.assertEqual(code, 0, out)
        state = str(self.fx.state)
        swap = events.index(("replace", f"{state}/reports"))
        before = [e for e in events[:swap] if e[0] == "fsync" and e[1].startswith(f"{state}/.kv.")]
        after = [e for e in events[swap:] if e == ("fsync", state)]
        self.assertTrue(before, events)
        self.assertTrue(after, events)
        receipts = str(self.fx.receipts)
        self.assertTrue(any(e == ("fsync", receipts) for e in events), events)  # the exclusive create

    def test_hooks_are_off_in_process_without_meute_test(self):
        code, out = self.call_main(*self.decide_argv(), env={"MEUTE_DECISIONS_FAIL_AFTER": "5"})
        self.assertEqual(code, 0, out)


if __name__ == "__main__":
    unittest.main()
