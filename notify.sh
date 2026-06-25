#!/usr/bin/env bash
# claude-code-mac-notify — on-screen banner + sound for Claude Code lifecycle events.
#
# Invoked by Claude Code hooks (see install.sh):
#   notify.sh stop          -> "Finished" banner
#   notify.sh notification  -> reads the hook's JSON on stdin, classifies it as
#                              "needs permission" vs "waiting for input"
#
# Customize the SUBTITLES and SOUNDS below to taste. macOS system sounds live in
# /System/Library/Sounds (Glass, Funk, Ping, Hero, Submarine, Pop, Blow, ...).
set -uo pipefail

# ---- config (override via env vars if you like) -----------------------------
TITLE="${CLAUDE_NOTIFY_TITLE:-Claude Code}"
SOUND_FINISHED="${CLAUDE_NOTIFY_SOUND_FINISHED:-Glass}"
SOUND_PERMISSION="${CLAUDE_NOTIFY_SOUND_PERMISSION:-Funk}"
SOUND_INPUT="${CLAUDE_NOTIFY_SOUND_INPUT:-Ping}"
# -----------------------------------------------------------------------------

TN="$(command -v terminal-notifier || true)"
[ -x "$TN" ] || exit 0   # terminal-notifier not installed: do nothing, never block Claude

# Which app should clicking the banner bring to the front? Detected from the
# launching terminal; falls back to the Claude desktop app. Override with
# CLAUDE_NOTIFY_ACTIVATE=<bundle id>.
case "${TERM_PROGRAM:-}" in
  iTerm.app)      ACTIVATE="com.googlecode.iterm2" ;;
  Apple_Terminal) ACTIVATE="com.apple.Terminal" ;;
  vscode)         ACTIVATE="com.microsoft.VSCode" ;;
  ghostty)        ACTIVATE="com.mitchellh.ghostty" ;;
  WezTerm)        ACTIVATE="com.github.wez.wezterm" ;;
  Hyper)          ACTIVATE="co.zeit.hyper" ;;
  *)              ACTIVATE="com.anthropic.claudefordesktop" ;;
esac
ACTIVATE="${CLAUDE_NOTIFY_ACTIVATE:-$ACTIVATE}"

EVENT="${1:-stop}"
case "$EVENT" in
  stop)
    SUBTITLE="✅ Finished"; MESSAGE="Task complete"; SOUND="$SOUND_FINISHED"
    ;;
  notification)
    MSG="$(jq -r '.message // empty' 2>/dev/null)"
    [ -z "$MSG" ] && MSG="Waiting on you"
    if printf '%s' "$MSG" | grep -qi permission; then
      SUBTITLE="🔐 Needs permission"; SOUND="$SOUND_PERMISSION"
    else
      SUBTITLE="⌨️ Waiting for input"; SOUND="$SOUND_INPUT"
    fi
    MESSAGE="$MSG"
    ;;
  *)
    SUBTITLE=""; MESSAGE="$EVENT"; SOUND="$SOUND_FINISHED"
    ;;
esac

# -ignoreDnD is REQUIRED to pop on screen when a Focus/Do Not Disturb mode is
# active; without it the banner is silently routed to Notification Center.
"$TN" -title "$TITLE" -subtitle "$SUBTITLE" -message "$MESSAGE" \
  -sound "$SOUND" -activate "$ACTIVATE" -ignoreDnD >/dev/null 2>&1 || true
