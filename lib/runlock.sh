# The run lock, sourced by bin/run.sh.
#
# The lock is fd 9 of the runner. bash has no close-on-exec, so every child
# inherits fd 9 unless its command line closes it; the engine, its probes,
# quota.sh and podman are therefore started with `9>&-`, and every git call
# goes through the git() below. One that leaves a process behind would
# otherwise keep the lock after run.sh exits, and every later fire skips with
# "another run holds the lock".

# runlock_acquire <lock-file> <info-file> <slot> <key>
# Opens fd 9 in the CALLING shell (never call this in $(...) or a pipeline),
# takes the lock without waiting, and only then records who holds it, so a
# losing runner never overwrites the winner's diagnosis. Returns 1 only when
# another run holds the lock: a lock file that cannot be opened dies, and
# lock-info is diagnosis, so failing to write it only warns.
runlock_acquire() {
  local lock_file="$1" info_file="$2" slot="$3" key="$4"
  exec 9>"$lock_file" || die "cannot open the run lock ${lock_file}"
  flock -n 9 || return 1
  { printf 'pid=%s started=%s slot=%s key=%s\n' \
      "$$" "$(date --iso-8601=seconds)" "${slot:--}" "${key:--}" > "$info_file"; } 2>/dev/null \
    || note "could not write ${info_file}; the run goes on"
}

# git runs the target repo's own code: hooks (pre-commit, post-checkout,
# reference-transaction) and clean/smudge filters, any of which may leave a
# daemon behind (eslint_d, prettierd, a gradle daemon). Every git call in
# run.sh and the libraries it sources closes the lock here, so a call site
# added later cannot forget to.
git() { command git "$@" 9>&-; }
