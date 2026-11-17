# Host-health gate, sourced by bin/run.sh.
#
# A fire on a host at load 90, or on a full disk, starts a 30-minute agent that
# cannot finish and may take the machine down with it. hostcheck_gate runs
# after the hold check and before the lock, so declining costs one small python
# call: skip code=load when the 1-minute load per CPU is over
# policy.max_load_per_cpu (default 2.0), skip code=disk when the state
# filesystem or the run's temp directory has less than policy.min_free_mb
# (default 512) free or cannot be written. 0 disables the respective check.
#
# Owner decision D6: on by default; a forced run obeys the load check unless
# --ignore-load (HOST_IGNORE_LOAD=1), and always obeys the disk check.
#
# A manifest that cannot be read here is not this gate's business: it passes,
# and the manifest validation that follows says what is wrong.
#
# Test seams: MEUTE_LOADAVG (default /proc/loadavg), MEUTE_NCPU (default
# nproc), MEUTE_DF (default df).
#
# Expects from the caller: STATE_DIR, RUN_TMP, MANIFEST, MANIFEST_PY, skip().

HOST_IGNORE_LOAD=0

# hostcheck_writable <dir>: can a file be created, and removed, there?
hostcheck_writable() {
  local probe
  probe="$(mktemp "$1/.hostcheck.XXXXXX" 2>/dev/null)" || return 1
  rm -f "$probe"
}

# hostcheck_free_mb <dir>: whole MB available to us there; empty if unknown.
# Always succeeds: a df that fails (odd mount, container permissions) is
# "unknown", never an errexit that kills the fire under run.sh's set -e.
hostcheck_free_mb() {
  local out
  out="$("${MEUTE_DF:-df}" -Pm "$1" 2>/dev/null)" || return 0
  awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }' <<< "$out"
}

hostcheck_gate() {
  local limits max_load min_free
  limits="$(python3 "$MANIFEST_PY" policy "$MANIFEST" 2>/dev/null \
    | jq -r '[.max_load_per_cpu, .min_free_mb] | @tsv' 2>/dev/null)" || return 0
  IFS=$'\t' read -r max_load min_free <<< "$limits"
  [[ -n "$max_load" && -n "$min_free" ]] || return 0

  if (( ! HOST_IGNORE_LOAD )); then
    local load ncpu
    # The braces silence the redirection's own error: an unreadable loadavg
    # is "unknown", not a line of noise on every fire.
    { read -r load _ < "${MEUTE_LOADAVG:-/proc/loadavg}"; } 2>/dev/null || load=""
    ncpu="${MEUTE_NCPU:-$(nproc 2>/dev/null || echo 1)}"
    if [[ "$load" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
       && awk -v l="$load" -v c="$ncpu" -v m="$max_load" 'BEGIN { exit !(m > 0 && c > 0 && l / c > m) }'; then
      skip load "host load ${load} on ${ncpu} CPUs is over ${max_load} per CPU" "load=${load}"
    fi
  fi

  (( min_free > 0 )) || return 0
  local dir free
  for dir in "$STATE_DIR" "$RUN_TMP"; do
    [[ -n "$dir" ]] || continue
    hostcheck_writable "$dir" || skip disk "cannot write to ${dir}"
    free="$(hostcheck_free_mb "$dir")"
    [[ -z "$free" ]] || (( free >= min_free )) || skip disk "${dir} has ${free} MB free, under ${min_free}"
  done
}
