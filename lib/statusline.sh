#!/usr/bin/env bash
#
# Claude Code status line: `meute install-statusline`. Sourced by bin/meute.
#
# Wraps the user's status line in contrib/statusline-capture.sh so the real
# 5h/7d subscription windows reach bin/quota.sh; until then the quota gate
# answers from the stub and `doctor` says so.
#
# Expects from the caller: MEUTE_ROOT, note, die.

# Put contrib/statusline-capture.sh in front of Claude Code's status line so
# the subscription's 5h/7d windows get snapshotted every time the human works.
# This is what makes the quota gate measure the thing PRP-001 §3 step 4 is
# about; until it runs, bin/quota.sh answers from the stub.
#
# Edits settings.json outside this repo -- the same kind of reach as
# install-timers writing ~/.config/systemd -- so it backs the file up first,
# keeps the original command verbatim as the wrapper's argument, and is
# idempotent because it can see it is already wrapped.
cmd_install_statusline() {
  local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  local capture="${MEUTE_ROOT}/contrib/statusline-capture.sh"
  [[ -x "$capture" ]] || die "install-statusline: ${capture} is missing or not executable"
  command -v jq >/dev/null || die "install-statusline: jq is required"

  local result
  result="$(python3 - "$settings" "$capture" 2>&1 <<'PY'
import json, os, shlex, sys
settings_path, capture = sys.argv[1], sys.argv[2]
try:
    with open(settings_path, encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    sys.exit(f"refusing to edit {settings_path}: not valid JSON ({e})")
if not isinstance(data, dict):
    sys.exit(f"refusing to edit {settings_path}: top level is not an object")

current = data.get("statusLine")
original = ""
if isinstance(current, dict):
    if current.get("type", "command") != "command":
        sys.exit(f"statusLine.type is {current.get('type')!r}, not 'command' - not wrapping it")
    original = current.get("command", "") or ""

if original.startswith(capture + " "):
    print("already")
    sys.exit(0)

wrapped = capture + " --" + (" " + shlex.quote(original) if original else "")
if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as fh:
        backup_body = fh.read()
    with open(settings_path + ".meute-bak", "w", encoding="utf-8") as fh:
        fh.write(backup_body)
data["statusLine"] = {**(current if isinstance(current, dict) else {}), "type": "command", "command": wrapped}
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
tmp = settings_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, settings_path)
print("wrapped" if original else "installed")
PY
)" || die "install-statusline: ${result}"

  case "$result" in
    already)   note "status line already captures rate limits (${settings})" ;;
    wrapped)   note "wrapped the existing status line in ${settings}"
               note "backup: ${settings}.meute-bak" ;;
    installed) note "installed a capture-only status line in ${settings} (there was none before)" ;;
  esac
  note "the next interactive Claude Code turn writes state/rate-limits.json;"
  note "after that, bin/quota.sh reads the real subscription windows. check with: meute doctor"
}
