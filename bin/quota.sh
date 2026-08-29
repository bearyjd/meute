#!/usr/bin/env bash
#
# meute quota probe.
#
# "Quota" here means the Claude/ChatGPT *subscription* allowance — the plan's
# rolling 5-hour window and its weekly pool — expressed as a percentage still
# available. It is NOT a dollar budget: meute is subscription-only and never
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
# Sources, in precedence order:
#   1. $MEUTE_QUOTA_CMD      external command; its stdout must be an integer 0-100
#   2. state/quota-override  a file containing an integer; wins over the stub
#   3. $MEUTE_QUOTA_STUB     the stub value (default 100)
#
# There is deliberately no built-in probe. As of Claude Code 2.1.x the remaining
# 5-hour/weekly allowance is only exposed interactively (/usage); `claude auth
# status --json` reports the plan tier but not the balance. Point MEUTE_QUOTA_CMD
# at whatever source you trust and this file does not need to change.
#
# Usage: quota.sh [-v] [--with-source]
#   --with-source  print "<percent> <source>" instead of just the percent, so the
#                  runner can record in state/log whether the gate is real or a stub.
set -Eeuo pipefail

readonly MEUTE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly OVERRIDE_FILE="${MEUTE_ROOT}/state/quota-override"

verbose=0
with_source=0
for arg in "$@"; do
  case "$arg" in
    -v) verbose=1 ;;
    --with-source) with_source=1 ;;
    *) printf 'quota.sh: unknown argument %s\n' "$arg" >&2; exit 2 ;;
  esac
done

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
if [[ -n "${MEUTE_QUOTA_CMD:-}" ]]; then
  if raw="$(eval "${MEUTE_QUOTA_CMD}" 2>/dev/null)"; then
    emit "${raw//[[:space:]]/}" "$(basename "${MEUTE_QUOTA_CMD%% *}")"
    exit $?
  fi
  printf 'quota.sh: MEUTE_QUOTA_CMD failed. Refusing to guess — the runner will\n' >&2
  printf 'quota.sh: decline this slot rather than run against an unknown quota.\n' >&2
  exit 1
fi

if [[ -f "$OVERRIDE_FILE" ]]; then
  emit "$(tr -d '[:space:]' < "$OVERRIDE_FILE")" "state/quota-override"
  exit $?
fi

emit "${MEUTE_QUOTA_STUB:-100}" "stub"
