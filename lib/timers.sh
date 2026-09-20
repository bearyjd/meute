#!/usr/bin/env bash
#
# systemd user timers: `meute install-timers` and the probes `doctor` shares
# (timer_state, linger_state, unit_path_line). Sourced by bin/meute.
#
# The timer helpers are tested by sourcing bin/meute, so sourcing it must
# keep exposing them; that is why this file is sourced unconditionally.
#
# Expects from the caller: MEUTE_ROOT, MANIFEST, note, die, plus
# lib/fleet.sh (fleet_load_policy for the slot calendars).

# --------------------------------------------------------------------------
# Whether a timer will actually fire. A unit can be `enabled` and inert at the
# same moment: `enable` writes the timers.target.wants symlink, `--now` is what
# starts it, and an `enable --now` whose start half failed leaves exactly that
# state — as does enabling from a shell that cannot reach the user manager.
# `is-enabled` reads the symlink, so it answers "enabled" for a timer with no
# next firing, which is how a fleet reports itself deployable and then never
# runs. The only claim worth checking is the one the scheduler acts on: is
# there a next elapse, and when.
#
# Echoes "<state>\t<detail>":
#   armed  <when>   there is a next firing
#   idle   <state>  loaded, but nothing scheduled — will not run
#   absent          systemd has no such unit
#   nobus           systemd could not be asked
# --------------------------------------------------------------------------
timer_state() {
  local unit="$1" out
  out="$(systemctl --user show "$unit" \
           -p LoadState -p UnitFileState -p ActiveState -p NextElapseUSecRealtime \
           2>/dev/null)" || { printf 'nobus\t\n'; return 0; }
  local load file next
  load="$(sed -n 's/^LoadState=//p'             <<<"$out")"
  file="$(sed -n 's/^UnitFileState=//p'         <<<"$out")"
  next="$(sed -n 's/^NextElapseUSecRealtime=//p' <<<"$out")"
  if [[ "$load" == "not-found" || -z "$load" ]]; then printf 'absent\t\n'; return 0; fi
  # systemd 258 leaves this empty for an inert timer; other versions answer "0"
  # or "n/a". Reading any of them as a time is the false positive this exists
  # to prevent, so all three mean the same thing: nothing is scheduled.
  case "$next" in
    ""|0|n/a) ;;
    *) printf 'armed\t%s\n' "$next"; return 0 ;;
  esac
  printf 'idle\t%s\n' "${file:-unknown}"
}

# yes / no / unknown. `loginctl` needs the *system* bus, which a container does
# not have even when the user bus works; a failed query is not a "no", and
# reporting it as one sends you to a remedy that errors out.
linger_state() {
  local v
  v="$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  case "$v" in yes|no) printf '%s\n' "$v" ;; *) printf 'unknown\n' ;; esac
}

# Writes and enables systemd user timers. Chosen over cron where cron is absent,
# and better regardless: Persistent=true means a slot missed while the machine
# was off runs at next boot, which plain cron does not do.
#
# Derived from where these binaries actually resolve right now, not assumed
# from a fixed install layout -- a hardcoded ~/.local/bin:~/.npm-global/bin
# happens to be right on the machine this was written on and wrong on the
# next one, silently, since a unit missing its PATH still installs and arms.
unit_path_line() {
  local names=(git jq python3 claude codex)
  # The fixed five above are meute's own hard dependencies -- they have no way
  # to know a given repo's toolchain. Found live: veille-finance's lint-sweep
  # blocked under the timer because cargo (~/.cargo/bin, nowhere near any of
  # them) was missing from the unit's PATH, even though the manifest already
  # declares it needs `cargo` via each tier's allowed_tools (Bash(cargo
  # test:*), ...). Derive from that instead of guessing a second fixed list
  # that would just be wrong on a different repo.
  local word
  while IFS= read -r word; do
    [[ -n "$word" ]] || continue
    names+=( "$word" )
  # Every level the runner resolves an allowlist from, not just tiers.
  # lib/manifest.py's build_entry picks the FIRST non-empty allowed_tools of
  # (task, project, tier) -- a task-level list REPLACES the tier's rather than
  # extending it, so a task can need binaries no tier ever names. dep-audit is
  # exactly that: its allowed_tools are audit_commands, and osv-scanner,
  # pip-audit, grype and govulncheck appear nowhere else. Scanning tiers alone
  # left those invisible to the unit's PATH -- the same dead end as the cargo
  # bug this function was written for, just one level further in. `go install`
  # putting govulncheck in ~/go/bin is the concrete way it bites.
  done < <(python3 -c "
import re, sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
seen = set()

def scan(value):
    for m in re.finditer(r'Bash\(([^:)]+)', value or ''):
        w = m.group(1).split()[0]
        if not w.startswith('.') and not w.startswith('/'):
            seen.add(w)

for tier in (d.get('tiers') or {}).values():
    if isinstance(tier, dict):
        scan(tier.get('allowed_tools'))
for task in (d.get('tasks') or {}).values():
    if isinstance(task, dict):
        scan(task.get('allowed_tools'))
for key in ('repos', 'community'):
    for project in (d.get(key) or []):
        if isinstance(project, dict):
            scan(project.get('allowed_tools'))
print('\n'.join(sorted(seen)))
" "$MANIFEST" 2>/dev/null)

  local needed=() bin path
  for bin in "${names[@]}"; do
    path="$(command -v "$bin" 2>/dev/null)" || continue
    # `command -v` answers for shell builtins too, and answers with the bare
    # word rather than a path: `command -v command` prints "command", which
    # dirname turns into ".". Every name derived above used to be a real
    # binary, so this could not arise; the allowlist now carries
    # `Bash(command -v:*)`, whose first word is the builtin, so it can. A
    # relative entry in the unit's PATH resolves against the unit's working
    # directory -- a worktree of the repo being worked on, which on the
    # community track is a third party's code, where a planted ./git would
    # then win. Take only absolute answers.
    [[ "$path" == /* ]] || continue
    needed+=( "$(dirname "$path")" )
  done

  # Order the result the way $PATH itself already does, not by which binary
  # happened to be resolved first. Two cargos can both be real: a distro
  # package in /usr/bin and a rustup one in ~/.cargo/bin, at different
  # versions. Building dirs in name-iteration order put /usr/bin ahead of
  # ~/.cargo/bin regardless of the caller's own PATH, so the unit could
  # silently run a different cargo (and get different clippy lints) than the
  # one both the caller and this repo's own CI (dtolnay/rust-toolchain) use.
  # `"${ordered[*]}"` joins on the *current* IFS, not the ':' from the read
  # below (that assignment scopes only to the read command) -- a colon-based
  # substring dedup against that join silently never matches, which is how
  # this leaked duplicate after duplicate into the PATH the first time this
  # was written. An associative array can't have that ambiguity.
  local -A seen=()
  local ordered=() dir nd want
  IFS=':' read -ra path_dirs <<< "$PATH"
  for dir in "${path_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    want=0
    for nd in "${needed[@]:-}"; do [[ "$nd" == "$dir" ]] && { want=1; break; }; done
    (( want )) || continue
    [[ -n "${seen[$dir]:-}" ]] && continue
    seen[$dir]=1
    ordered+=( "$dir" )
  done
  local uniq; uniq="$(IFS=:; printf '%s' "${ordered[*]:-}")"
  printf '%s\n' "${uniq:+${uniq}:}/usr/bin:/bin"
}

cmd_install_timers() {
  command -v systemctl >/dev/null || die "systemd is not available on this machine"
  local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$unit_dir"
  local path_line; path_line="$(unit_path_line)"
  fleet_load_policy || die "install-timers: could not read policy from ${MANIFEST}"
  local slot
  for slot in daily weekly; do
    # Cadence comes from the manifest. "daily" is the slot's name, not a
    # promise about frequency: a fleet of thirty repos at one item a day
    # sees each repo monthly, so the operator sets how often the slot fires.
    local cal="$POLICY_DAILY_CALENDAR"
    [[ "$slot" == weekly ]] && cal="$POLICY_WEEKLY_CALENDAR"
    systemd-analyze calendar "$cal" >/dev/null 2>&1 \
      || die "install-timers: policy.${slot}_calendar ${cal@Q} is not a valid OnCalendar spec (try: systemd-analyze calendar ${cal@Q})"
    cat > "${unit_dir}/meute-${slot}.service" <<UNIT
[Unit]
Description=meute fleet runner (${slot} slot)
Documentation=https://github.com/bearyjd/meute

[Service]
Type=oneshot
WorkingDirectory=${MEUTE_ROOT}
Environment=PATH=${path_line}
ExecStart=${MEUTE_ROOT}/bin/run.sh ${slot}
# stdout and stderr go to the journal; the runner also appends to state/log.
UNIT
    cat > "${unit_dir}/meute-${slot}.timer" <<UNIT
[Unit]
Description=meute ${slot} slot
Documentation=https://github.com/bearyjd/meute

[Timer]
OnCalendar=${cal}
# Run a slot missed while the machine was off, rather than skipping the week.
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT
    note "wrote ${unit_dir}/meute-${slot}.{service,timer}"
  done
  systemctl --user daemon-reload || true
  systemctl --user enable --now meute-daily.timer meute-weekly.timer || true

  # Assert the arming rather than trusting the exit code. The previous version
  # sent this listing to /dev/null, so it printed "0 timers listed" and reported
  # success over two timers that had never been started.
  local slot state detail inert=()
  for slot in daily weekly; do
    IFS=$'\t' read -r state detail <<<"$(timer_state "meute-${slot}.timer")"
    case "$state" in
      armed) note "meute-${slot}.timer armed - next ${detail}" ;;
      *)     note "meute-${slot}.timer is NOT armed (${state}) - it will not fire"
             inert+=( "meute-${slot}.timer" ) ;;
    esac
  done

  case "$(linger_state)" in
    yes) : ;;
    no)  note "WARNING: lingering is off - run 'loginctl enable-linger $USER' or timers only fire while you are logged in" ;;
    *)   note "WARNING: cannot tell whether lingering is on - no system bus reachable from here (a container?)"
         note "         check on the host with:  loginctl show-user $USER --property=Linger" ;;
  esac

  (( ${#inert[@]} == 0 )) || \
    die "units written, but ${inert[*]} not armed. Start them where systemd can be reached:  systemctl --user start ${inert[*]}"
}
