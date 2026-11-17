#!/usr/bin/env bash
#
# Tab-separated key/value store. Sourced by bin/run.sh and bin/meute.
#
# Deliberately not a database: one file, one line per key, read with awk and
# written atomically via mktemp+mv so a run interrupted mid-write cannot leave a
# half-file behind. Values may not contain tabs or newlines.
#
# Every write is a read-modify-write, so writers are serialised by flock on
# <file>.lock: the lock file is separate because mv replaces the store's inode.
# Without it, two triage decisions landing together (parallel CLI calls, the
# threaded web server) kept only the last one to rename (R18).
_kv_locked() {
  local file="$1" fd rc; shift
  exec {fd}>>"${file}.lock" || return 1
  flock -x "$fd" || { exec {fd}>&-; return 1; }
  "$@"; rc=$?
  exec {fd}>&-
  return "$rc"
}

kv_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -F'\t' -v key="$key" '$1 == key { print $2; exit }' "$file"
}

# Replaces any existing row for the key.
kv_set() {
  mkdir -p "$(dirname "$1")"
  _kv_locked "$1" _kv_set "$@"
}
_kv_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "$(dirname "$file")/.kv.XXXXXX")"
  if [[ -f "$file" ]]; then
    awk -F'\t' -v key="$key" '$1 != key' "$file" > "$tmp"
  fi
  printf '%s\t%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
}

kv_del() {
  [[ -f "$1" ]] || return 0
  _kv_locked "$1" _kv_del "$@"
}
_kv_del() {
  local file="$1" key="$2" tmp
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "$(dirname "$file")/.kv.XXXXXX")"
  awk -F'\t' -v key="$key" '$1 != key' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Whole rows, for callers that keep more than one value per key.
kv_row() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -F'\t' -v key="$key" '$1 == key { print; exit }' "$file"
}

kv_set_row() {
  mkdir -p "$(dirname "$1")"
  _kv_locked "$1" _kv_set_row "$@"
}
_kv_set_row() {
  local file="$1" key="$2"; shift 2
  local tmp row
  tmp="$(mktemp "$(dirname "$file")/.kv.XXXXXX")"
  if [[ -f "$file" ]]; then
    awk -F'\t' -v key="$key" '$1 != key' "$file" > "$tmp"
  fi
  row="$key"
  local field
  for field in "$@"; do row+="$(printf '\t%s' "$field")"; done
  printf '%s\n' "$row" >> "$tmp"
  mv "$tmp" "$file"
}
