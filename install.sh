#!/usr/bin/env bash
# claude-code-mac-notify installer (macOS).
# Installs terminal-notifier, drops notify.sh into ~/.claude/hooks/, and wires
# the Stop + Notification hooks into ~/.claude/settings.json without clobbering
# anything else.
set -euo pipefail

[ "$(uname)" = "Darwin" ] || { echo "This installer is macOS only."; exit 1; }

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

echo "==> Checking dependencies"
need_brew() {
  command -v brew >/dev/null 2>&1 || {
    echo "Homebrew is required. Install it from https://brew.sh then re-run."; exit 1; }
}
command -v terminal-notifier >/dev/null 2>&1 || { need_brew; echo "   installing terminal-notifier"; brew install terminal-notifier; }
command -v jq             >/dev/null 2>&1 || { need_brew; echo "   installing jq";             brew install jq; }

echo "==> Installing notify.sh -> $HOOKS_DIR/notify.sh"
mkdir -p "$HOOKS_DIR"
cp "$SRC_DIR/notify.sh" "$HOOKS_DIR/notify.sh"
chmod +x "$HOOKS_DIR/notify.sh"

echo "==> Wiring hooks into $SETTINGS"
mkdir -p "$(dirname "$SETTINGS")"
python3 - "$SETTINGS" "$HOOKS_DIR/notify.sh" <<'PY'
import json, os, sys
settings_path, notify = sys.argv[1], sys.argv[2]
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

def install(event, arg):
    cmd = f'"{notify}" {arg}'
    arr = hooks.setdefault(event, [])
    # idempotent: drop any prior group that already calls our notify.sh
    arr[:] = [g for g in arr
              if not any(notify in h.get("command", "") for h in g.get("hooks", []))]
    arr.append({"hooks": [{"type": "command", "command": cmd, "async": True}]})

install("Stop", "stop")
install("Notification", "notification")

# Silence Claude Code's built-in generic notifier so it doesn't double up.
data["preferredNotifChannel"] = "notifications_disabled"

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
print("   updated (Stop, Notification, preferredNotifChannel)")
PY

echo "==> Firing a test banner"
"$HOOKS_DIR/notify.sh" stop || true

cat <<'EOF'

Almost done. Two things macOS will NOT let a script change, do these once by hand:

  System Settings -> Notifications -> terminal-notifier
    1. Allow notifications: ON
    2. Alert style: Banners (auto-hide) or Alerts (stay until dismissed)
    3. Summarize notifications: OFF   (otherwise it goes to the sidebar)

  Also make sure a Focus / Do Not Disturb mode isn't filtering it. (notify.sh
  passes -ignoreDnD, which handles most cases, but a strict Focus can still block.)

Then fully quit and reopen Claude Code so it reloads the new config.

You're set: you'll get an on-screen banner + sound when Claude finishes, needs
permission, or is waiting on your input. Edit ~/.claude/hooks/notify.sh to change
the wording or sounds. Run ./uninstall.sh to remove it.
EOF
