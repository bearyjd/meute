# A fire's own temp directory, sourced by bin/run.sh and bin/meute.
#
# Every temp file a fire makes lives in one directory, created under
# ${MEUTE_TMPDIR:-<state>/tmp} and exported as TMPDIR, so a bare `mktemp` (in
# the runner, lib/fleet.sh, or the engine itself) lands in it. Removing that
# one directory on exit is the whole cleanup: no per-file trap to forget, and
# a full or unwritable /tmp (a tmpfs on most hosts) no longer ends a fire.
# MEUTE_TMPDIR=/tmp restores the old location without a revert.
#
# The caller supplies die(). The directory is mode 700 (mktemp -d).

RUN_TMP=""

# tmp_init <state-dir>: create the run's directory and point TMPDIR at it.
tmp_init() {
  local parent="${MEUTE_TMPDIR:-$1/tmp}"
  mkdir -p "$parent" && RUN_TMP="$(mktemp -d "${parent}/run.XXXXXX")" \
    || die "cannot create a temp directory under ${parent}"
  export TMPDIR="$RUN_TMP"
}

# tmp_cleanup: remove the run's directory, never its parent. Safe to call
# twice, and before tmp_init.
tmp_cleanup() {
  [[ -z "${RUN_TMP:-}" ]] || rm -rf "$RUN_TMP"
  RUN_TMP=""
}
