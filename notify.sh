#!/usr/bin/env bash
# claude-code-mac-notify — on-screen banner + sound for Claude Code lifecycle events.
#
# Invoked by Claude Code hooks (see install.sh):
#   notify.sh stop          -> "Finished" banner            (Stop event)
#   notify.sh question      -> "Needs your answer" banner   (PreToolUse on AskUserQuestion/ExitPlanMode)
#   notify.sh tool          -> "About to run a tool" banner  (optional PreToolUse on Edit/Write/Bash)
#   notify.sh notification  -> reads the hook's JSON on stdin and classifies it as
#                              "needs permission" vs "waiting for input"  (Notification event)
#
# Each banner names the conversation so you can tell which session finished when
# several are running. The name is derived from the conversation's first user
# message (read from the transcript the hook passes on stdin), falling back to the
# project folder name. Override it explicitly with CLAUDE_NOTIFY_SESSION.
#
# DESIGN NOTE: the sound is played directly with `afplay`, NOT via terminal-notifier's
# -sound flag. On recent macOS (Tahoe / 26.x) terminal-notifier's -sound is silently
# ignored, so decoupling the sound is what makes it reliable. terminal-notifier draws
# the banner only. If terminal-notifier isn't installed, the sound alone still fires.
#
# Customize the SUBTITLES and SOUNDS below to taste. macOS system sounds live in
# /System/Library/Sounds (Glass, Funk, Ping, Hero, Submarine, Pop, Blow, ...).
set -uo pipefail

# ---- config (override via env vars if you like) -----------------------------
TITLE="${CLAUDE_NOTIFY_TITLE:-Claude Code}"
SOUND_FINISHED="${CLAUDE_NOTIFY_SOUND_FINISHED:-Glass}"
SOUND_PERMISSION="${CLAUDE_NOTIFY_SOUND_PERMISSION:-Funk}"
SOUND_INPUT="${CLAUDE_NOTIFY_SOUND_INPUT:-Ping}"
SOUND_QUESTION="${CLAUDE_NOTIFY_SOUND_QUESTION:-Ping}"
SOUND_TOOL="${CLAUDE_NOTIFY_SOUND_TOOL:-Tink}"
SOUND_DIR="/System/Library/Sounds"
NAME_MAXLEN="${CLAUDE_NOTIFY_NAME_MAXLEN:-40}"
# -----------------------------------------------------------------------------

TN="$(command -v terminal-notifier || true)"

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

# Read the hook's JSON payload from stdin, but only when it's actually piped in
# (a real hook invocation). On a manual/terminal run stdin is a tty, so we skip
# `cat` to avoid blocking forever.
INPUT=""
if [ ! -t 0 ]; then INPUT="$(cat)"; fi

# ---- derive a short, recognizable conversation name -------------------------
# Priority: explicit CLAUDE_NOTIFY_SESSION > first user message in transcript >
# project folder name.
NAME="${CLAUDE_NOTIFY_SESSION:-}"
if [ -z "$NAME" ]; then
  TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
  if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    # First plain-text user message. `head -1` closes the pipe early so jq doesn't
    # slurp a multi-MB transcript.
    NAME="$(jq -r 'select(.type=="user" and (.message.content|type=="string")) | .message.content' "$TRANSCRIPT" 2>/dev/null \
            | head -1 | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')"
  fi
fi
if [ -z "$NAME" ]; then
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  [ -z "$CWD" ] && CWD="$PWD"
  NAME="$(basename "$CWD")"
fi
# Truncate long names (byte-based; conversation openers are virtually always ASCII).
if [ "${#NAME}" -gt "$NAME_MAXLEN" ]; then
  NAME="$(printf '%s' "$NAME" | cut -c1-"$NAME_MAXLEN")…"
fi
# -----------------------------------------------------------------------------

EVENT="${1:-stop}"
case "$EVENT" in
  stop)
    SUBTITLE="✅ Finished"; SOUND="$SOUND_FINISHED"
    ;;
  question)
    SUBTITLE="❓ Needs your answer"; SOUND="$SOUND_QUESTION"
    ;;
  tool)
    SUBTITLE="⚙️ About to run a tool"; SOUND="$SOUND_TOOL"
    ;;
  notification)
    MSG="$(printf '%s' "$INPUT" | jq -r '.message // empty' 2>/dev/null)"
    if printf '%s' "$MSG" | grep -qi permission; then
      SUBTITLE="🔐 Needs permission"; SOUND="$SOUND_PERMISSION"
    else
      SUBTITLE="⌨️ Waiting for input"; SOUND="$SOUND_INPUT"
    fi
    ;;
  *)
    SUBTITLE="$EVENT"; SOUND="$SOUND_FINISHED"
    ;;
esac

# The conversation name is the message line, so you can tell sessions apart.
MESSAGE="$NAME"

# Sound: play directly via afplay. terminal-notifier's -sound is ignored on recent
# macOS, so this is the reliable path. Backgrounded so it never blocks Claude.
if [ -f "$SOUND_DIR/$SOUND.aiff" ]; then
  afplay "$SOUND_DIR/$SOUND.aiff" >/dev/null 2>&1 &
fi

# Banner: terminal-notifier (optional). -ignoreDnD helps it appear when a Focus /
# Do Not Disturb mode is active. If terminal-notifier is missing, we already played
# the sound above, so we just skip the banner.
if [ -x "$TN" ]; then
  "$TN" -title "$TITLE" -subtitle "$SUBTITLE" -message "$MESSAGE" \
    -activate "$ACTIVATE" -ignoreDnD >/dev/null 2>&1 || true
fi
