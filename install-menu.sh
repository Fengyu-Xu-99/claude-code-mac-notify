#!/usr/bin/env bash
# claude-code-mac-notify — optional menu bar app installer (macOS).
#
# Adds a native menu bar app that shows every Claude Code session, its project,
# and status. It does NOT replace notify.sh (banners/sounds); it reads state that
# the hooks write. This installer:
#   1. compiles ClaudeWatchMenu.swift  -> ~/.claude/ClaudeWatchMenu
#   2. wires menubar.sh into the Stop/Notification/PreToolUse hooks (idempotent,
#      leaves notify.sh's hooks untouched)
#   3. installs a LaunchAgent so the app auto-starts at login and after crashes
set -euo pipefail

[ "$(uname)" = "Darwin" ] || { echo "This installer is macOS only."; exit 1; }

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
BIN="$CLAUDE_DIR/ClaudeWatchMenu"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/com.claude-code-mac-notify.menu.plist"
LABEL="com.claude-code-mac-notify.menu"

echo "==> Checking dependencies"
command -v jq >/dev/null 2>&1 || {
  command -v brew >/dev/null 2>&1 || { echo "Homebrew required for jq. See https://brew.sh"; exit 1; }
  echo "   installing jq"; brew install jq; }
command -v swiftc >/dev/null 2>&1 || xcrun --find swiftc >/dev/null 2>&1 || {
  echo "swiftc not found. Install Xcode Command Line Tools:  xcode-select --install"; exit 1; }

echo "==> Installing menubar.sh -> $HOOKS_DIR/menubar.sh"
mkdir -p "$HOOKS_DIR"
cp "$SRC_DIR/menubar.sh" "$HOOKS_DIR/menubar.sh"
chmod +x "$HOOKS_DIR/menubar.sh"

echo "==> Compiling ClaudeWatchMenu -> $BIN"
swiftc -O "$SRC_DIR/ClaudeWatchMenu.swift" -o "$BIN"

echo "==> Wiring menu hooks into $SETTINGS"
mkdir -p "$(dirname "$SETTINGS")"
python3 - "$SETTINGS" "$HOOKS_DIR/menubar.sh" <<'PY'
import json, os, sys
settings_path, menubar = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        raw = f.read().strip()
    if raw:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            sys.exit("ERROR: existing settings.json is not valid JSON. Aborting so nothing is lost.")

hooks = data.setdefault("hooks", {})

def install(event, arg, matcher=None):
    cmd = f'"{menubar}" {arg}'
    arr = hooks.setdefault(event, [])
    # idempotent: drop any prior menubar.sh group on this event WITH THE SAME
    # matcher, then re-add. Keying on (menubar.sh, matcher) not the exact arg
    # means changing the arg (e.g. working -> turn) REPLACES the stale entry
    # instead of leaving both. notify.sh groups are left untouched. One event can
    # still hold two menubar groups when their matchers differ (PreToolUse:
    # waiting vs working).
    def is_stale(g):
        if g.get("matcher") != matcher:
            return False
        return any(menubar in h.get("command", "") for h in g.get("hooks", []))
    arr[:] = [g for g in arr if not is_stale(g)]
    group = {"hooks": [{"type": "command", "command": cmd, "async": True}]}
    if matcher:
        group = {"matcher": matcher, **group}
    arr.append(group)

install("Stop", "done")                # finished -> sticky "needs review" (blue)
install("Notification", "notify")
install("PreToolUse", "waiting", "AskUserQuestion|ExitPlanMode")
install("PreToolUse", "working", "Edit|Write|MultiEdit|NotebookEdit|Bash")
# Permission dialog (e.g. "Allow this bash command?") -> yellow, even when the
# session is focused. This is the one signal the Notification event couldn't give.
install("PermissionRequest", "permission")
# Keep "working" fresh through a whole turn, not just tool moments:
#   UserPromptSubmit -> "turn": green on send, AND clears a stale review/waiting
#   MessageDisplay   -> green while Claude streams text, even with no tool call
# Without these a long thinking/writing pass ages to idle even though it's busy.
install("UserPromptSubmit", "turn")
install("MessageDisplay", "working")

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
print("   updated (Stop, Notification, PreToolUse:waiting/working, PermissionRequest, UserPromptSubmit, MessageDisplay)")
PY

echo "==> Installing LaunchAgent -> $PLIST"
mkdir -p "$AGENTS_DIR"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$CLAUDE_DIR/ClaudeWatchMenu.stdout.log</string>
  <key>StandardErrorPath</key><string>$CLAUDE_DIR/ClaudeWatchMenu.stderr.log</string>
</dict>
</plist>
PLISTEOF

# reload cleanly if it was already loaded
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

cat <<EOF

Done. Look for the ⌁ icon in your menu bar (it may take a few seconds to appear).
  ⌁            no active sessions
  ⌁ 🟢2 🟡1    two working, one waiting on you

Restart your Claude Code sessions so the new hooks load. Status updates as each
session fires an event (tool use, question, finish). A session with no event for
90s shows as idle; after 4h with no events it drops off the list.

Uninstall the menu app with  ./uninstall-menu.sh  (leaves notify.sh intact).
EOF
