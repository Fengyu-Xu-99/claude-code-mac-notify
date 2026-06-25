#!/usr/bin/env bash
# Remove the claude-code-mac-notify hooks from ~/.claude/settings.json and delete
# the notify.sh script. Leaves terminal-notifier/jq installed (remove with brew if
# you want). Does not touch preferredNotifChannel unless you pass --restore-builtin.
set -euo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
RESTORE="no"; [ "${1:-}" = "--restore-builtin" ] && RESTORE="yes"

if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" "$HOOKS_DIR/notify.sh" "$RESTORE" <<'PY'
import json, os, sys
settings_path, notify, restore = sys.argv[1], sys.argv[2], sys.argv[3]
with open(settings_path) as f:
    data = json.load(f)
for event in ("Stop", "Notification", "PreToolUse"):
    arr = data.get("hooks", {}).get(event)
    if not arr:
        continue
    arr[:] = [g for g in arr
              if not any(notify in h.get("command", "") for h in g.get("hooks", []))]
    if not arr:
        data["hooks"].pop(event, None)
if restore == "yes":
    data.pop("preferredNotifChannel", None)
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
print("Cleaned hooks from", settings_path)
PY
fi

rm -f "$HOOKS_DIR/notify.sh" && echo "Removed $HOOKS_DIR/notify.sh"
echo "Done. Quit and reopen Claude Code to reload."
