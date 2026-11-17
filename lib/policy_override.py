"""Expiring policy overrides (resilience plan P1.1, owner decision D2).

state/policy-override holds tab-separated rows: key, value, until-epoch, reason.
The manifest's policy is the base; an unexpired row replaces that key, and the
result goes through merged_policy, the same rules the manifest answers to. An
override that cannot be forgotten: every row has an expiry, and a row whose
expiry is past the 7-day cap (a hand edit) is ignored like an expired one.

MEUTE_QUOTA_FLOOR=<n> is the one-invocation form: nothing is written.
"""
from __future__ import annotations

import json
import math
import os
import stat
import sys

OVERRIDABLE = ("quota_floor_percent", "weekly_runs", "weekly_cost_usd",
               "community_share", "tier3_max_in_flight")
MAX_SECONDS = 7 * 86400
MAX_BYTES = 1 << 20
MAX_UNTIL_DIGITS = 12
# Setting one ceiling must not trip merged_policy's "not both" rule against the
# other one the manifest happens to carry.
CEILINGS = ("weekly_runs", "weekly_cost_usd")


def _fail(message: str):
    from manifest import ManifestError
    raise ManifestError(message)


def parse_value(text: str):
    if text in ("null", "none"):
        return None
    for cast in (int, float):
        try:
            return cast(text)
        except ValueError:
            pass
    return text


def now_epoch() -> int:
    return int(os.environ.get("MEUTE_NOW") or __import__("time").time())


def _read_capped(path: str):
    """The file's bytes, or None (logged) when it is not a plain file of sane size.

    O_NONBLOCK so a FIFO cannot block the open; fstat before reading so a
    device (a symlink to /dev/zero) is never read at all.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as error:
        # A hand-made mess (no permission) is no override: the manifest's
        # policy applies, and the run goes on.
        _skipped(f"{path}: {error.strerror or error}")
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            _skipped(f"{path}: not a regular file")
            return None
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            raw = handle.read(MAX_BYTES + 1)
    except OSError as error:
        _skipped(f"{path}: {error.strerror or error}")
        return None
    finally:
        if fd >= 0:
            os.close(fd)
    if len(raw) > MAX_BYTES:
        # Never parse a truncated tail: a cut-off value is a different number.
        _skipped(f"{path}: too large (over {MAX_BYTES} bytes)")
        return None
    return raw


def read_rows(path: str, now: int, ignored: list | None = None) -> dict:
    """key -> (value, until, reason) for rows still in force.

    A row that cannot be read is skipped and logged; when `ignored` is given,
    (key, why) is appended to it so the caller can say so where it is seen.
    """
    rows = {}
    raw = _read_capped(path)
    if raw is None:
        return rows

    def skip(key: str, why: str) -> None:
        _skipped(why)
        if ignored is not None and key in OVERRIDABLE:
            ignored.append((key, why))

    for number, raw_line in enumerate(raw.splitlines(), 1):
        try:
            line = raw_line.decode("utf-8")
        except UnicodeDecodeError:
            skip(raw_line.split(b"\t", 1)[0].decode("ascii", "replace"), f"{path}:{number}: not UTF-8")
            continue
        fields = line.split("\t")
        if len(fields) < 3 or fields[0] not in OVERRIDABLE:
            continue
        # str.isdigit() accepts '\u00b2', which int() refuses; and an until
        # of thousands of digits trips Python's int-string limit (it would be
        # past the 7-day cap anyway).
        if not (fields[2].isascii() and fields[2].isdigit() and len(fields[2]) <= MAX_UNTIL_DIGITS):
            skip(fields[0], f"{path}:{number}: until {fields[2][:20]!r} is not an epoch")
            continue
        until = int(fields[2])
        value = parse_value(fields[1])
        # A hand-edited nan/inf is no value at all: skipped like an expired
        # row, so the other rows stay live and `policy show` agrees.
        if isinstance(value, float) and not math.isfinite(value):
            continue
        if now < until <= now + MAX_SECONDS:
            rows[fields[0]] = (value, until, fields[3] if len(fields) > 3 else "")
    return rows


def _skipped(why: str) -> None:
    sys.stderr.write(f"meute/manifest: policy override: skipped {why}\n")


def effective_policy(data: dict, values: dict) -> dict:
    from manifest import merged_policy
    patched = dict(data)
    base = dict(data.get("policy") or {}) if isinstance(data.get("policy") or {}, dict) else {}
    for ceiling in CEILINGS:
        if ceiling in values and values[ceiling] is not None:
            for other in CEILINGS:
                if other != ceiling and other not in values:
                    base.pop(other, None)
    for key, value in values.items():
        # NaN passes merged_policy's `<= 0` test and jq prints it as null,
        # which reads downstream as "no ceiling"; inf is no ceiling either.
        if isinstance(value, float) and not math.isfinite(value):
            _fail(f"policy override: {key}={value}: must be a finite number")
    base.update(values)
    patched["policy"] = base
    return merged_policy(patched)


def resolve(data: dict, path: str | None, now: int, env_floor: str = ""):
    """(policy, applied keys, ignored [(key, why)]) for the rows in `path`.

    Rows are taken one at a time in file order, then MEUTE_QUOTA_FLOOR: a row
    that does not validate on top of those already taken is ignored alone, so
    a typo beside a tightening row costs the typo, never the tightening.
    """
    from manifest import ManifestError, merged_policy
    ignored = []
    rows = read_rows(path, now, ignored) if path else {}
    candidates = [(key, key, row[0]) for key, row in rows.items()]
    if env_floor:
        candidates.append(("MEUTE_QUOTA_FLOOR", "quota_floor_percent", parse_value(env_floor)))
    values, applied = {}, []
    for label, key, value in candidates:
        trial = {**values, key: value}
        try:
            effective_policy(data, trial)
        except ManifestError as error:
            sys.stderr.write(f"meute/manifest: policy override ignored: {label}: {error}\n")
            ignored.append((label, str(error)))
            continue
        values = trial
        applied = sorted(set(applied) | {key})
    policy = effective_policy(data, values) if values else merged_policy(data)
    return policy, applied, ignored


def cmd_policy_effective(args: list) -> int:
    """policy-effective MANIFEST [OVERRIDE_FILE]: the policy a run obeys.

    An override row that does not validate is reported on stderr, named in
    `override_ignored`, and skipped alone: a typo in a state file must not
    stop the fleet, nor silently void the other rows beside it.
    """
    from manifest import load
    data = load(args[0])
    policy, applied, ignored = resolve(data, args[1] if len(args) > 1 else None,
                                       now_epoch(), os.environ.get("MEUTE_QUOTA_FLOOR", ""))
    if applied:
        policy["override"] = applied
    if ignored:
        policy["override_ignored"] = [f"{key}: {why}" for key, why in ignored]
    print(json.dumps(policy))
    return 0


def cmd_policy_check(args: list) -> int:
    """policy-check MANIFEST OVERRIDE_FILE key=value...: refuse what `policy set` must not store.

    Checks what the file will hold after the write, not the new pairs alone:
    the rows still in force, minus the other ceiling when a ceiling is set
    (policy_override_set deletes that row), plus the new pairs.
    """
    from manifest import load
    data = load(args[0])
    new = {}
    for assignment in args[2:]:
        key, sep, text = assignment.partition("=")
        if not sep or key not in OVERRIDABLE:
            _fail(f"policy set: {assignment!r}: expected key=value with key one of {', '.join(OVERRIDABLE)}")
        new[key] = parse_value(text)
    if not new:
        _fail("policy set: give at least one key=value")
    evicted = {other for key in new if key in CEILINGS for other in CEILINGS if other not in new}
    values = {key: row[0] for key, row in read_rows(args[1], now_epoch()).items()
              if key not in evicted}
    values.update(new)
    effective_policy(data, values)
    return 0
