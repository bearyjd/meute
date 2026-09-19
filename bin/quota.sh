#!/usr/bin/env bash
#
# meute quota probe.
#
# "Quota" here means one engine's *subscription* allowance — the plan's
# rolling window and weekly pool — expressed as a percentage still available.
# It is NOT a dollar budget: meute is subscription-only and never
# runs on metered API billing, so there is no spend to cap. The cost figures the
# runner records in state/log are the list-price equivalent of work already paid
# for by the seat; they are useful for ranking which tasks are expensive, and
# they are not what this gate measures.
#
# The gate exists for one reason: a scheduled chore must never consume the
# window the human wants for interactive work. Both pools matter, and the
# binding one is whichever is scarcer right now — report the MINIMUM of the two
# if your source can see both.
#
# Contract: print a single integer 0-100 to stdout and exit 0. Print nothing
# else to stdout. Exit non-zero only if no source could be consulted at all; the
# runner treats that as "unknown" and declines to run, because starving the
# human is worse than skipping a chore.
#
# Sources for Claude, in precedence order:
#   1. $MEUTE_CLAUDE_QUOTA_CMD external command; its stdout must be an integer
#                              0-100. $MEUTE_QUOTA_CMD remains its legacy alias.
#   2. state/rate-limits.json  Claude's own 5-hour/7-day windows, as snapshotted
#                              by the status line; read through
#                              contrib/quota-subscription.sh. Installed by
#                              `meute install-statusline`.
#   3. state/quota-override    a file containing an integer; wins over the stub
#   4. $MEUTE_QUOTA_STUB       the stub value (default 100)
#
# Codex has no built-in balance source. It runs only when
# $MEUTE_CODEX_QUOTA_CMD is configured; otherwise this probe fails closed. A
# Claude snapshot, override, generic command, or stub must never be presented
# as a Codex balance.
#
# No CLI subcommand exposes the balance — `claude auth status --json` reports
# the plan tier, not the pools — but the status line's stdin JSON does, for
# Pro/Max seats: `rate_limits.five_hour` and `rate_limits.seven_day`, each with
# `used_percentage` and `resets_at`. Source 2 is that, captured. It is the only
# built-in source that measures what this gate is for; the stub measures nothing.
#
# Usage: quota.sh [-v] [--engine claude|codex] [--with-source]
#   --engine       selects the subscription pool. Defaults to claude for
#                  backwards compatibility with existing direct callers.
#   --with-source  print "<percent> <source>" instead of just the percent, so the
#                  runner can record in state/log whether the gate is real or a stub.
set -Eeuo pipefail

readonly MEUTE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly OVERRIDE_FILE="${MEUTE_ROOT}/state/quota-override"

verbose=0
with_source=0
engine="claude"
while (( $# )); do
  case "$1" in
    -v) verbose=1 ;;
    --with-source) with_source=1 ;;
    --engine) engine="${2:?quota.sh: --engine needs a value}"; shift ;;
    *) printf 'quota.sh: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[[ "$engine" =~ ^(claude|codex)$ ]] \
  || { printf 'quota.sh: unknown engine %s\n' "$engine" >&2; exit 2; }

note() { (( verbose )) && printf 'quota: %s\n' "$1" >&2; return 0; }

# Accept only a bare integer in 0-100. Anything else is a broken source, not a
# reason to guess.
valid() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 0 && $1 <= 100 ))
}

emit() {
  local value="$1" source="$2"
  if ! valid "$value"; then
    printf 'quota.sh: %s produced %q, expected an integer 0-100\n' "$source" "$value" >&2
    return 1
  fi
  note "${value}% remaining (source: ${source})"
  if (( with_source )); then
    printf '%s %s\n' "$value" "$source"
  else
    printf '%s\n' "$value"
  fi
  return 0
}

# A configured probe that fails is NOT "no source available" — it is a broken
# source. Falling back to the stub here would silently disable the gate and let
# the fleet run at full speed exactly when the operator asked it not to.
run_configured_probe() {
  local command="$1" label="$2" raw
  if raw="$(eval "$command" 2>/dev/null)"; then
    emit "${raw//[[:space:]]/}" "$(basename "${command%% *}")"
    exit $?
  fi
  printf 'quota.sh: %s failed. Refusing to guess — the runner will\n' "$label" >&2
  printf 'quota.sh: decline this slot rather than run against an unknown quota.\n' >&2
  exit 1
}

case "$engine" in
  codex)
    if [[ -n "${MEUTE_CODEX_QUOTA_CMD:-}" ]]; then
      run_configured_probe "$MEUTE_CODEX_QUOTA_CMD" "MEUTE_CODEX_QUOTA_CMD"
    fi
    printf 'quota.sh: no Codex quota probe is configured. Set MEUTE_CODEX_QUOTA_CMD\n' >&2
    printf 'quota.sh: to a command that prints remaining subscription percent (0-100).\n' >&2
    exit 1
    ;;
  claude)
    if [[ -n "${MEUTE_CLAUDE_QUOTA_CMD:-}" ]]; then
      run_configured_probe "$MEUTE_CLAUDE_QUOTA_CMD" "MEUTE_CLAUDE_QUOTA_CMD"
    fi
    # The generic command predates engine selection and remains Claude's alias.
    if [[ -n "${MEUTE_QUOTA_CMD:-}" ]]; then
      run_configured_probe "$MEUTE_QUOTA_CMD" "MEUTE_QUOTA_CMD"
    fi
    ;;
esac

# A snapshot that exists but cannot be read is a broken source, same as a
# failing MEUTE_QUOTA_CMD: fail closed rather than fall through to the stub.
readonly SNAPSHOT_FILE="${MEUTE_ROOT}/state/rate-limits.json"
if [[ -f "$SNAPSHOT_FILE" ]]; then
  if raw="$("${MEUTE_ROOT}/contrib/quota-subscription.sh" 2>/dev/null)"; then
    emit "${raw//[[:space:]]/}" "quota-subscription.sh"
    exit $?
  fi
  printf 'quota.sh: state/rate-limits.json is present but unreadable. Refusing to\n' >&2
  printf 'quota.sh: guess — delete it to fall back, or let the status line rewrite it.\n' >&2
  exit 1
fi

if [[ -f "$OVERRIDE_FILE" ]]; then
  emit "$(tr -d '[:space:]' < "$OVERRIDE_FILE")" "state/quota-override"
  exit $?
fi

emit "${MEUTE_QUOTA_STUB:-100}" "stub"
