"""meute triage inbox -- PRP-003 screen 1, plus the drafts awaiting merge.

An inbox with keyboard actions, not a dashboard: every row leads to a
decision. All data comes from `lib/inbox.py dump`; every write goes through
`bin/meute`. Run with `./bin/meute tui`, or in a browser with `./bin/meute web`.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

from rich.markdown import Markdown
from textual import on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import (
    DataTable, Footer, Header, Input, Label, OptionList, Static, TabbedContent, TabPane,
)
from textual.widgets.option_list import Option

ROOT = os.environ.get("MEUTE_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INBOX = os.path.join(ROOT, "lib", "inbox.py")
SEV_STYLE = {"CRITICAL": "bold red", "HIGH": "red", "MEDIUM": "yellow", "LOW": "dim"}


def _run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, INBOX, *args], capture_output=True, text=True, cwd=ROOT)


from model import Model  # noqa: E402  (textual-free, tested by tests/test_meute.sh)


# ----------------------------------------------------------------- modals ---

class ReasonScreen(ModalScreen[tuple[str, str] | None]):
    """Dismiss needs a reason -- the sole promoted-vs-dismissed signal per lens."""

    BINDINGS = [Binding("escape", "cancel", "cancel")]

    def __init__(self, reasons: list[str], title: str) -> None:
        super().__init__()
        self.reasons, self.title_text = reasons, title

    def compose(self) -> ComposeResult:
        with Vertical(id="modal"):
            yield Label(f"Dismiss: {self.title_text[:70]}")
            yield Label("reason (required):")
            yield OptionList(*[Option(r, id=r) for r in self.reasons], id="reasons")
            yield Input(placeholder="optional note, then Enter", id="note")

    @on(OptionList.OptionSelected)
    def _picked(self, ev: OptionList.OptionSelected) -> None:
        self.chosen = str(ev.option.id)
        self.query_one("#note", Input).focus()

    @on(Input.Submitted)
    def _done(self, ev: Input.Submitted) -> None:
        reason = getattr(self, "chosen", None)
        if not reason:
            self.notify("pick a reason first", severity="warning")
            return
        self.dismiss((reason, ev.value.strip()))

    def action_cancel(self) -> None:
        self.dismiss(None)


class TextScreen(ModalScreen[str | None]):
    BINDINGS = [Binding("escape", "cancel", "cancel")]

    def __init__(self, prompt: str) -> None:
        super().__init__()
        self.prompt = prompt

    def compose(self) -> ComposeResult:
        with Vertical(id="modal"):
            yield Label(self.prompt)
            yield Input(placeholder="required", id="text")

    @on(Input.Submitted)
    def _done(self, ev: Input.Submitted) -> None:
        if ev.value.strip():
            self.dismiss(ev.value.strip())

    def action_cancel(self) -> None:
        self.dismiss(None)


class ConfirmScreen(ModalScreen[bool]):
    BINDINGS = [Binding("y", "yes", "yes"), Binding("n,escape", "no", "no")]

    def __init__(self, text: str) -> None:
        super().__init__()
        self.text = text

    def compose(self) -> ComposeResult:
        with Vertical(id="modal"):
            yield Label(self.text)
            yield Label("[b]y[/b] confirm   [b]n[/b] cancel")

    def action_yes(self) -> None:
        self.dismiss(True)

    def action_no(self) -> None:
        self.dismiss(False)


# -------------------------------------------------------------------- app ---

class Inbox(App):
    CSS = """
    #status { padding: 0 1; background: $panel; color: $text; }
    #main { height: 1fr; }
    #list { width: 55%; }
    #detail { width: 45%; border-left: solid $primary; padding: 0 1; overflow-y: auto; }
    #modal { width: 70; height: auto; border: thick $primary; background: $surface; padding: 1 2; }
    #filter { dock: bottom; }
    """
    BINDINGS = [
        Binding("j,down", "cursor_down", "down", show=False),
        Binding("k,up", "cursor_up", "up", show=False),
        Binding("enter", "open", "detail"),
        Binding("p", "promote", "promote → tier-3 draft"),
        Binding("d", "dismiss_finding", "dismiss (reason)"),
        Binding("r", "resolve", "resolve (fixed by hand)"),
        Binding("slash", "filter", "filter"),
        Binding("g", "jump", "repo"),
        Binding("a", "toggle_decided", "show decided"),
        Binding("R", "reload", "reload"),
        Binding("q", "quit", "quit"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.model = Model()

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Static("", id="status")
        with TabbedContent(id="tabs"):
            with TabPane("Findings", id="findings"):
                with Horizontal(id="main"):
                    yield DataTable(id="list", cursor_type="row", zebra_stripes=True)
                    yield Static("", id="detail")
            with TabPane("Drafts awaiting merge", id="branches"):
                yield DataTable(id="branches_table", cursor_type="row")
            with TabPane("Reports", id="reports"):
                yield DataTable(id="reports_table", cursor_type="row")
        box = Input(placeholder="filter: repo, severity, task, lens, words in the title  (Esc clears)", id="filter")
        box.display = False
        yield box
        yield Footer()

    def on_mount(self) -> None:
        self.title = "meute"
        # The hidden filter box was the first focusable widget and took the
        # keyboard: j/k typed into it and Enter submitted them as a query.
        self.query_one("#list", DataTable).focus()
        # Fixed widths for the short columns so the title gets what is left:
        # the title is the decision, the rest is context.
        # Three columns: the title is the decision, task/lens live in the
        # detail header. Its width is whatever the pane leaves after sev+repo.
        lst = self.query_one("#list", DataTable)
        lst.add_column("sev", width=8, key="sev")
        lst.add_column("repo", width=18, key="repo")
        lst.add_column("title", width=self._title_width(), key="title")
        for tid, cols in (("#branches_table", ("repo", "branch", "date", "base", "unique lines", "state")),
                          ("#reports_table", ("state", "repo", "task", "date", "summary"))):
            self.query_one(tid, DataTable).add_columns(*cols)
        self.action_reload()

    def _title_width(self) -> int:
        pane = self.query_one("#list", DataTable).size.width or 80
        return max(30, pane - 8 - 18 - 8)   # 8: cell padding and the scrollbar

    def on_resize(self) -> None:
        lst = self.query_one("#list", DataTable)
        if "title" in lst.columns:
            lst.columns["title"].width = self._title_width()
            lst.refresh()

    # -- data --------------------------------------------------------------
    def action_reload(self) -> None:
        proc = _run("dump")
        if proc.returncode != 0:
            self.notify(f"inbox dump failed: {proc.stderr.strip()[:200]}", severity="error", timeout=10)
            return
        keep_query, keep_decided = self.model.query, self.model.show_decided
        self.model = Model.from_dump(json.loads(proc.stdout))
        self.model.query, self.model.show_decided = keep_query, keep_decided
        self.refresh_all()

    def refresh_all(self) -> None:
        self.query_one("#status", Static).update(self.model.header_line())
        self.sub_title = self.model.header_line().split("·")[0].strip()
        table = self.query_one("#list", DataTable)
        table.clear()
        last = None
        for f in self.model.visible():
            repo = f["repo"] if f["repo"] != last else ""
            last = f["repo"]
            sev = f"[{SEV_STYLE.get(f['severity'], '')}]{f['severity']}[/]"
            state = "" if f["state"] == "new" else f" [dim]({f['state']})[/]"
            table.add_row(sev, repo, f["title"] + state, key=f"{f['report']}#{f['n']}")
        bt = self.query_one("#branches_table", DataTable)
        bt.clear()
        for b in self.model.branches:
            bt.add_row(b["repo"], b["branch"], b["date"], b["base"], str(b["unique_lines"]),
                       "absorbed -- prunable" if b["absorbed"] else "awaiting review",
                       key=f"{b['repo']}:{b['branch']}")
        rt = self.query_one("#reports_table", DataTable)
        rt.clear()
        for r in sorted(self.model.reports, key=lambda r: r.get("date", ""), reverse=True):
            rt.add_row(r["state"], r["repo"], r["task"], r.get("date", ""), r.get("summary", "")[:80], key=r["id"])
        self.show_detail()

    def current(self) -> dict | None:
        table = self.query_one("#list", DataTable)
        if table.row_count == 0:
            return None
        key = table.coordinate_to_cell_key(table.cursor_coordinate).row_key.value
        rid, _, n = str(key).rpartition("#")
        for f in self.model.findings:
            if f["report"] == rid and f["n"] == int(n):
                return f
        return None

    def show_detail(self) -> None:
        f = self.current()
        detail = self.query_one("#detail", Static)
        if f is None:
            detail.update("nothing to decide")
            return
        try:
            sys.path.insert(0, os.path.join(ROOT, "lib"))
            import inbox as inbox_lib  # local import: only the app needs it
            body = inbox_lib.finding_body(f["report"], f["n"])
        except Exception as e:  # a bad report must not take the UI down
            body = f"(could not read finding: {e})"
        head = f"**{f['repo']}** · {f['task']} / {f['lens']} · {f['date']} · `{f['report']}#{f['n']}`"
        if f["state"] != "new":
            head += f"\n\n_{f['state']}_ {f.get('decided_at','')} {f.get('note','')}"
        detail.update(Markdown(head + "\n\n" + body))

    @on(DataTable.RowHighlighted, "#list")
    def _moved(self) -> None:
        self.show_detail()

    # -- navigation --------------------------------------------------------
    def action_cursor_down(self) -> None:
        self.query_one("#list", DataTable).action_cursor_down()

    def action_cursor_up(self) -> None:
        self.query_one("#list", DataTable).action_cursor_up()

    def action_open(self) -> None:
        self.show_detail()

    def action_filter(self) -> None:
        box = self.query_one("#filter", Input)
        box.display = True
        box.value = self.model.query
        box.focus()

    @on(Input.Submitted, "#filter")
    def _filtered(self, ev: Input.Submitted) -> None:
        self.model.query = ev.value.strip()
        ev.input.display = False
        self.query_one("#list", DataTable).focus()
        self.refresh_all()

    def on_key(self, event) -> None:
        # Esc in the filter box clears it and returns to the list.
        box = self.query_one("#filter", Input)
        if event.key == "escape" and box.has_focus:
            box.value = ""
            self.model.query = ""
            box.display = False
            self.query_one("#list", DataTable).focus()
            self.refresh_all()

    def action_toggle_decided(self) -> None:
        self.model.show_decided = not self.model.show_decided
        self.refresh_all()

    def action_jump(self) -> None:
        repos = self.model.repos()
        if not repos:
            return
        cur = self.current()
        i = repos.index(cur["repo"]) if cur and cur["repo"] in repos else -1
        target = repos[(i + 1) % len(repos)]
        idx = self.model.first_index_of_repo(target)
        if idx >= 0:
            self.query_one("#list", DataTable).move_cursor(row=idx)

    # -- decisions ---------------------------------------------------------
    def _act(self, verb: str, *rest: str) -> None:
        f = self.current()
        if f is None:
            return
        proc = _run(verb, f["report"], str(f["n"]), *rest)
        try:
            result = json.loads(proc.stdout or "{}")
        except json.JSONDecodeError:
            result = {"ok": proc.returncode == 0, "message": (proc.stderr or proc.stdout).strip()}
        self.notify(result.get("message", "")[:300], severity="information" if result.get("ok") else "error",
                    timeout=8)
        self.action_reload()

    def action_promote(self) -> None:
        f = self.current()
        if f is None:
            return
        self.push_screen(ConfirmScreen(f"Promote to a tier-3 draft?\n\n{f['severity']} {f['title'][:80]}"),
                         lambda ok: self._act("promote") if ok else None)

    def action_dismiss_finding(self) -> None:
        f = self.current()
        if f is None:
            return
        self.push_screen(ReasonScreen(self.model.dismiss_reasons, f["title"]),
                         lambda r: self._act("dismiss", r[0], r[1]) if r else None)

    def action_resolve(self) -> None:
        f = self.current()
        if f is None:
            return
        self.push_screen(TextScreen("Resolved how? (e.g. a PR link) -- required"),
                         lambda m: self._act("resolve", m) if m else None)


def main() -> None:
    Inbox().run()


if __name__ == "__main__":
    main()
