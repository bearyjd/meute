# Privacy checks for `meute doctor` (meute-resilience-plan.md P2.4, R21).
# Sourced by bin/meute after lib/doctor.sh, whose d_ok/d_warn it uses.
#
# On a shared host state/ and reports/ name private repositories and carry
# unfixed findings, so anything but owner-only is worth a warning. The
# runner, bin/meute and the web server all set umask 077, but that only
# governs files created from now on; directories made before keep their mode.
#
# A remote URL with a credential in it is quoted verbatim by git's own
# errors, which reach engine stderr and from there a report. The check names
# the repository only: printing the URL would print the secret.

doctor_privacy() {
  local dir mode name path urls
  for dir in state reports; do
    [[ -d "${MEUTE_ROOT}/${dir}" ]] || continue
    mode="$(stat -c %a "${MEUTE_ROOT}/${dir}" 2>/dev/null)" || continue
    if (( (8#$mode & 8#055) != 0 )); then
      d_warn "${dir}/ is readable by group or others (mode ${mode}) - run: chmod -R go-rwx ${dir}"
    else
      d_ok "${dir}/ is owner-only"
    fi
  done

  # Fail closed: a check that could not look must not say "clean".
  local list rc flagged=0
  # Two steps, each checked: a pipeline's status depends on the caller's
  # pipefail, and doctor must not depend on that.
  if ! list="$(python3 "$MANIFEST_PY" list-repos "$MANIFEST")" \
     || ! list="$(printf '%s\n' "$list" | jq -r '[.name, .path] | @tsv')"; then
    d_warn "could not list enrolled repositories; remote credentials not checked"
    return 0
  fi
  while IFS=$'\t' read -r name path; do
    [[ -n "$path" && -d "$path" ]] || continue
    # Exit 1 is "no remote URLs"; anything else (a broken config, unsafe
    # ownership) means the remotes went unread.
    rc=0
    urls="$(git -C "$path" config --get-regexp '^remote\..*\.(url|pushurl)$' 2>/dev/null)" || rc=$?
    if (( rc > 1 )); then
      d_warn "${name}: could not read git config; remote credentials not checked"
      flagged=$(( flagged + 1 ))
      continue
    fi
    # The same filter that keeps credentials out of reports decides what a
    # credential is, so the two can never disagree.
    if [[ "$(printf '%s' "$urls" | python3 "${MEUTE_ROOT}/lib/redact.py")" != "$urls" ]]; then
      d_warn "${name}: a remote URL has credentials embedded - move them to a git credential helper"
      flagged=$(( flagged + 1 ))
    fi
  done <<< "$list"
  (( flagged > 0 )) || d_ok "no enrolled repository has a credential in a remote URL"
}
