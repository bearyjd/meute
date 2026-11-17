#!/usr/bin/env bash
#
# `meute findings verify` and `meute claim` (P1.7 (b), R5). Sourced by bin/meute,
# which supplies MANIFEST, MEUTE_ROOT, INBOX_PY, REPORT_PY, note, die,
# require_report and finding_state. Both write state/finding-status only;
# state/reports stays the authoritative record of decisions.

# A verdict per undecided finding: its file between the report's base SHA and
# the repository's current HEAD of that ref. Reads the repositories only.
cmd_findings_verify() {
  local repo="" repos
  while (( $# )); do
    case "$1" in
      --repo) repo="${2:?--repo needs a repo name}"; shift ;;
      *) die "findings verify: unknown argument $1" ;;
    esac
    shift
  done
  repos="$(python3 "${MEUTE_ROOT}/lib/manifest.py" list-repos "$MANIFEST")" \
    || die "findings verify: could not read repository paths from ${MANIFEST}"
  local counts
  counts="$(python3 "$INBOX_PY" verify ${repo:+--repo "$repo"} <<< "$repos")" \
    || die "findings verify: lib/inbox.py exited with an error (see above)"
  note "verified${repo:+ ${repo}}: ${counts}"
}

# A PR's URL as the kv store can hold it: one token, http(s), no whitespace or
# other control characters (an ESC would reach the terminal).
valid_pr_url() { [[ "$1" =~ ^https?://[^[:space:][:cntrl:]]+$ ]]; }

# "Covered by an open PR": hides the finding from `findings --new` until the
# PR lands (then `meute resolve --pr`) or the claim file is deleted.
cmd_claim() {
  local id="${1:-}"; shift || true
  local number="" pr=""
  while (( $# )); do
    case "$1" in
      -f|--finding) number="${2:?-f needs a finding number}"; shift ;;
      --pr) pr="${2:?--pr needs a URL}"; shift ;;
      *) die "claim: unknown argument $1" ;;
    esac
    shift
  done
  require_report "$id"
  [[ "$number" =~ ^[0-9]+$ ]] || die "claim: -f <n> is required (see: meute show ${id})"
  [[ -n "$pr" ]] || die "claim: --pr <url> is required"
  valid_pr_url "$pr" || die "claim: --pr must be an http(s) URL with no spaces"
  local total state
  total="$(python3 "$REPORT_PY" findings "$(report_path "$id")" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  (( number >= 1 && number <= total )) || die "claim: no finding ${number} in ${id}"
  state="$(finding_state "$id" "$number")"
  [[ "$state" == "new" ]] || die "claim: finding ${number} of ${id} is already ${state}"
  python3 "${MEUTE_ROOT}/lib/finding_status.py" claim "$(finding_key "$id" "$number")" "$pr" \
    || die "claim: could not write state/finding-status"
  note "claimed finding ${number} of ${id} (${pr})"
}
