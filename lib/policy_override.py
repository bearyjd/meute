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
import os
import sys

OVERRIDABLE = ("quota_floor_percent", "weekly_runs", "weekly_cost_usd",
               "community_share", "tier3_max_in_flight")
MAX_SECONDS = 7 * 86400
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


def read_rows(path: str, now: int) -> dict:
    """key -> (value, until, reason) for rows still in force."""
    rows = {}
    try:
        handle = open(path, "r", encoding="utf-8")
    except FileNotFoundError:
        return rows
    with handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 3 or fields[0] not in OVERRIDABLE or not fields[2].isdigit():
                continue
            until = int(fields[2])
            if now < until <= now + MAX_SECONDS:
                rows[fields[0]] = (parse_value(fields[1]), until,
                                   fields[3] if len(fields) > 3 else "")
    return rows


def effective_policy(data: dict, values: dict) -> dict:
    from manifest import merged_policy
    patched = dict(data)
    base = dict(data.get("policy") or {}) if isinstance(data.get("policy") or {}, dict) else {}
    for ceiling in CEILINGS:
        if ceiling in values and values[ceiling] is not None:
            for other in CEILINGS:
                if other != ceiling and other not in values:
                    base.pop(other, None)
    base.update(values)
    patched["policy"] = base
    return merged_policy(patched)


def cmd_policy_effective(args: list) -> int:
    """policy-effective MANIFEST [OVERRIDE_FILE]: the policy a run obeys.

    An override that does not validate is reported on stderr and skipped: a
    typo in a state file must not stop the fleet, and the manifest's own
    policy is the conservative fallback.
    """
    from manifest import ManifestError, load, merged_policy
    data = load(args[0])
    now = now_epoch()
    rows = read_rows(args[1], now) if len(args) > 1 else {}
    values = {key: row[0] for key, row in rows.items()}
    env_floor = os.environ.get("MEUTE_QUOTA_FLOOR", "")
    if env_floor:
        values["quota_floor_percent"] = parse_value(env_floor)
    policy = merged_policy(data)
    if values:
        try:
            policy = effective_policy(data, values)
            policy["override"] = sorted(values)
        except ManifestError as error:
            sys.stderr.write(f"meute/manifest: policy override ignored: {error}\n")
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
