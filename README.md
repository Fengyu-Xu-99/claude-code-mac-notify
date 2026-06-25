# claude-code-mac-notify

Desktop banners + sounds for [Claude Code](https://claude.com/claude-code) on macOS.
Get an on-screen notification with a distinct sound when Claude:

| Event | Banner | Default sound |
|-------|--------|---------------|
| Finishes a job | **Claude Code** — ✅ Finished | Glass |
| Needs your permission | **Claude Code** — 🔐 Needs permission | Funk |
| Is waiting for your input | **Claude Code** — ⌨️ Waiting for input | Ping |

Each banner is branded "Claude Code" and clicking it brings your Claude window to the front.

## Why this exists

Claude Code has a built-in notifier, but it's generic ("Notification") and, depending on your
macOS setup, often lands silently in Notification Center instead of popping on screen. This wires
up richer, clearly-labelled banners that actually appear, with the non-obvious flags that make
that work (see [Gotchas](#gotchas-the-stuff-that-wasted-our-time)).

## Requirements

- macOS
- [Homebrew](https://brew.sh) (the installer uses it to install `terminal-notifier` and `jq`)
- Claude Code

## Install

```sh
git clone https://github.com/<you>/claude-code-mac-notify.git
cd claude-code-mac-notify
./install.sh
```

The installer:
1. Installs `terminal-notifier` and `jq` if missing.
2. Copies `notify.sh` to `~/.claude/hooks/notify.sh`.
3. Adds `Stop` and `Notification` hooks to `~/.claude/settings.json` (merges, never clobbers).
4. Sets `preferredNotifChannel: "notifications_disabled"` so the built-in generic notifier
   doesn't double up.
5. Fires a test banner.

### Two manual steps (macOS won't let a script do these)

In **System Settings → Notifications → terminal-notifier**:
1. **Allow notifications: ON**
2. **Alert style: Banners** (auto-hide) or **Alerts** (stay until dismissed)
3. **Summarize notifications: OFF** — if on, banners go to the sidebar instead of popping

Then make sure a **Focus / Do Not Disturb** mode isn't filtering it, and **fully quit and reopen
Claude Code** so it reloads the new config.

## Customize

Everything lives in `~/.claude/hooks/notify.sh`. Edit the subtitles/messages directly, or set
env vars (e.g. in the hook, or globally):

```sh
CLAUDE_NOTIFY_TITLE="My Claude"
CLAUDE_NOTIFY_SOUND_FINISHED="Hero"      # any file in /System/Library/Sounds (no extension)
CLAUDE_NOTIFY_SOUND_PERMISSION="Funk"
CLAUDE_NOTIFY_SOUND_INPUT="Ping"
CLAUDE_NOTIFY_ACTIVATE="com.googlecode.iterm2"   # app to focus when the banner is clicked
```

The "click to focus" target is auto-detected from your terminal (`iTerm.app`, `Apple_Terminal`,
`vscode`, `ghostty`, `WezTerm`, `Hyper`) and falls back to the Claude desktop app.

## Uninstall

```sh
./uninstall.sh                  # removes the hooks + notify.sh
./uninstall.sh --restore-builtin  # also re-enables Claude Code's built-in notifier
```

## Gotchas (the stuff that wasted our time)

- **`osascript` / "Script Editor" notifications never pop on screen** for some setups, they only
  reach Notification Center. `terminal-notifier` pops reliably. This project uses the latter.
- **`-ignoreDnD` is required** to appear on screen when a Focus/Do Not Disturb mode is active.
  Without it the banner is silently shunted to the sidebar.
- **Don't use `terminal-notifier`'s `-group` flag** if you want each event to pop. With a group,
  v2.0.0 silently *replaces* the previous banner instead of re-alerting.
- **"Summarize notifications" (Apple Intelligence)** also routes banners to the sidebar; turn it
  off for terminal-notifier.
- **Config reloads on Claude Code restart.** Edits to `settings.json` mid-session won't take
  effect until you reopen (or open the `/hooks` menu once).

## License

MIT
