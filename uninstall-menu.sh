#!/usr/bin/env bash
# Remove the claude-code-mac-notify menu bar app: unload the LaunchAgent, remove
# the binary, state dir, menubar.sh, and its hook entries. Leaves notify.sh and
# its banners/sounds completely intact.
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
BIN="$CLAUDE_DIR/ClaudeWatchMenu"
PLIST="$HOME/Library/LaunchAgents/com.claude-code-mac-notify.menu.plist"

if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST" && echo "Removed LaunchAgent"
fi

if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" "$HOOKS_DIR/menubar.sh" <<'PY'
import json, sys
settings_path, menubar = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    data = json.load(f)
for event in ("Stop", "Notification", "PreToolUse", "PermissionRequest", "UserPromptSubmit", "MessageDisplay"):
    arr = data.get("hooks", {}).get(event)
    if not arr:
        continue
    arr[:] = [g for g in arr
              if not any(menubar in h.get("command", "") for h in g.get("hooks", []))]
    if not arr:
        data["hooks"].pop(event, None)
with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
print("Cleaned menu hooks from", settings_path)
PY
fi

rm -f "$BIN" && echo "Removed $BIN"
rm -f "$HOOKS_DIR/menubar.sh" && echo "Removed $HOOKS_DIR/menubar.sh"
rm -rf "$CLAUDE_DIR/menubar" && echo "Removed state dir $CLAUDE_DIR/menubar"
rm -f "$CLAUDE_DIR/ClaudeWatchMenu.stdout.log" "$CLAUDE_DIR/ClaudeWatchMenu.stderr.log"
echo "Done. notify.sh left intact."
