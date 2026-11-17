"""tui/model.py: a finding that inherited a dismissal is decided, as in the web UI."""
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tui"))
from model import Model  # noqa: E402


def _finding(n, state="new", inherited=""):
    return {"report": "alpha/audit-01", "n": n, "repo": "alpha", "severity": "high",
            "task": "audit", "lens": "x", "title": f"t{n}", "location": "",
            "state": state, "inherited": inherited}


class InheritedDecisionTest(unittest.TestCase):
    def setUp(self):
        self.model = Model(findings=[_finding(1), _finding(2, inherited="dismissed"),
                                     _finding(3, state="dismissed")])

    def test_visible_hides_inherited_dismissed(self):
        self.assertEqual([f["n"] for f in self.model.visible()], [1])

    def test_show_decided_lists_inherited_dismissed(self):
        self.model.show_decided = True
        self.assertEqual([f["n"] for f in self.model.visible()], [1, 2, 3])

    def test_header_undecided_count_excludes_inherited(self):
        self.assertIn("1 undecided", self.model.header_line())


if __name__ == "__main__":
    unittest.main()
