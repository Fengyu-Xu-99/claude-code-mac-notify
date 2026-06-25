# Troubleshooting & Design Log

The full story of getting Claude Code desktop notifications working on macOS, including the
dead ends, so the choices in this project make sense. Verified on macOS 26.3.1 (Tahoe),
Apple Silicon.

---

## TL;DR

- **Sound** is played directly with `afplay`. terminal-notifier's own `-sound` is ignored on
  recent macOS, so we never use it.
- **Banner** is drawn by `terminal-notifier`.
- **"Claude asked a question"** is handled by a `PreToolUse` hook on `AskUserQuestion|ExitPlanMode`,
  not the generic `Notification` event.
- **Banner stuck in the sidebar?** `killall NotificationCenter usernoted` (stuck daemon).

---

## Part 1 — What did NOT work (and why)

### 1. terminal-notifier's `-sound` flag
- **Symptom:** banner appears, no sound.
- **Cause:** on macOS 26 the `-sound` flag is silently ignored.
- **Fix:** decouple, play the sound with `afplay` directly. 100% reliable since.

### 2. Trusting any tool to "pop" via the notification API
- **Symptom:** notifications only reached the Notification Center sidebar, never popped, even with
  Alert Style = Persistent and Allow Notifications on.
- **Ruled out:** `noti`, `osascript -e 'display notification'`, per-app and global notification
  settings (all already correct), "Summarize notifications" (was already off).
- **Red herring:** online threads and the terminal-notifier GitHub issues (#307, #312) blame Apple
  deprecating the old `NSUserNotification` API. Plausible, but NOT the cause on this machine.

### 3. swiftDialog as a replacement
- Its `--notification` mode needs notification permission and gets auto-denied when launched
  headless. Its **window** mode (`--mini --position topright`) does pop reliably, but a window is
  more intrusive than a banner. Kept only as a possible fallback, not used.

### 4. Blaming `preferredNotifChannel`
- Hypothesis: `notifications_disabled` was suppressing the hook. **False** per Claude Code docs,
  it only controls the built-in notifier and does not gate hooks.

### 5. Testing the question alert with `AskUserQuestion`
- The in-conversation question prompt never fired the `Notification` hook, because `AskUserQuestion`
  doesn't emit that event, and `Notification` only fires when you're not viewing the session.

---

## Part 2 — What WORKS

### The banner fix: restart the notification daemon
Native banners were being demoted to the sidebar by a **stuck macOS notification daemon**, not by
the API deprecation. One line restores popping:

```sh
killall NotificationCenter usernoted
```

Re-run it if banners ever drift back to sidebar-only (can recur after app reinstalls / OS updates).

### Sound via afplay
Every event plays its sound with `afplay /System/Library/Sounds/<name>.aiff`, backgrounded so it
never blocks Claude. Defaults: Glass (finished), Ping (question / input), Funk (permission).

### Three hooks
- **Stop** → fires at the end of every turn. Reliable.
- **PreToolUse** matched to `AskUserQuestion|ExitPlanMode` → fires right before Claude asks a
  question or shows a plan. This is the reliable "needs your answer" alert.
- **Notification** → fires on permission prompts / idle, but only when you're away from the session.

See `notify.sh` for the implementation and `install.sh` for how they're wired.

---

## Verified facts (Claude Code docs)
- `preferredNotifChannel` values: `auto`, `terminal_bell`, `iterm2`, `iterm2_with_bell`, `kitty`,
  `ghostty`, `notifications_disabled`. Does NOT gate hooks.
- `PreToolUse` fires before these matchable tools: `Bash`, `Edit`, `Write`, `Read`, `Glob`, `Grep`,
  `Agent`, `WebFetch`, `WebSearch`, `AskUserQuestion`, `ExitPlanMode`, and any MCP tool.
- The `Notification` hook fires on `permission_prompt` and `idle_prompt`, surfacing like the desktop
  OS notification (only when you're not actively viewing the session).
- Hooks are shared by the desktop app and the CLI. settings.json edits may need a Claude Code
  restart (or opening `/hooks` once) to take effect.

---

## Known open item
Even configured correctly, banners occasionally land in the sidebar (the stuck-daemon behavior).
Workaround: the `killall` above. A future improvement could be a small launchd job to keep the
daemon healthy. The sound always fires regardless, so this is cosmetic.
