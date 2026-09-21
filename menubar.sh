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
  working)    STATUS="working"; LABEL="working" ;;   # MessageDisplay: streaming text
  tool)       STATUS="working"; LABEL="working" ;;   # PreToolUse: a tool is executing
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

# The conversation's display name, best source first:
#   CLAUDE_NOTIFY_SESSION > Claude Code's own generated title > first thing the
#   user actually typed > the project folder.
#
# Claude Code writes its generated title into the transcript as
# {"type":"ai-title","aiTitle":"..."} -- the same string the IDE shows on the tab.
# Two things matter about it: it does NOT exist at a session's first event (it
# appears a few turns in), and it is rewritten as the conversation develops. So
# we take the LAST one and we re-derive on later events rather than once.
#
# Read from the tail: transcripts reach tens of megabytes and this keeps the cost
# flat instead of growing with the conversation.
derive_name() {
  _t="$1"; _fallback="$2"
  if [ -n "${CLAUDE_NOTIFY_SESSION:-}" ]; then
    printf '%s' "$CLAUDE_NOTIFY_SESSION"; return
  fi
  _n=""
  if [ -n "$_t" ] && [ -f "$_t" ]; then
    _n="$(tail -c 262144 "$_t" 2>/dev/null | grep '"type":"ai-title"' | tail -1 \
          | jq -r '.aiTitle // empty' 2>/dev/null)"
    # A tail that happens to be all tool output carries no title: pay for a full
    # scan only in that case.
    [ -z "$_n" ] && _n="$(jq -r 'select(.type=="ai-title") | .aiTitle' "$_t" 2>/dev/null | tail -1)"
    # Transcripts predating ai-title: fall back to the first plain-text user
    # message. Drop anything starting with "<", which is machinery like
    # <local-command-caveat> or <task-notification> rather than something typed.
    if [ -z "$_n" ]; then
      _n="$(jq -r 'select(.type=="user" and (.message.content|type=="string")) | .message.content' "$_t" 2>/dev/null \
            | grep -v '^<' | head -1 | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')"
    fi
  fi
  [ -z "$_n" ] && _n="$_fallback"
  [ "${#_n}" -gt "$NAME_MAXLEN" ] && _n="$(printf '%s' "$_n" | cut -c1-"$NAME_MAXLEN")…"
  printf '%s' "$_n"
}

# FAST PATH: the session is already known (file exists). MessageDisplay fires on
# every streamed chunk, so we must NOT re-read the transcript here. Just update
# the existing record. ponytail: single jq edit, no transcript I/O.
#
# Downgrade guard: only a background STREAMING "working" event (MessageDisplay)
# is blocked from stealing an active "waiting"/"review" state, so streaming text
# doesn't flicker the yellow away. But "tool" (PreToolUse) and "turn"
# (UserPromptSubmit) DO clear waiting: PreToolUse fires right after you approve a
# permission, so it's the signal that "needs permission" is resolved and work
# resumed. (Confirmed order: PermissionRequest -> approve -> PreToolUse -> tool.)
if [ -f "$OUT" ]; then
  cur="$(jq -r '.status // ""' "$OUT" 2>/dev/null)"
  if { [ "$cur" = "waiting" ] || [ "$cur" = "review" ]; } \
     && [ "$EVENT" = "working" ]; then
    # keep the sticky state, but do NOT bump ts (so review/waiting age is honest)
    exit 0
  fi
  # Identity fields (name/cwd/project) used to be written once and never touched
  # again. That was wrong twice over: the generated title does not exist yet at a
  # session's first event, and cwd changes when you move into a subfolder. So
  # refresh them too -- but only on the LOW-FREQUENCY events. "working"
  # (MessageDisplay, once per streamed chunk) and "tool" (PreToolUse) stay on the
  # cheap path, which is the whole reason this fast path exists.
  case "$EVENT" in
    turn|waiting|permission|done|notify)
      CWD="$(field '.cwd')"
      [ -z "$CWD" ] && CWD="$(jq -r '.cwd // empty' "$OUT" 2>/dev/null)"
      PROJECT="$(basename "$CWD")"
      NAME="$(derive_name "$(field '.transcript_path')" "$PROJECT")"
      jq --arg st "$STATUS" --arg l "$LABEL" --argjson t "$NOW" \
         --arg d "$CWD" --arg p "$PROJECT" --arg n "$NAME" \
         '.status=$st | .label=$l | .ts=$t | .cwd=$d | .project=$p | .name=$n' \
         "$OUT" > "$tmp" 2>/dev/null && mv "$tmp" "$OUT"
      ;;
    *)
      jq --arg st "$STATUS" --arg l "$LABEL" --argjson t "$NOW" \
         '.status=$st | .label=$l | .ts=$t' "$OUT" > "$tmp" 2>/dev/null \
         && mv "$tmp" "$OUT"
      ;;
  esac
  exit 0
fi

# SLOW PATH: first event for this session -> create the record. The name is very
# likely just the project folder at this point, because Claude Code has not
# generated a title yet; the fast path above upgrades it once one exists.
CWD="$(field '.cwd')"; [ -z "$CWD" ] && CWD="$PWD"
PROJECT="$(basename "$CWD")"
NAME="$(derive_name "$(field '.transcript_path')" "$PROJECT")"

# jq assembles the JSON so quotes/emoji in the name can't corrupt it. Write to a
# temp then mv, so the menu app never reads a half-written file.
jq -n --arg s "$SID" --arg p "$PROJECT" --arg d "$CWD" --arg n "$NAME" \
      --arg st "$STATUS" --arg l "$LABEL" --argjson t "$NOW" \
   '{session:$s, project:$p, cwd:$d, name:$n, status:$st, label:$l, ts:$t}' \
   > "$tmp" 2>/dev/null && mv "$tmp" "$OUT"
