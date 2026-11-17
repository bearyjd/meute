# `meute health`: is the fleet still running, and a way to be told when it is
# not (plan P1.8, R8). Sourced by bin/meute.
#
# A fleet stops silently in many ways: the timer is disarmed, linger is off,
# a 429 set a 24 h automatic hold, every fire skips on a probe that fails, a
# fire hangs holding the lock. `doctor` would say so, but only when asked.
# health prints one line per problem and exits 1; with --alert the same text
# goes on stdin to policy.alert_cmd, and the hourly meute-health.timer that
# install-timers writes runs exactly that. --failed (meute-alert.service, the
# OnFailure= of both run units) always alerts, with a fixed first line.
#
# Owner decision D4: alert_cmd is a generic command line (default empty) and
# the transport is the owner's; the text never names a repository, so it may
# go to a phone or a chat without leaking which projects the fleet works on.
#
# Never takes the run lock: a probe of state/.lock would make a concurrent
# fire skip. A held lock is read from state/lock-info and the holder's PID.
#
# Expects from the caller: MEUTE_ROOT, MANIFEST, MANIFEST_PY, STATE_DIR,
# LOG_FILE, note, die, plus lib/fleet.sh (fleet_load_policy, hold_active,
# now_epoch, hold_until_human), lib/timers.sh (timer_state, linger_state),
# lib/unitlimits.sh (unit_timeout_start_sec), lib/hostcheck.sh
# (hostcheck_free_mb) and lib/sweep.sh (sweep_stale, _sweep_live).

HEALTH_OK_MAX_SECONDS=$(( 3 * 86400 ))   # no status=ok for this long is a problem
HEALTH_MAX_ERRORS=3                      # this many status=error lines in a row
HEALTH_QUOTA_MAX_SECONDS=86400           # the status-line snapshot older than this
HEALTH_ALERT_TIMEOUT=60                  # seconds alert_cmd may take

# The longest gap between two daily-slot firings (weekend gaps included), from
# systemd itself; one day when systemd-analyze cannot say. It runs with TZ=UTC
# so the elapse lines are UTC and no "(in UTC)" lines exist, on any host: a
# host already in UTC prints only those, so parsing "(in UTC)" found nothing.
health_cadence_seconds() {
  local cal="$1" t prev="" gap max=0
  while IFS= read -r t; do
    t="$(date -d "$t" +%s 2>/dev/null)" || continue
    [[ -z "$prev" ]] || { gap=$(( t - prev )); (( gap <= max )) || max="$gap"; }
    prev="$t"
  done < <(TZ=UTC systemd-analyze calendar --iterations=8 "$cal" 2>/dev/null \
             | sed -En 's/^ *(Next elapse|Iteration #[0-9]+): //p')
  (( max > 0 )) || max=86400
  printf '%s\n' "$max"
}

# ISO time of the first field of a state/log line, as an epoch; empty if not one.
_health_epoch() { [[ -n "$1" ]] && date -d "$1" +%s 2>/dev/null || true; }

health_check_log() {
  local now cadence last first last_ok errors t
  now="$(now_epoch)"
  if [[ ! -s "$LOG_FILE" ]]; then
    printf 'no run has been logged yet (state/log is empty): the timer may never have fired\n'
    return 0
  fi
  cadence="$(health_cadence_seconds "${POLICY_DAILY_CALENDAR:-*-*-* 03:17:00}")"
  last="$(_health_epoch "$(tail -n 1 "$LOG_FILE" | cut -f1)")"
  if [[ -n "$last" ]] && (( now - last > 2 * cadence )); then
    printf 'no run logged for %sh (twice the daily cadence is %sh): the fleet has stopped firing\n' \
      $(( (now - last) / 3600 )) $(( 2 * cadence / 3600 ))
  fi
  t="$(awk -F'\t' 'index($0, "\tstatus=ok\t") { t = $1 } END { print t }' "$LOG_FILE")"
  last_ok="$(_health_epoch "$t")"
  first="$(_health_epoch "$(head -n 1 "$LOG_FILE" | cut -f1)")"
  if [[ -n "$last_ok" ]]; then
    (( now - last_ok <= HEALTH_OK_MAX_SECONDS )) \
      || printf 'no successful run for %sd: every fire since has skipped or failed (see: meute status)\n' $(( (now - last_ok) / 86400 ))
  elif [[ -n "$first" ]] && (( now - first > HEALTH_OK_MAX_SECONDS )); then
    printf 'no successful run logged in %sd: every fire has skipped or failed (see: meute status)\n' $(( (now - first) / 86400 ))
  fi
  errors="$(awk 'index($0, "\tstatus=error") { n++; next } { n = 0 } END { print n + 0 }' "$LOG_FILE")"
  (( errors < HEALTH_MAX_ERRORS )) \
    || printf '%s consecutive runs ended in error (see: tail state/log)\n' "$errors"
}

health_check_hold() {
  hold_active || return 0
  [[ "$HOLD_REASON" == auto:* ]] || return 0   # a pause the owner set is not news
  printf 'the fleet is paused until %s by an automatic hold (a provider rate limit); lift it with: meute resume\n' \
    "$(hold_until_human "$HOLD_UNTIL")"
}

health_check_lock() {
  local info="${STATE_DIR}/lock-info" pid started age limit
  [[ -f "$info" ]] || return 0
  pid="$(sed -n 's/^pid=\([0-9]*\) .*/\1/p' "$info" | head -n 1)"
  started="$(sed -n 's/.* started=\([^ ]*\) .*/\1/p' "$info" | head -n 1)"
  [[ -n "$pid" && -n "$started" ]] || return 0
  _sweep_live "$pid" || return 0   # lock-info outlives its run; only a live holder counts
  started="$(_health_epoch "$started")"
  [[ -n "$started" ]] || return 0
  age=$(( $(now_epoch) - started ))
  limit="$(unit_timeout_start_sec)"
  (( age > limit )) || return 0
  printf 'the run lock held for %sm by a live run, longer than the %sm any item may take: a fire may be hung\n' \
    $(( age / 60 )) $(( limit / 60 ))
}

health_check_timers() {
  local name state detail
  for name in daily weekly health; do
    IFS=$'\t' read -r state detail <<< "$(timer_state "meute-${name}.timer")"
    case "$state" in
      idle|absent) printf 'meute-%s.timer is not armed (%s): it will not fire; run: meute install-timers\n' "$name" "$state" ;;
    esac
  done
  [[ "$(linger_state)" != no ]] \
    || printf 'lingering is off: timers fire only while you are logged in; run: loginctl enable-linger %s\n' "$USER"
}

health_check_disk() {
  local min free
  min="$(python3 "$MANIFEST_PY" policy "$MANIFEST" 2>/dev/null | jq -r '.min_free_mb // empty' 2>/dev/null)" || min=""
  [[ "$min" =~ ^[0-9]+$ ]] && (( min > 0 )) || return 0
  free="$(hostcheck_free_mb "$STATE_DIR")"
  [[ -n "$free" ]] && (( free < min )) || return 0
  printf 'state/ has %s MB free, under policy.min_free_mb %s: every fire skips with code=disk\n' "$free" "$min"
}

health_check_leftovers() {
  local n
  n="$(sweep_stale --dry-run 2>/dev/null | grep -c . || true)"
  (( n == 0 )) || printf '%s leftover(s) of killed runs (meute doctor lists them; the next fire removes them)\n' "$n"
}

health_check_quota() {
  local snap="${STATE_DIR}/rate-limits.json" at age
  [[ -f "$snap" ]] || return 0
  at="$(jq -r '.captured_at // 0 | floor' "$snap" 2>/dev/null)" || at=0
  [[ "$at" =~ ^[0-9]+$ ]] || at=0
  age=$(( $(now_epoch) - at ))
  (( age > HEALTH_QUOTA_MAX_SECONDS )) || return 0
  printf 'the quota snapshot is %sh old: the subscription gate reads stale numbers (is the status line capture still installed?)\n' \
    $(( age / 3600 ))
}

health_check_override() {
  (( ${POLICY_OVERRIDE_ACTIVE:-0} )) || return 0
  printf 'a policy override is in force, not the manifest policy (meute policy show; meute policy clear)\n'
}

# Every problem, one line each; nothing when the fleet is healthy.
health_problems() {
  fleet_load_policy >/dev/null 2>&1 || true
  health_check_log
  health_check_hold
  health_check_lock
  health_check_timers
  health_check_disk
  health_check_leftovers
  health_check_quota
  health_check_override
}

# policy.alert_cmd, read from the raw manifest rather than through
# merged_policy, so a manifest broken elsewhere still gets its alert out.
health_alert_cmd() {
  python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
    v = (d.get("policy") or {}).get("alert_cmd") or ""
except Exception:
    v = ""
print(v if isinstance(v, str) else "")' "$MANIFEST" 2>/dev/null || true
}

# health_alert <text>: the text on alert_cmd's stdin, bounded in time.
health_alert() {
  local cmd rc=0
  cmd="$(health_alert_cmd)"
  if [[ -z "$cmd" ]]; then
    note "health: policy.alert_cmd is not set; nothing was sent"
    return 0
  fi
  printf '%s\n' "$1" | timeout "$HEALTH_ALERT_TIMEOUT" bash -c "$cmd" >/dev/null 2>&1 || rc=$?
  (( rc == 0 )) || note "health: policy.alert_cmd failed (exit ${rc})"
}

cmd_health() {
  local alert=0 failed=0 text
  while (( $# )); do
    case "$1" in
      --alert) alert=1 ;;
      --failed) failed=1 ;;
      *) die "health: unknown argument $1 (try: meute health [--alert])" ;;
    esac
    shift
  done
  text="$(health_problems)"
  (( ! failed )) \
    || text="a scheduled meute run failed; see: journalctl --user -u meute-daily -u meute-weekly${text:+$'\n'${text}}"
  [[ -n "$text" ]] || return 0
  printf '%s\n' "$text"
  (( ! alert )) || health_alert "$text"
  return 1
}
