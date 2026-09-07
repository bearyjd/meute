"""The inbox's view logic, kept free of Textual so it is testable without a
terminal or the venv: tests/test_meute.sh runs this under the system python3.
"""

from __future__ import annotations

from dataclasses import dataclass, field



@dataclass
class Model:
    findings: list[dict] = field(default_factory=list)
    reports: list[dict] = field(default_factory=list)
    branches: list[dict] = field(default_factory=list)
    status: dict = field(default_factory=dict)
    dismiss_reasons: list[str] = field(default_factory=list)
    query: str = ""
    show_decided: bool = False

    @classmethod
    def from_dump(cls, data: dict) -> "Model":
        return cls(findings=data.get("findings", []), reports=data.get("reports", []),
                   branches=data.get("branches", []), status=data.get("status", {}),
                   dismiss_reasons=data.get("dismiss_reasons", []))

    def visible(self) -> list[dict]:
        """Undecided by default, grouped by repo, most severe first -- the
        order lib/inbox.py already returns. `/` narrows on any column."""
        rows = self.findings if self.show_decided else [f for f in self.findings if f["state"] == "new"]
        if self.query:
            q = self.query.casefold()
            rows = [f for f in rows if q in " ".join(
                str(f.get(k, "")) for k in ("repo", "severity", "task", "lens", "title", "location", "state")
            ).casefold()]
        return rows

    def repos(self) -> list[str]:
        seen: list[str] = []
        for f in self.visible():
            if f["repo"] not in seen:
                seen.append(f["repo"])
        return seen

    def first_index_of_repo(self, repo: str) -> int:
        for i, f in enumerate(self.visible()):
            if f["repo"] == repo:
                return i
        return -1

    def header_line(self) -> str:
        s = self.status
        q = s.get("quota")
        src = s.get("quota_source") or "?"
        floor = s.get("floor")
        if q is None:
            gate = "quota ?"
        elif src == "stub":
            gate = "quota UNMEASURED (stub) -- run: meute install-statusline"
        elif floor is not None and q < floor:
            gate = f"quota {q}% BELOW FLOOR {floor}%"
        else:
            gate = f"quota {q}% ok"
        ceiling = s.get("ceiling")
        spend = f"${s.get('cost', 0):.2f}" + (f" of ${ceiling}" if isinstance(ceiling, float) else "")
        new = sum(1 for f in self.findings if f["state"] == "new")
        return (f"{gate}  ·  week {s.get('week','?')}: {s.get('runs',0)} runs, "
                f"{s.get('declined',0)} declined, {spend}  ·  {new} undecided")


