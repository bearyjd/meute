"""Whether a report may show a finding that the inbox parser does not list.

The inbox lists exactly the report_lib.FINDING_RE lines, and readiness accepts
those only inside a canonical `## Findings` section. Every other line that
names a severity is judged by its shape, on a folded copy of the line (see
fold). It makes the report malformed when it is:

1. structural: after indentation, `>` and list markers it starts with `#`,
   `<`, `=` or a link or footnote definition; it is underlined into a setext heading;
   it holds an HTML heading tag anywhere; or it is a table row with a cell that
   is only a severity, optionally followed by a parenthesis (any cell when the
   row opens with a pipe, else the first);
2. a title: it starts with `[SEV]` or `(SEV, qualifier)` followed by anything
   but the word "finding", in any emphasis, after any list or `A)` marker;
3. a field or label: `Severity: SEV`, or running text that opens with
   `SEV - ...` or `SEV: ...`;
4. a list, quote or emphasis line that leads with a severity, brackets one, or
   is bold from end to end, when no parsed finding of the same report has that
   severity. With such a finding the line is read as a reference to it.

A severity in the middle of a list item or a field value, and in running text,
is not a finding. A heading that holds a `[` is malformed whatever it names,
unless it is indented as code. Inside a Findings section every `###` heading
must parse, except one that starts with "Not " or "No " and holds neither a
severity nor a bracket. Fenced code blocks are not exempt, because the inbox
parser does not exempt them.

Task-list boxes count as list markers, and emoji and other symbols before a
severity are dropped by fold.

Not caught: a severity named mid-sentence or after a title ("Note: [HIGH] SQL
injection", "SQL injection (HIGH)"); running text that opens with a severity
and no dash or colon; a rating field under another name ("Risk: High"); a
lookalike outside CONFUSABLES; a severity cell after the first in a table row
with no leading pipe; a severity spelled with digits or spaces, or
split across two lines outside a heading; an unknown label outside a heading
("- [SEVERE] x"); and a severity-leading list or emphasis line when the report
already has a parsed finding of that severity.
"""

from __future__ import annotations

import re
import unicodedata

import report as report_lib

SEVERITY = r"(?:crit(?:ical)?|high|med(?:ium)?|low)"
# A severity word or its inbox abbreviation, but not a longer word or a path segment (highly, src/low.py).
SEVERITY_WORD = re.compile(rf"(?<![^\W_])(?<![./]){SEVERITY}(?![^\W_]|/|\.\w)", re.I)
FINDING_HEADING = re.compile(r"^###\s.*$", re.M)
FINDINGS_SECTION = re.compile(r"^## Findings\s*$", re.M)  # report_lib.has_findings_section, every occurrence
NEXT_SECTION = re.compile(r"^##\s+", re.M)
ORDERED_ITEM = re.compile(r"\d+[.):]")
SETEXT_UNDERLINE = re.compile(r"\s*(?:=+|-+)\s*$")
# Cyrillic and Greek letters drawn like the Latin letters of the severity words. Nothing else is folded.
CONFUSABLES = str.maketrans(
    "АаСсЕеНҺһІіӀӏМОоТԀԁԌԜԝгΑΕΗΙιΜΟοΤυ",
    "AaCcEeHHhIiIlMOoTDdGWwrAEHIiMOoTu",
)
DROPPED = ("Cf", "Mn", "So", "Sk")  # zero-width and format characters, combining marks, emoji and other symbols
QUOTE_OR_LIST = re.compile(r"(?:[\s>]|(?:[-*+]|\d+[.):])\s(?:\[[ xX]\]\s)?)*")
LINK_DEFINITION = re.compile(r"\[[^\]]*\]:")
HTML_HEADING = re.compile(r"<h[1-6]", re.I)
BRACKETED = re.compile(rf"[\[(]\s*({SEVERITY})\s*(?:[,;][^\])\n]{{0,30}})?[\])]", re.I)
TITLE = re.compile(
    rf"(?:[A-Za-z]{{1,4}}[.)]\s+)?[*_`~\s]*{BRACKETED.pattern}[*_`]*\s*(?!finding\b)[^\s:*]", re.I)
LEADING = re.compile(rf"[\s*_`~\[(]*({SEVERITY_WORD.pattern})", re.I)
LABEL = re.compile(rf"{SEVERITY}(?:\s+[-–—]|:)\s+\S", re.I)
SEVERITY_FIELD = re.compile(rf"[*_`\s]*severity[*_`\s]*[:=\-\u2013\u2014][*_`\s]*{SEVERITY}(?![^\W_])", re.I)
SEVERITY_CELL = re.compile(rf"(?:^|\|)\s*[*_`\[\s]*{SEVERITY}[*_`\]\s]*\s*(?:\([^|)]*\)\s*)?(?:\||$)", re.I)
BOLD_ONLY = re.compile(r"(\*\*|__).*\1:?")
DISMISSAL = re.compile(r"###\s+(?:not|no)\s", re.I)
BRACKET = re.compile(r"[\[(]")
CODE_INDENT = re.compile(r" {4}|\t")
ATX_HEADING = re.compile(r"#{1,6}\s")


def fold(line: str) -> str:
    """The line as a reader sees it: compatibility forms, invisible characters and lookalikes folded."""
    if line.isascii():
        return line
    plain = unicodedata.normalize("NFKD", line)
    return "".join(c for c in plain if unicodedata.category(c) not in DROPPED).translate(CONFUSABLES)


def findings_spans(body: str) -> list[tuple[int, int]]:
    """(start, end) offsets of the text under every canonical `## Findings` heading."""
    spans = []
    for match in FINDINGS_SECTION.finditer(body):
        following = NEXT_SECTION.search(body, match.end())
        spans.append((match.end(), following.start() if following else len(body)))
    return spans


def _prefix_end(line: str) -> int:
    """Offset where the indentation, quote and list markers of a line end."""
    prefix = QUOTE_OR_LIST.match(line)
    return prefix.end() if prefix else 0  # the pattern can match empty, so None does not occur


def _severity_cell_row(line: str) -> bool:
    """A table row with a cell that is only a severity: any cell when the row opens with a pipe, else the first.

    Later cells of a row without a leading pipe are not read: `"a | critical | b"` in a sentence is prose."""
    if "|" not in line:
        return False
    cell = SEVERITY_CELL.search if line.lstrip().startswith("|") else SEVERITY_CELL.match
    return cell(line) is not None


def _plain_prose(text: str, following: str) -> bool:
    """Running text: starts with a letter or digit, is no ordered item and no setext heading."""
    return text[0].isalnum() and not ORDERED_ITEM.match(text) and not SETEXT_UNDERLINE.match(following)


def _structural(line: str, core: str, following: str) -> bool:
    if core.startswith(("#", "<", "=")) or LINK_DEFINITION.match(core):
        return True
    return bool(SETEXT_UNDERLINE.match(following) or HTML_HEADING.search(line))


def _suspicious(line: str, following: str, parsed: set[str]) -> bool:
    """Whether a folded line naming a severity may be a finding the inbox does not list."""
    core = line[_prefix_end(line):]
    if _structural(line, core, following) or TITLE.match(core) or SEVERITY_FIELD.match(core):
        return True
    if _severity_cell_row(line):
        return True
    if _plain_prose(line.strip(), following):
        return LABEL.match(core) is not None
    hits = [match.group(1) for match in (LEADING.match(core), BRACKETED.search(line)) if match]
    if not hits and not BOLD_ONLY.fullmatch(core.strip()):
        return False  # a severity inside a list item or a field value
    named = {word[:3].lower() for word in hits or SEVERITY_WORD.findall(line)}
    return not named <= parsed


def _extra_heading(listed: str) -> bool:
    """A `###` heading under Findings that is neither a parsed finding nor a "not a finding" note."""
    headings = FINDING_HEADING.findall(listed)
    dismissed = [h for h in headings if DISMISSAL.match(h) and not BRACKET.search(fold(h))]  # a severity: _suspicious
    return len(headings) - len(dismissed) != len(report_lib.parse_findings(listed))


def unlisted_finding(body: str) -> bool:
    """Whether the report body may hold a finding the inbox would not list."""
    spans = findings_spans(body)
    listed = "\n".join(body[start:end] for start, end in spans)
    if _extra_heading(listed):
        return True
    read: set[int] = set()
    for match in report_lib.FINDING_RE.finditer(body):
        if not any(start <= match.start() and match.end() <= end for start, end in spans):
            return True
        read.update(range(body.count("\n", 0, match.start()), body.count("\n", 0, match.end()) + 1))
    parsed = {finding["severity"][:3].lower() for finding in report_lib.parse_findings(listed)}
    lines = [fold(line) for line in body.split("\n")]
    for index, line in enumerate(lines):
        if index in read or not line.strip():
            continue
        if SEVERITY_WORD.search(line):
            if _suspicious(line, lines[index + 1] if index + 1 < len(lines) else "", parsed):
                return True
        elif _bracket_heading(line):
            return True
    return False


def _bracket_heading(line: str) -> bool:
    """A heading that holds a bracket and is not indented as code: it may be a title under an unknown label."""
    if "[" not in line or CODE_INDENT.match(line):
        return False
    return ATX_HEADING.match(line, _prefix_end(line)) is not None
