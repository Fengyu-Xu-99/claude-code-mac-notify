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

# Optional: --tool-alerts also fires a (soft) alert before every Edit/Write/Bash.
# This is the only way to be alerted on permission prompts while you're looking at
# the session, but it's NOISY: it fires on routine tool use too, not just prompts.
TOOL_ALERTS="no"
[ "${1:-}" = "--tool-alerts" ] && TOOL_ALERTS="yes"

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
python3 - "$SETTINGS" "$HOOKS_DIR/notify.sh" "$TOOL_ALERTS" <<'PY'
import json, os, sys
settings_path, notify, tool_alerts = sys.argv[1], sys.argv[2], sys.argv[3]
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
    cmd = f'"{notify}" {arg}'
    arr = hooks.setdefault(event, [])
    # idempotent: drop any prior group that runs THIS exact notify.sh command, so
    # re-running is safe and multiple notify.sh hooks can coexist on one event
    # (e.g. PreToolUse carries both the 'question' and 'tool' hooks).
    arr[:] = [g for g in arr
              if not any(h.get("command", "") == cmd for h in g.get("hooks", []))]
    group = {"hooks": [{"type": "command", "command": cmd, "async": True}]}
    if matcher:
        group = {"matcher": matcher, **group}
    arr.append(group)

install("Stop", "stop")
install("Notification", "notification")
# Fire when Claude is about to ask a question or present a plan. This is the
# reliable "Claude needs your answer" alert; the Notification event above only
# surfaces when you're away from the session.
install("PreToolUse", "question", "AskUserQuestion|ExitPlanMode")

# Opt-in: alert before every Edit/Write/Bash (catches permission prompts while you
# watch, at the cost of firing on routine tool use too). Off unless --tool-alerts.
if tool_alerts == "yes":
    install("PreToolUse", "tool", "Edit|Write|MultiEdit|NotebookEdit|Bash")

# Silence Claude Code's built-in generic notifier so it doesn't double up.
data["preferredNotifChannel"] = "notifications_disabled"

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
extra = ", PreToolUse:tool" if tool_alerts == "yes" else ""
print(f"   updated (Stop, Notification, PreToolUse:question{extra}, preferredNotifChannel)")
PY

echo "==> Firing a test banner"
"$HOOKS_DIR/notify.sh" stop || true

cat <<'EOF'

Almost done. Two things macOS will NOT let a script change, do these once by hand:

  System Settings -> Notifications -> terminal-notifier
    1. Allow notifications: ON
    2. Alert style: Banners (auto-hide) or Alerts (stay until dismissed)

Then fully quit and reopen Claude Code so it reloads the new config.

If banners only show in the Notification Center sidebar instead of popping on
screen, the macOS notification daemon is in a stuck state. Reset it with:

  killall NotificationCenter usernoted

You're set: you'll get a sound + banner when Claude finishes, asks you a
question, needs permission, or is waiting on your input. Edit
~/.claude/hooks/notify.sh to change the wording or sounds. Run ./uninstall.sh
to remove it.

Want an alert on permission prompts even while you're watching the session?
Re-run with  ./install.sh --tool-alerts  to also fire a soft sound before every
Edit/Write/Bash. Heads up: it fires on routine tool use too, not just prompts.
EOF
