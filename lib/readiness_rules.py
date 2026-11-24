"""Operator-policy rules for readiness: assessment, deferrals and accepted conditions."""

from __future__ import annotations

from datetime import datetime, timezone
import re

from evidence import SHA256
from report import SEVERITIES

CATEGORIES = ("security", "cleanup")
CONDITIONS = ("codemap_missing", "baseline_preexisting_failure")
SCOPE = ("repo", "slice_id", "plan_revision")
FINGERPRINT = r"[0-9a-f]{40}"
UTC_TIMESTAMP = (
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]{1,6})?(?:Z|\+00:00)"
)
DEFERRAL_FIELDS = {"finding", "fingerprint", *SCOPE, "reason", "expires_at"}
CONDITION_FIELDS = {"condition", *SCOPE, "reason"}


def parse_utc(value) -> datetime | None:
    """A timezone-aware UTC instant, or None for naive and non-UTC text."""
    if not isinstance(value, str) or re.fullmatch(UTC_TIMESTAMP, value) is None:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def _text(value) -> bool:
    return isinstance(value, str) and bool(value) and value == value.strip() and value.isprintable()


def _matches(pattern: str, value) -> bool:
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def _check_category(category) -> bool:
    if not (isinstance(category, dict) and category.keys() == {"affirmed", "findings"}):
        return False
    if not isinstance(category["affirmed"], bool) or not isinstance(category["findings"], dict):
        return False
    return all(
        _text(key) and isinstance(item, dict) and item.keys() == {"fingerprint", "applicable"}
        and _matches(FINGERPRINT, item["fingerprint"]) and isinstance(item["applicable"], bool)
        for key, item in category["findings"].items()
    )


def _check_listed(items, fields: set[str]) -> bool:
    return isinstance(items, list) and all(
        isinstance(item, dict) and item.keys() == fields
        and all(_text(item[key]) for key in fields - {"expires_at"}) for item in items
    )


def validate_rules(policy: dict) -> None:
    """Raise ValueError naming the first malformed 4.2 policy field."""
    assessment = policy["assessment"]
    if not (isinstance(assessment, dict) and assessment.keys() == set(CATEGORIES)
            and all(_check_category(assessment[name]) for name in CATEGORIES)):
        raise ValueError("Expected an assessment of security and cleanup with per-finding applicability")
    severities = policy["severity_policy"]
    if not (isinstance(severities, list) and severities and set(severities) <= set(SEVERITIES)
            and len(set(severities)) == len(severities)):
        raise ValueError("Expected severity_policy to list at least one severity")
    attested = policy["attested_digests"]
    if not (isinstance(attested, list) and all(_matches(SHA256, item) for item in attested)):
        raise ValueError("Expected attested_digests to list SHA-256 digests")
    if not _check_listed(policy["deferrals"], DEFERRAL_FIELDS) or any(
        not _matches(FINGERPRINT, item["fingerprint"]) or parse_utc(item["expires_at"]) is None
        for item in policy["deferrals"]
    ):
        raise ValueError("Expected scoped deferrals with a UTC expires_at")
    conditions = policy["accepted_conditions"]
    if not _check_listed(conditions, CONDITION_FIELDS) or any(
        item["condition"] not in CONDITIONS for item in conditions
    ):
        raise ValueError("Expected scoped accepted_conditions naming a known condition")
    if not _text(policy["evidence_root"]) or not policy["evidence_root"].startswith("/"):
        raise ValueError("Expected an absolute evidence_root")


def covers(items: list[dict], scope: dict) -> list[dict]:
    """Rules whose scope equals the record scope, in policy order."""
    return [item for item in items if all(item[key] == scope[key] for key in SCOPE)]


def expired(deferral: dict, now: datetime) -> bool:
    """Expiry is exclusive: at now == expires_at the deferral is already expired."""
    return now >= parse_utc(deferral["expires_at"])
