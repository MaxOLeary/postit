// Postit — native macOS Liquid Glass post-its.
//
// Freeform text on real Liquid Glass (macOS 26). Type anything; it auto-saves.
// Drag anywhere to move, grab an edge/corner to resize. A top strip gives you
// a "+" to spawn another note, a stepper to size the font up/down, and a live
// size readout. Every note remembers its text, font size, and position across
// launches. A menu-bar item lists every saved note so you can reopen any of
// them at will. Zero runtime dependencies — a real .app.

import Cocoa

// MARK: - Look & feel

private enum Style {
    static let defaultSize   = NSSize(width: 320, height: 340)
    static let cornerRadius:  CGFloat = 26
    static let padding:       CGFloat = 14
    static let stripHeight:   CGFloat = 30
    static let defaultFont:   CGFloat = 15
    static let minFont:       CGFloat = 10
    static let maxFont:       CGFloat = 40
    static let textColor      = NSColor(calibratedWhite: 0.97, alpha: 1.0)
    static let chromeColor    = NSColor(calibratedWhite: 1.0, alpha: 0.55)
    // Two tints: the calm look when idle, and a brighter one while focused to
    // counteract macOS dimming the glass on the active window.
    static let idleTint       = NSColor(calibratedWhite: 0.16, alpha: 0.18)
    static let focusedTint    = NSColor(calibratedWhite: 0.85, alpha: 0.12)
}

// MARK: - Model

/// The saved state of one note. Codable so it round-trips to a small JSON file.
struct NoteData: Codable {
    var id: String
    var text: String            // plain fallback (legacy + human-readable backup)
    var rtf: String?            // base64 RTF: the real content, keeps per-range fonts
    var fontSize: CGFloat       // last-chosen size — default for new typing / new notes
    var frame: [CGFloat]        // [x, y, w, h] in screen coords; empty == "unset"

    init(id: String, text: String = "", rtf: String? = nil,
         fontSize: CGFloat = Style.defaultFont, frame: [CGFloat] = []) {
        self.id = id
        self.text = text
        self.rtf = rtf
        self.fontSize = fontSize
        self.frame = frame
    }

    /// The RTF payload decoded back to Data, if present.
    var rtfData: Data? { rtf.flatMap { Data(base64Encoded: $0) } }

    /// A short label for the menu-bar switcher: the first non-empty line,
    /// trimmed and capped. Empty notes read as "Untitled note".
    var displayTitle: String { NoteData.title(from: text) }

    static func title(from raw: String) -> String {
        let firstLine = raw.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Untitled note" }
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }
}

// MARK: - Persistence

/// Reads and writes note JSON files under Application Support/Postit/notes.
/// One file per note (`<uuid>.json`). Saves are debounced so a burst of
/// keystrokes writes to disk once, not once per character.
final class NoteStore {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let d = base.appendingPathComponent("Postit/notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Load every saved note, oldest file first (stable, creation-ordered).
    static func loadAll() -> [NoteData] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        let jsons = urls.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return a < b
        }
        return jsons.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(NoteData.self, from: data)
        }
    }

    /// The single "main" note to restore on launch: the one edited most
    /// recently. A reload brings back just that one window instead of every
    /// note ever created — the others stay saved on disk (nothing is deleted),
    /// they just aren't reopened. Returns nil if there are no saved notes.
    static func loadMostRecent() -> NoteData? {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let jsons = urls.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b   // newest first
        }
        for url in jsons {
            if let data = try? Data(contentsOf: url),
               let note = try? JSONDecoder().decode(NoteData.self, from: data) {
                return note
            }
        }
        return nil
    }

    /// Load one saved note by id (used by the switcher to reopen a closed note).
    static func load(id: String) -> NoteData? {
        let url = dir.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NoteData.self, from: data)
    }

    /// One-time import of the pre-multi-note single file (Postit/note.txt).
    /// Returns a note if that file exists with real content, and writes it out
    /// as a proper JSON note so it becomes permanent. The original note.txt is
    /// left in place as a backup — nothing is deleted.
    static func migrateLegacyNote() -> NoteData? {
        let legacy = dir.deletingLastPathComponent().appendingPathComponent("note.txt")
        guard let text = try? String(contentsOf: legacy, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let note = NoteData(id: UUID().uuidString, text: text)
        NoteStore(id: note.id).saveNow(note)
        return note
    }

    private let url: URL
    private var pending: DispatchWorkItem?

    init(id: String) { url = NoteStore.dir.appendingPathComponent("\(id).json") }

    /// Coalesce rapid edits into a single write ~0.4s after activity stops.
    func scheduleSave(_ note: NoteData) {
        pending?.cancel()
        let work = DispatchWorkItem { [url] in
            if let data = try? JSONEncoder().encode(note) {
                try? data.write(to: url, options: .atomic)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Flush immediately (on blur/close/quit) and drop any pending debounce.
    func saveNow(_ note: NoteData) {
        pending?.cancel()
        pending = nil
        if let data = try? JSONEncoder().encode(note) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Remove the file (used when an empty note is closed).
    func delete() {
        pending?.cancel()
        pending = nil
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Window

/// Borderless panel that can take the keyboard without activating the app —
/// keeps macOS from re-emphasizing (dimming) the glass while you type.
final class GlassWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - One note

/// Owns a single post-it window: the glass, the text view, the top-strip
/// controls, and its persistence. Reports lifecycle back to the manager.
final class NoteController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    let id: String
    private weak var manager: NotesManager?
    private let store: NoteStore

    private var window: GlassWindow!
    private var textView: NSTextView!
    private var glass: NSGlassEffectView!
    private var sizeLabel: NSTextField!
    private var fontSize: CGFloat
    // The size new typing should use right now. We enforce it on every edit
    // because AppKit likes to reset typing attributes to the surrounding text.
    private var currentFont = NSFont.systemFont(ofSize: Style.defaultFont)

    init(data: NoteData, manager: NotesManager) {
        self.id = data.id
        self.manager = manager
        self.store = NoteStore(id: data.id)
        self.fontSize = min(max(data.fontSize, Style.minFont), Style.maxFont)
        super.init()
        build(with: data)
    }

    var windowRef: NSWindow { window }

    private func build(with data: NoteData) {
        let size = Style.defaultSize
        window = GlassWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.level = .normal
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)

        // ---- Liquid Glass base ----
        glass = NSGlassEffectView(frame: window.contentLayoutRect)
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = Style.cornerRadius
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.tintColor = Style.idleTint

        let container = NSView(frame: glass.bounds)
        container.autoresizingMask = [.width, .height]

        // ---- top strip (controls float above the text) ----
        let strip = NSView(frame: NSRect(x: 0, y: container.bounds.height - Style.stripHeight,
                                         width: container.bounds.width, height: Style.stripHeight))
        strip.autoresizingMask = [.width, .minYMargin]

        // "+" new note, top-left
        let plus = chromeButton("+", size: 20, fontSize: 18)
        plus.frame = NSRect(x: 8, y: (Style.stripHeight - 20) / 2, width: 20, height: 20)
        plus.autoresizingMask = [.maxXMargin, .minYMargin]
        plus.target = self
        plus.action = #selector(newNote)
        plus.toolTip = "New note"
        strip.addSubview(plus)

        // font size: two bare chevrons (no bezel), up = bigger, down = smaller
        let up = chevronButton("chevron.up", action: #selector(fontUp))
        up.frame = NSRect(x: 33, y: Style.stripHeight / 2 - 1, width: 15, height: 11)
        up.autoresizingMask = [.maxXMargin, .minYMargin]
        up.toolTip = "Bigger"
        strip.addSubview(up)

        let down = chevronButton("chevron.down", action: #selector(fontDown))
        down.frame = NSRect(x: 33, y: Style.stripHeight / 2 - 10, width: 15, height: 11)
        down.autoresizingMask = [.maxXMargin, .minYMargin]
        down.toolTip = "Smaller"
        strip.addSubview(down)

        // size readout
        sizeLabel = NSTextField(labelWithString: "\(Int(fontSize))")
        sizeLabel.frame = NSRect(x: 54, y: (Style.stripHeight - 16) / 2, width: 26, height: 16)
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = Style.chromeColor
        sizeLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        sizeLabel.toolTip = "Current font size"
        strip.addSubview(sizeLabel)

        // "✕" close, top-right
        let close = chromeButton("✕", size: 18, fontSize: 12)
        close.frame = NSRect(x: strip.bounds.width - 26, y: (Style.stripHeight - 18) / 2,
                             width: 18, height: 18)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        close.target = self
        close.action = #selector(closeNote)
        close.toolTip = "Close note"
        strip.addSubview(close)

        container.addSubview(strip)

        // ---- text area below the strip ----
        let textRect = NSRect(x: Style.padding, y: Style.padding,
                              width: container.bounds.width - Style.padding * 2,
                              height: container.bounds.height - Style.stripHeight - Style.padding)
        let scroll = NSScrollView(frame: textRect)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay

        textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isRichText = true                 // per-range fonts, not one global font
        textView.allowsUndo = true                 // Cmd+Z / Cmd+Shift+Z for typing & deletes
        textView.drawsBackground = false
        textView.textColor = Style.textColor
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self

        let baseFont = NSFont.systemFont(ofSize: fontSize)
        currentFont = baseFont
        textView.font = baseFont
        textView.typingAttributes = [.font: baseFont, .foregroundColor: Style.textColor]
        if let rtfData = data.rtfData,
           let attr = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attr)   // restores per-range sizes
        } else if !data.text.isEmpty {
            // legacy/plain content: lay it down in the default style
            textView.string = data.text
            let whole = NSRange(location: 0, length: (data.text as NSString).length)
            textView.textStorage?.addAttribute(.font, value: baseFont, range: whole)
            textView.textStorage?.addAttribute(.foregroundColor, value: Style.textColor, range: whole)
        }
        scroll.documentView = textView
        container.addSubview(scroll)

        glass.contentView = container
        window.contentView = glass
        window.delegate = self

        // position: restore saved frame, else center
        if data.frame.count == 4 {
            window.setFrame(NSRect(x: data.frame[0], y: data.frame[1],
                                   width: data.frame[2], height: data.frame[3]), display: false)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        applyTint(focused: window.isKeyWindow)
    }

    /// A borderless text button styled like the existing subtle "✕".
    private func chromeButton(_ title: String, size: CGFloat, fontSize: CGFloat) -> NSButton {
        let b = NSButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        b.title = title
        b.isBordered = false
        b.font = NSFont.systemFont(ofSize: fontSize)
        b.contentTintColor = Style.chromeColor
        b.setButtonType(.momentaryChange)
        b.refusesFirstResponder = true             // don't steal focus from the text
        return b
    }

    /// A borderless SF Symbol chevron button — just the glyph, no bezel.
    private func chevronButton(_ symbol: String, action: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyDown
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        b.contentTintColor = Style.chromeColor
        b.setButtonType(.momentaryChange)
        b.refusesFirstResponder = true
        b.target = self
        b.action = action
        return b
    }

    // ---- state → NoteData ----
    private func snapshot() -> NoteData {
        let f = window.frame
        var rtf: String?
        if let ts = textView.textStorage {
            let whole = NSRange(location: 0, length: ts.length)
            rtf = ts.rtf(from: whole, documentAttributes: [:])?.base64EncodedString()
        }
        return NoteData(id: id, text: textView.string, rtf: rtf, fontSize: fontSize,
                        frame: [f.origin.x, f.origin.y, f.size.width, f.size.height])
    }

    private func applyTint(focused: Bool) {
        glass?.tintColor = focused ? Style.focusedTint : Style.idleTint
    }

    // ---- actions ----
    @objc private func newNote() { manager?.newNote() }

    @objc private func fontUp()   { changeFont(by: +1) }
    @objc private func fontDown() { changeFont(by: -1) }

    private func changeFont(by delta: CGFloat) {
        let newSize = min(max(fontSize + delta, Style.minFont), Style.maxFont)
        guard newSize != fontSize else { return }
        fontSize = newSize
        sizeLabel.stringValue = "\(Int(newSize))"
        currentFont = NSFont.systemFont(ofSize: newSize)

        let range = textView.selectedRange()
        if range.length > 0 {
            // resize just the highlighted text
            textView.textStorage?.addAttribute(.font, value: currentFont, range: range)
        }
        // and make whatever you type next use this size (the "cursor" case)
        textView.typingAttributes[.font] = currentFont
        store.scheduleSave(snapshot())
    }

    @objc private func closeNote() { window.close() }

    var isEmpty: Bool { textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Live title for the switcher — reflects unsaved typing, not just disk.
    var displayTitle: String { NoteData.title(from: textView.string) }

    /// Bring this note's window forward and give it the keyboard.
    func focus() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)
    }

    // ---- text delegate ----
    func textDidChange(_ notification: Notification) { store.scheduleSave(snapshot()) }

    /// Force every edit to use the chosen size. AppKit resets the text view's
    /// typing attributes to the surrounding text after each keystroke, which is
    /// what made a bumped-up size silently fall back — this defeats that.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        textView.typingAttributes[.font] = currentFont
        return true
    }

    /// Track the size at the cursor/selection so `currentFont`, the stepper, and
    /// the readout all reflect what you're editing (click into 15pt text → type
    /// 15pt; bump to 17 → keep typing 17).
    func textViewDidChangeSelection(_ notification: Notification) {
        let sel = textView.selectedRange()
        guard let ts = textView.textStorage else { return }
        var font: NSFont?
        if sel.length > 0, ts.length > 0 {
            font = ts.attribute(.font, at: min(sel.location, ts.length - 1),
                                effectiveRange: nil) as? NSFont
        } else if sel.location > 0, ts.length > 0 {
            font = ts.attribute(.font, at: min(sel.location - 1, ts.length - 1),
                                effectiveRange: nil) as? NSFont
        } else {
            font = textView.typingAttributes[.font] as? NSFont
        }
        guard let f = font else { return }
        currentFont = f
        fontSize = f.pointSize
        sizeLabel.stringValue = "\(Int(round(f.pointSize)))"
    }

    // ---- window delegate ----
    func windowDidBecomeKey(_ notification: Notification) { applyTint(focused: true) }

    func windowDidResignKey(_ notification: Notification) {
        applyTint(focused: false)
        store.saveNow(snapshot())
    }

    func windowDidMove(_ notification: Notification)   { store.scheduleSave(snapshot()) }
    func windowDidResize(_ notification: Notification) { store.scheduleSave(snapshot()) }

    func windowWillClose(_ notification: Notification) {
        // An empty note leaves no trace; a real one is flushed to disk.
        if isEmpty { store.delete() } else { store.saveNow(snapshot()) }
        manager?.controllerDidClose(self)
    }

    /// Called on app quit — flush without deleting empties (avoids surprise
    /// data loss; a still-empty note just reopens empty next launch).
    func flush() { store.saveNow(snapshot()) }
}

// MARK: - Manager

/// Owns all open notes. Restores the main note on launch, spawns new ones, and
/// puts a menu-bar switcher up so any saved note can be reopened. The app is a
/// menu-bar resident: closing every window leaves the switcher, not a quit.
final class NotesManager: NSObject, NSMenuDelegate {
    private var controllers: [NoteController] = []
    private var statusItem: NSStatusItem?

    func start() {
        setupStatusItem()

        // Restore only the main note (most recently edited) so a reload opens a
        // single window. Other saved notes stay on disk and are reachable from
        // the menu-bar switcher; the "+" button still spawns more.
        if let main = NoteStore.loadMostRecent() {
            open(main)
        } else if let migrated = NoteStore.migrateLegacyNote() {
            open(migrated)                          // one-time import of old note.txt
        } else {
            newNote()
        }
    }

    // MARK: menu-bar switcher

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "note.text",
                                   accessibilityDescription: "Postit")
            button.image?.isTemplate = true
            button.toolTip = "Postit notes"
        }
        let menu = NSMenu()
        menu.delegate = self                        // rebuilt every time it opens
        item.menu = menu
        statusItem = item
    }

    /// Rebuild the switcher menu from disk each time it's opened so it always
    /// reflects the current set of saved notes and which ones are open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let saved = NoteStore.loadAll()
        let openByID = Dictionary(controllers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        if saved.isEmpty {
            let empty = NSMenuItem(title: "No saved notes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for note in saved {
                // Prefer the live (possibly unsaved) title for open notes.
                let title = openByID[note.id]?.displayTitle ?? note.displayTitle
                let mi = NSMenuItem(title: title, action: #selector(switchToNote(_:)),
                                    keyEquivalent: "")
                mi.target = self
                mi.representedObject = note.id
                mi.state = openByID[note.id] != nil ? .on : .off   // ✓ = currently open
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        let newItem = NSMenuItem(title: "New Note", action: #selector(makeNewNote),
                                 keyEquivalent: "n")
        newItem.target = self
        menu.addItem(newItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Postit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    /// Front an already-open note, or load it from disk and open it.
    @objc private func switchToNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let existing = controllers.first(where: { $0.id == id }) {
            existing.focus()
        } else if let data = NoteStore.load(id: id) {
            let c = open(data)
            c.focus()
        }
    }

    @objc private func makeNewNote() { newNote() }

    @discardableResult
    private func open(_ data: NoteData) -> NoteController {
        let c = NoteController(data: data, manager: self)
        controllers.append(c)
        return c
    }

    func newNote() {
        var data = NoteData(id: UUID().uuidString)
        // Cascade off the frontmost note so a new one isn't hidden behind it.
        if let front = controllers.last {
            let f = front.windowRef.frame
            data.frame = [f.origin.x + 26, f.origin.y - 26, f.size.width, f.size.height]
        }
        let c = open(data)
        c.windowRef.makeKeyAndOrderFront(nil)
    }

    func controllerDidClose(_ c: NoteController) {
        controllers.removeAll { $0 === c }
        // No terminate on empty: the app lives in the menu bar so a closed note
        // can be reopened from the switcher. Quit via that menu or Cmd+Q.
    }

    func flushAll() { controllers.forEach { $0.flush() } }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notes = NotesManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        notes.start()
    }

    /// Cmd+N from the main menu (reaches here via the responder chain).
    @objc func newNote(_ sender: Any?) { notes.newNote() }

    func applicationWillTerminate(_ notification: Notification) {
        notes.flushAll()
    }
}

// MARK: - Boot

/// Minimal menu so Cmd+Q / Cmd+X/C/V/A / Cmd+W work in the text view.
private func makeMainMenu() -> NSMenu {
    let menu = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    // nil target → travels the responder chain to the app delegate.
    appMenu.addItem(withTitle: "New Note", action: #selector(AppDelegate.newNote(_:)), keyEquivalent: "n")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Postit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Close",      action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    editItem.submenu = editMenu
    menu.addItem(editItem)

    return menu
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no app-switcher tile
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = makeMainMenu()
app.run()
