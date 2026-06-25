# claude-code-mac-notify

Desktop banners + sounds for [Claude Code](https://claude.com/claude-code) on macOS.
Get an on-screen notification with a distinct sound when Claude:

| Event | Banner | Default sound |
|-------|--------|---------------|
| Finishes a job | **Claude Code** — ✅ Finished | Glass |
| Asks you a question | **Claude Code** — ❓ Needs your answer | Ping |
| Needs your permission | **Claude Code** — 🔐 Needs permission | Funk |
| Is waiting for your input | **Claude Code** — ⌨️ Waiting for input | Ping |

Each banner is branded "Claude Code" and clicking it brings your Claude window to the front.
The sound always plays (via `afplay`); the banner is a bonus on top.

### Telling sessions apart

The banner's message line names the conversation, so when several sessions are running you can
see *which one* finished or needs you. The name is derived automatically from the conversation's
first user message (read from the transcript the hook provides), truncated to ~40 chars. If that
isn't available it falls back to the project folder name. Set `CLAUDE_NOTIFY_SESSION` to override
it with a fixed label.

## Why this exists

Claude Code has a built-in notifier, but it's generic ("Notification"), it only surfaces when
you're already looking away from the session, and depending on your macOS setup it often lands
silently in Notification Center. It also won't alert you the moment Claude stops to ask a
question. This wires up richer, clearly-labelled alerts with a distinct sound per event, including
a dedicated "Claude is asking you a question" ping, using the non-obvious approach that actually
works on current macOS (see [Gotchas](#gotchas-the-stuff-that-wasted-our-time)).

## Requirements

- macOS
- [Homebrew](https://brew.sh) (the installer uses it to install `terminal-notifier` and `jq`)
- Claude Code

## Install

```sh
git clone https://github.com/Fengyu-Xu-99/claude-code-mac-notify.git
cd claude-code-mac-notify
./install.sh
```

The installer:
1. Installs `terminal-notifier` and `jq` if missing.
2. Copies `notify.sh` to `~/.claude/hooks/notify.sh`.
3. Adds `Stop`, `Notification`, and `PreToolUse` (matched to `AskUserQuestion`/`ExitPlanMode`)
   hooks to `~/.claude/settings.json` (merges, never clobbers).
4. Sets `preferredNotifChannel: "notifications_disabled"` so the built-in generic notifier
   doesn't double up.
5. Fires a test banner.

### One manual step (macOS won't let a script do this)

In **System Settings → Notifications → terminal-notifier**:
1. **Allow notifications: ON**
2. **Alert style: Banners** (auto-hide) or **Alerts** (stay until dismissed)

Then **fully quit and reopen Claude Code** so it reloads the new config. If banners only appear in
the Notification Center sidebar instead of popping, see [Gotchas](#gotchas-the-stuff-that-wasted-our-time)
(it's a one-line daemon reset, not a settings problem).

## Optional: alert on permission prompts

By default you get alerts when Claude **finishes**, **asks a question**, or (when you're away from
the session) **needs permission / is waiting**. But while you're actively looking at the session,
the desktop app handles permission prompts in its own UI and does **not** fire a hook, so you won't
hear anything when a permission dialog pops up in front of you.

If you want a sound on permission prompts even while watching, enable tool alerts:

```sh
./install.sh --tool-alerts
```

This adds a soft alert (default sound: Tink) before every `Edit`, `Write`, and `Bash`.

> **Tradeoff, read this first.** There's no hook that fires *only* on a permission prompt, so this
> fires before **every** edit and command, not just the ones that ask for approval. That means
> routine tool use also makes the sound. Most people find this noisy and leave it off; it's here
> for folks who run with strict permissions and want to be pinged before anything happens. Tune the
> sound with `CLAUDE_NOTIFY_SOUND_TOOL`, or remove it later with `./uninstall.sh`.

## Customize

Everything lives in `~/.claude/hooks/notify.sh`. Edit the subtitles/messages directly, or set
env vars (e.g. in the hook, or globally):

```sh
CLAUDE_NOTIFY_TITLE="My Claude"
CLAUDE_NOTIFY_SOUND_FINISHED="Hero"      # any file in /System/Library/Sounds (no extension)
CLAUDE_NOTIFY_SOUND_QUESTION="Ping"
CLAUDE_NOTIFY_SOUND_PERMISSION="Funk"
CLAUDE_NOTIFY_SOUND_INPUT="Ping"
CLAUDE_NOTIFY_SOUND_TOOL="Tink"      # only used if you enable --tool-alerts (see below)
CLAUDE_NOTIFY_SESSION="notification testing"      # fixed name for this session (overrides auto-naming)
CLAUDE_NOTIFY_NAME_MAXLEN="40"                     # truncate the auto-derived name to N chars
CLAUDE_NOTIFY_ACTIVATE="com.googlecode.iterm2"    # app to focus when the banner is clicked
```

The "click to focus" target is auto-detected from your terminal (`iTerm.app`, `Apple_Terminal`,
`vscode`, `ghostty`, `WezTerm`, `Hyper`) and falls back to the Claude desktop app.

## Uninstall

```sh
./uninstall.sh                  # removes the hooks + notify.sh
./uninstall.sh --restore-builtin  # also re-enables Claude Code's built-in notifier
```

## Gotchas (the stuff that wasted our time)

These are the findings that actually mattered, verified on macOS 26 (Tahoe), after a lot of
dead ends. For the full story, including the approaches that *didn't* work, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

- **`terminal-notifier`'s `-sound` flag is ignored on recent macOS.** This is the big one: the
  banner shows but no sound plays. The fix is to *not* rely on it, `notify.sh` plays the sound
  itself with `afplay /System/Library/Sounds/<name>.aiff`. Because of this the sound is rock
  solid even when the banner misbehaves, and it still fires if `terminal-notifier` isn't installed.
- **Banners landing in the sidebar instead of popping = a stuck notification daemon, not a
  settings problem.** If everything is configured right but banners only appear in Notification
  Center, reset the daemon:
  ```sh
  killall NotificationCenter usernoted
  ```
  This was the real cause, and it can recur after app reinstalls or macOS point updates. (Note:
  the deprecated `NSUserNotification` API that online threads blame turned out to be a red herring
  here, the daemon restart is what brought banners back.)
- **The built-in `Notification` event only fires when you're NOT viewing the session.** Like the
  desktop OS notification, it stays silent while you're watching the window, so testing it while
  staring at the screen shows nothing. That's expected. This is also why the dedicated
  **`PreToolUse` question hook** exists: it fires unconditionally the moment Claude asks, which
  the `Notification` event won't do.
- **`AskUserQuestion` does not emit a `Notification` event.** To get alerted when Claude asks a
  question, you must hook `PreToolUse` matched to `AskUserQuestion` (and `ExitPlanMode` for plan
  approvals). The installer does this for you.
- **`preferredNotifChannel` does not gate hooks.** Setting it to `notifications_disabled` only
  silences Claude Code's built-in notifier; your hooks still fire. We use it to avoid duplicate
  banners.
- **The new macOS sound set (Breeze, Submerge, Funky, etc.) can't be used here.** Those sounds,
  added in recent macOS, aren't stored as plain files; they live in a sealed system asset that only
  Apple's own APIs can play. `afplay` (and therefore this tool) can only play the classic sounds in
  `/System/Library/Sounds` (Glass, Funk, Ping, Submarine, Blow, Hero, Sosumi, ...). Several classic
  sounds are near-identical twins of the new ones (Submarine ≈ Submerge, Funk ≈ Funky), so pick the
  closest classic name.
- **`-ignoreDnD`** helps the banner appear when a Focus / Do Not Disturb mode is active.
- **Don't use `terminal-notifier`'s `-group` flag** if you want each event to pop. With a group,
  v2.0.0 silently *replaces* the previous banner instead of re-alerting. This project doesn't use it.
- **Config reloads on Claude Code restart.** Edits to `settings.json` mid-session won't take
  effect until you reopen (or open the `/hooks` menu once).

## License

MIT
