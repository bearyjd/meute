# The state/cursor key a fire rotates on, sourced by lib/select.sh (run.sh) and
# lib/drain.sh (meute drain) so both name the same one.
#
# cursor_name <slot> <plan|manifest> [only]
#
# A staged plan rotates on plan-cursor.<slot>, the manifest on cursor.<slot>.
# A fire narrowed by MEUTE_ONLY_REPOS (`meute drain --repo`) gets a key of its
# own, suffixed by a hash of the sorted names: the timers' fleet-wide cursor is
# never moved by a drain the operator narrowed to a few repos.
cursor_name() {
  local prefix=cursor suffix=""
  [[ "$2" != plan ]] || prefix=plan-cursor
  [[ -z "${3:-}" ]] || suffix=".only.$(printf '%s\n' "$3" | sed '/^$/d' | sort -u | sha1sum | cut -c1-8)"
  printf '%s.%s%s\n' "$prefix" "$1" "$suffix"
}
