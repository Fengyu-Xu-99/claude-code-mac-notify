import Cocoa
import Foundation

// claude-code-mac-notify — menu bar app.
//
// Lists every Claude Code session, its project, and status, in the macOS menu
// bar. Reads the per-session JSON files that menubar.sh writes to
// ~/.claude/menubar/ (no polling of processes, no watcher). Modeled on
// codex-notify-watch's CodexWatchMenu.swift.
//
// Status shown:
//   🟡 waiting  — asking a question / needs permission / waiting for input
//   🟢 working  — last event within IDLE_SECS
//   ⚪️ idle     — finished, or quiet longer than IDLE_SECS
// Files untouched for STALE_SECS are dropped (session is gone).

let IDLE_SECS: TimeInterval = 90
let STALE_SECS: TimeInterval = 4 * 3600

struct SessionState: Decodable {
    let session: String
    let project: String
    let cwd: String
    let name: String
    let status: String
    let label: String
    let ts: Double
}

// A session decorated with what the menu should actually show.
struct Row {
    let state: SessionState
    let effectiveStatus: String   // "waiting" | "review" | "working" | "idle"
    let age: TimeInterval
    var rank: Int {               // things needing you float to the top
        switch effectiveStatus {
        case "waiting": return 0  // 🟡 needs an answer / permission now
        case "review":  return 1  // 🔵 finished, awaiting your review
        case "working": return 2  // 🟢 busy
        default:        return 3  // ⚪️ idle
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?

    private var stateDir: String {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_MENUBAR_DIR"] {
            return override
        }
        return "\(NSHomeDirectory())/.claude/menubar"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "⌁"
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func refresh() {
        let rows = loadRows()
        updateTitle(rows)
        rebuildMenu(rows)
    }

    // Read + decode every state file, drop stale ones, compute effective status.
    private func loadRows() -> [Row] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: stateDir) else {
            return []
        }
        let now = Date().timeIntervalSince1970
        var rows: [Row] = []
        for entry in entries where entry.hasSuffix(".json") {
            let path = "\(stateDir)/\(entry)"
            guard let data = fm.contents(atPath: path),
                  let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
                continue
            }
            let age = now - state.ts
            if age > STALE_SECS {
                try? fm.removeItem(atPath: path)   // forget dead sessions
                continue
            }
            // "waiting" and "review" are STICKY: they never age to idle, they sit
            // until you act (answer the prompt, or click Mark reviewed). Only
            // "working" ages out after IDLE_SECS. "idle"/"reviewed" show as idle.
            let effective: String
            switch state.status {
            case "waiting":            effective = "waiting"
            case "review":             effective = "review"
            case "idle", "reviewed":   effective = "idle"
            default:                   effective = age > IDLE_SECS ? "idle" : "working"
            }
            rows.append(Row(state: state, effectiveStatus: effective, age: age))
        }
        // waiting first, then working, then idle; newest first within each.
        return rows.sorted { a, b in
            a.rank != b.rank ? a.rank < b.rank : a.state.ts > b.state.ts
        }
    }

    private func updateTitle(_ rows: [Row]) {
        let waiting = rows.filter { $0.effectiveStatus == "waiting" }.count
        let review  = rows.filter { $0.effectiveStatus == "review" }.count
        let working = rows.filter { $0.effectiveStatus == "working" }.count
        var parts: [String] = []
        if working > 0 { parts.append("🟢\(working)") }
        if waiting > 0 { parts.append("🟡\(waiting)") }
        if review  > 0 { parts.append("🔵\(review)") }   // finished, unreviewed
        statusItem.button?.title = parts.isEmpty ? "⌁" : "⌁ " + parts.joined(separator: " ")
    }

    private func rebuildMenu(_ rows: [Row]) {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Claude Code sessions", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if rows.isEmpty {
            let item = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for (index, row) in rows.enumerated() {
                let item = NSMenuItem()
                item.tag = index
                // Each row is a single custom view: dot · project · status · age · action.
                // openSession/markReviewed/removeSession are wired inside the view.
                item.view = SessionRowView(row: row, index: index, target: self,
                                           open: #selector(openSession(_:)),
                                           review: #selector(markReviewed(_:)),
                                           remove: #selector(removeSession(_:)))
                menu.addItem(item)
            }
        }

        // legend: decode the dot colors (only shown when there are sessions)
        if !rows.isEmpty {
            menu.addItem(.separator())
            let legend = NSMenuItem()
            legend.isEnabled = false
            legend.view = LegendView()
            menu.addItem(legend)
        }

        menu.addItem(.separator())
        // Sound toggle: writes/removes ~/.claude/menubar/sound.off, which notify.sh
        // checks before playing. Muting silences the sounds; banners still show.
        let muted = FileManager.default.fileExists(atPath: muteFlagPath)
        let sound = NSMenuItem(title: muted ? "🔇 Unmute sounds" : "🔊 Mute sounds",
                               action: #selector(toggleMute), keyEquivalent: "")
        sound.target = self
        menu.addItem(sound)
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        // store rows so the click handlers can resolve a tag -> session
        self.currentRows = rows
        statusItem.menu = menu
    }

    private var muteFlagPath: String { "\(stateDir)/sound.off" }

    @objc private func toggleMute() {
        let fm = FileManager.default
        if fm.fileExists(atPath: muteFlagPath) {
            try? fm.removeItem(atPath: muteFlagPath)
        } else {
            try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            fm.createFile(atPath: muteFlagPath, contents: nil)
        }
        refresh()
    }

    private var currentRows: [Row] = []

    // Sender may be an NSMenuItem or a control inside a custom row view; both
    // carry the row index in .tag.
    private func tag(of sender: Any) -> Int? {
        if let mi = sender as? NSMenuItem { return mi.tag }
        if let c = sender as? NSControl { return c.tag }
        if let v = sender as? NSView { return v.tag }
        return nil
    }

    private func dismissMenu() { statusItem.menu?.cancelTracking() }

    // Clicking a row just dismisses the menu. Click-to-open-in-VS-Code was
    // removed: there's no reliable, non-destructive way to focus the EXISTING
    // window for a folder (code --reuse-window overwrites the active window, and
    // plain `code <folder>` still opened a new window on some setups). The row's
    // tooltip shows the session name and cwd if you need to find it yourself.
    @objc private func openSession(_ sender: Any) {
        dismissMenu()
    }

    // "Mark reviewed": clear a finished session's sticky blue by writing status
    // "reviewed" into its state file. loadRows then treats it as idle.
    @objc private func markReviewed(_ sender: Any) {
        guard let t = tag(of: sender), currentRows.indices.contains(t) else { return }
        dismissMenu()
        let sid = currentRows[t].state.session
        let path = "\(stateDir)/\(sid).json"
        guard let data = FileManager.default.contents(atPath: path),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        obj["status"] = "reviewed"
        obj["label"] = "reviewed"
        if let out = try? JSONSerialization.data(withJSONObject: obj) {
            try? out.write(to: URL(fileURLWithPath: path))
        }
        refresh()
    }

    // "Remove": take an idle session off the list now by deleting its state file.
    // If that session fires another event later, menubar.sh recreates it.
    @objc private func removeSession(_ sender: Any) {
        guard let t = tag(of: sender), currentRows.indices.contains(t) else { return }
        dismissMenu()
        let sid = currentRows[t].state.session
        try? FileManager.default.removeItem(atPath: "\(stateDir)/\(sid).json")
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// A single menu row: [dot] project · status            age  [action]
// The whole row is clickable (opens the session). The trailing action button,
// present only on review (✓) and idle (✕) rows, handles its own click.
final class SessionRowView: NSView {
    private let index: Int
    private weak var target: AnyObject?
    private let openSel: Selector
    private var highlighted = false

    // NSView.tag is read-only; expose our row index through it so tag(of:) works.
    override var tag: Int { index }

    init(row: Row, index: Int, target: AnyObject, open: Selector, review: Selector, remove: Selector) {
        self.index = index
        self.target = target
        self.openSel = open
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 34))

        // --- color dot (drawn, not emoji: sharper, aligns to baseline) --------
        // The dot color IS the status; a legend at the menu bottom decodes it,
        // so no per-row status word is needed.
        let dotColor: NSColor
        switch row.effectiveStatus {
        case "waiting": dotColor = .systemYellow
        case "review":  dotColor = .systemBlue
        case "working": dotColor = .systemGreen
        default:        dotColor = .tertiaryLabelColor
        }
        let dot = NSView(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        // --- project (the only text on the row) + age (muted, right) ----------
        let project = label(row.state.project, font: .menuFont(ofSize: 13), color: .labelColor)
        let age = label(shortAge(row.age), font: .menuFont(ofSize: 11), color: .tertiaryLabelColor)
        [project, age].forEach { addSubview($0) }

        // --- trailing action (only where it makes sense) ----------------------
        var action: NSButton?
        if row.effectiveStatus == "review" {
            action = actionButton(symbol: "checkmark.circle.fill", tip: "Mark reviewed", sel: review)
        } else if row.effectiveStatus == "idle" {
            action = actionButton(symbol: "xmark.circle.fill", tip: "Remove from list", sel: remove)
        }
        if let action { addSubview(action) }

        // tooltip carries the full session name + cwd (kept off the row itself)
        self.toolTip = "\(row.state.name)\n\(row.state.cwd)\nlast event \(shortAge(row.age)) ago"

        // --- layout: flexbox-like via constraints -----------------------------
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            project.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            project.centerYAnchor.constraint(equalTo: centerYAnchor),

            age.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // project truncates before it pushes the age off the right edge
        project.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        if let action {
            NSLayoutConstraint.activate([
                action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                action.centerYAnchor.constraint(equalTo: centerYAnchor),
                action.widthAnchor.constraint(equalToConstant: 16),
                action.heightAnchor.constraint(equalToConstant: 16),
                age.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -10),
            ])
        } else {
            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
        }
        // project must stay clear of the age
        project.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -8).isActive = true

        widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // menu selection highlight on hover
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { highlighted = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent)  { highlighted = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5)
            r.fill()
        }
    }

    // clicking anywhere on the row (except the action button) opens the session
    override func mouseUp(with event: NSEvent) {
        _ = target?.perform(openSel, with: self)
    }

    // ---- helpers ----
    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font; l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func actionButton(symbol: String, tip: String, sel: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.title = ""
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            b.image = img
            b.imageScaling = .scaleProportionallyUpOrDown
            b.contentTintColor = .secondaryLabelColor
        } else {
            b.title = symbol == "checkmark.circle.fill" ? "✓" : "✕"
        }
        b.toolTip = tip
        b.tag = index
        b.target = target
        b.action = sel
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func shortAge(_ age: TimeInterval) -> String {
        let s = Int(age)
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

// Bottom-of-menu key: colored dot + one-word meaning, two per line.
final class LegendView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
        let pairs: [(NSColor, String)] = [
            (.systemYellow, "needs you"), (.systemBlue, "finished"),
            (.systemGreen, "working"),    (.tertiaryLabelColor, "idle"),
        ]
        // 2x2 grid so it stays compact
        let cols = 2
        for (i, pair) in pairs.enumerated() {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = pair.0.cgColor
            dot.layer?.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            addSubview(dot)

            let text = NSTextField(labelWithString: pair.1)
            text.font = .menuFont(ofSize: 11)
            text.textColor = .secondaryLabelColor
            text.translatesAutoresizingMaskIntoConstraints = false
            addSubview(text)

            let col = i % cols, rowN = i / cols
            let x = CGFloat(16 + col * 110)
            let y = CGFloat(rowN * 19)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: x),
                dot.topAnchor.constraint(equalTo: topAnchor, constant: y + 6),
                dot.widthAnchor.constraint(equalToConstant: 7),
                dot.heightAnchor.constraint(equalToConstant: 7),
                text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
                text.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            ])
        }
        widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        heightAnchor.constraint(equalToConstant: 46).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
