# Resource limits and the start timeout for the generated systemd service,
# plus the doctor check that an installed unit has them. Sourced by bin/meute.
#
# A fire that hangs must neither starve the desktop nor outlive its own
# budget: with no TimeoutStartSec a oneshot unit never ends, so systemd never
# starts the next fire (R9).
#
# Expects from the caller: MANIFEST_PY, MANIFEST, d_warn (doctor.sh).

UNIT_TIMEOUT_SLACK=600     # seconds on top of the longest item timeout
UNIT_TIMEOUT_DEFAULT=1800  # manifest default, used when the queue cannot be read

# The longest timeout_seconds any queued item can carry, plus the slack.
unit_timeout_start_sec() {
  local longest
  longest="$({ python3 "$MANIFEST_PY" queue "$MANIFEST" daily
               python3 "$MANIFEST_PY" queue "$MANIFEST" weekly; } 2>/dev/null \
             | jq -rs 'map(.timeout_seconds) | max // empty' 2>/dev/null)" || longest=""
  [[ "$longest" =~ ^[0-9]+$ ]] || longest="$UNIT_TIMEOUT_DEFAULT"
  printf '%s\n' $(( longest + UNIT_TIMEOUT_SLACK ))
}

# The [Service] lines, one per line, as written into the unit.
unit_limit_lines() {
  printf 'Nice=10\nIOSchedulingClass=idle\nCPUWeight=20\nTimeoutStartSec=%s\n' "$(unit_timeout_start_sec)"
}

# doctor_unit_limits <unit-dir>: warn once per installed service that lacks
# any of the four directives.
doctor_unit_limits() {
  local unit_dir="$1" slot file
  for slot in daily weekly; do
    file="${unit_dir}/meute-${slot}.service"
    [[ -f "$file" ]] || continue
    if ! grep -qx 'Nice=10' "$file" || ! grep -qx 'IOSchedulingClass=idle' "$file" \
       || ! grep -qx 'CPUWeight=20' "$file" || ! grep -q '^TimeoutStartSec=[0-9]' "$file"; then
      d_warn "meute-${slot}.service has no resource limits or start timeout - re-run install-timers"
    fi
  done
}
