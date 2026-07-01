#!/usr/bin/env bash
# claude-code-mac-notify — menu bar state writer.
#
# Runs from the SAME Claude Code hooks as notify.sh. On each event it writes one
# JSON file per session to ~/.claude/menubar/, which the ClaudeWatchMenu app
# reads to show every running session, its project, and its status in the menu
# bar. This never draws anything itself; it just records state.
#
#   menubar.sh working   -> a tool is about to run     (PreToolUse Edit/Write/Bash)
#   menubar.sh waiting   -> asking a question / plan     (PreToolUse AskUserQuestion/ExitPlanMode)
#   menubar.sh notify    -> permission / input wait      (Notification, classified from stdin)
#   menubar.sh done      -> finished                     (Stop)
#
# One file per session_id so parallel sessions never clobber each other. The
# name-derivation mirrors notify.sh so labels match the banners.
set -uo pipefail

STATE_DIR="${CLAUDE_MENUBAR_DIR:-$HOME/.claude/menubar}"
NAME_MAXLEN="${CLAUDE_NOTIFY_NAME_MAXLEN:-50}"
mkdir -p "$STATE_DIR"

# Read the hook JSON from stdin only when piped (a real hook run); on a tty
# (manual run) skip cat so it doesn't block forever. Same guard as notify.sh.
INPUT=""
if [ ! -t 0 ]; then INPUT="$(cat)"; fi

field() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }

SID="$(field '.session_id')"
[ -z "$SID" ] && SID="$$"                 # fallback so a manual run still writes
OUT="$STATE_DIR/$SID.json"

EVENT="${1:-done}"
case "$EVENT" in
  working)    STATUS="working"; LABEL="working" ;;
  turn)       STATUS="working"; LABEL="working" ;;   # UserPromptSubmit: new turn
  waiting)    STATUS="waiting"; LABEL="needs your answer" ;;
  permission) STATUS="waiting"; LABEL="needs permission" ;;
  done)       STATUS="review";  LABEL="finished — needs review" ;;
  reviewed)   STATUS="idle";    LABEL="reviewed" ;;  # user clicked "Mark reviewed"
  notify)
    MSG="$(field '.message')"
    if printf '%s' "$MSG" | grep -qi permission; then
      STATUS="waiting"; LABEL="needs permission"
    else
      STATUS="waiting"; LABEL="waiting for input"
    fi ;;
  *) STATUS="$EVENT"; LABEL="$EVENT" ;;
esac

NOW="$(date +%s)"
tmp="$STATE_DIR/.$SID.$$.tmp"

# FAST PATH: the session is already known (file exists). MessageDisplay fires on
# every streamed chunk, so we must NOT re-read the transcript here. Just update
# the existing record. ponytail: single jq edit, no transcript I/O.
#
# Downgrade guard: a background streaming "working" event must not steal an
# active "waiting" (a prompt is up) or "review" (finished, awaiting you) state.
# Only an explicit new turn ("turn"), or events that raise attention, may change
# those. Everything else is a free overwrite.
if [ -f "$OUT" ]; then
  cur="$(jq -r '.status // ""' "$OUT" 2>/dev/null)"
  if { [ "$cur" = "waiting" ] || [ "$cur" = "review" ]; } \
     && { [ "$EVENT" = "working" ]; }; then
    # keep the sticky state, but do NOT bump ts (so review/waiting age is honest)
    exit 0
  fi
  jq --arg st "$STATUS" --arg l "$LABEL" --argjson t "$NOW" \
     '.status=$st | .label=$l | .ts=$t' "$OUT" > "$tmp" 2>/dev/null \
     && mv "$tmp" "$OUT"
  exit 0
fi

# SLOW PATH: first event for this session -> derive project + name once.
CWD="$(field '.cwd')"; [ -z "$CWD" ] && CWD="$PWD"
PROJECT="$(basename "$CWD")"
TRANSCRIPT="$(field '.transcript_path')"
# Name: explicit override > first plain-text user message in transcript > project.
NAME="${CLAUDE_NOTIFY_SESSION:-}"
if [ -z "$NAME" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  NAME="$(jq -r 'select(.type=="user" and (.message.content|type=="string")) | .message.content' "$TRANSCRIPT" 2>/dev/null \
          | head -1 | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')"
fi
[ -z "$NAME" ] && NAME="$PROJECT"
[ "${#NAME}" -gt "$NAME_MAXLEN" ] && NAME="$(printf '%s' "$NAME" | cut -c1-"$NAME_MAXLEN")…"

# jq assembles the JSON so quotes/emoji in the name can't corrupt it. Write to a
# temp then mv, so the menu app never reads a half-written file.
jq -n --arg s "$SID" --arg p "$PROJECT" --arg d "$CWD" --arg n "$NAME" \
      --arg st "$STATUS" --arg l "$LABEL" --argjson t "$NOW" \
   '{session:$s, project:$p, cwd:$d, name:$n, status:$st, label:$l, ts:$t}' \
   > "$tmp" 2>/dev/null && mv "$tmp" "$OUT"
