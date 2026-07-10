// Postit — a native macOS Liquid Glass post-it.
//
// A freeform text area on real Liquid Glass (macOS 26). Type anything; it
// auto-saves. Drag anywhere to move it, grab an edge/corner to resize. It
// layers like a normal window. Zero runtime dependencies — a real .app.

import Cocoa

// MARK: - Look & feel

private enum Style {
    static let windowSize    = NSSize(width: 320, height: 340)
    static let cornerRadius:  CGFloat = 26
    static let padding:       CGFloat = 14
    static let fontSize:      CGFloat = 15
    static let textColor      = NSColor(calibratedWhite: 0.97, alpha: 1.0)
    // Two tints: the calm look when idle, and a brighter one while focused to
    // counteract macOS dimming the glass on the active window.
    static let idleTint       = NSColor(calibratedWhite: 0.16, alpha: 0.18)
    static let focusedTint    = NSColor(calibratedWhite: 0.85, alpha: 0.12)
}

// MARK: - Persistence

/// Loads/saves the note to Application Support. Saves are debounced so a burst
/// of keystrokes writes to disk once, not once per character.
final class NoteStore {
    private let url: URL
    private var pending: DispatchWorkItem?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Postit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("note.txt")
    }

    func load() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// Coalesce rapid edits into a single write ~0.4s after typing stops.
    func scheduleSave(_ text: String) {
        pending?.cancel()
        let work = DispatchWorkItem { [url] in
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Flush immediately (on blur/close/quit) and drop any pending debounce.
    func saveNow(_ text: String) {
        pending?.cancel()
        pending = nil
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Window

/// Borderless panel that can take the keyboard without activating the app —
/// keeps macOS from re-emphasizing (dimming) the glass while you type.
final class GlassWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let store = NoteStore()
    private var window: GlassWindow!
    private var textView: NSTextView!
    private var glass: NSGlassEffectView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = GlassWindow(
            contentRect: NSRect(origin: .zero, size: Style.windowSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.isFloatingPanel = false            // layer like a normal window
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.level = .normal                     // on top only while focused
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false                   // kill the square shadow line
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        // ---- Liquid Glass base ----
        glass = NSGlassEffectView(frame: window.contentLayoutRect)
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = Style.cornerRadius
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.tintColor = Style.idleTint

        // ---- content riding on top of the glass ----
        let container = NSView(frame: glass.bounds)
        container.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: container.bounds.insetBy(dx: Style.padding, dy: Style.padding))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay

        textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.drawsBackground = false
        textView.textColor = Style.textColor
        textView.insertionPointColor = .white
        textView.font = NSFont.systemFont(ofSize: Style.fontSize)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        textView.string = store.load()
        scroll.documentView = textView
        container.addSubview(scroll)

        // small close button, top-right
        let close = NSButton(frame: NSRect(x: container.bounds.width - 26,
                                           y: container.bounds.height - 26,
                                           width: 18, height: 18))
        close.autoresizingMask = [.minXMargin, .minYMargin]
        close.title = "✕"
        close.isBordered = false
        close.font = NSFont.systemFont(ofSize: 12)
        close.contentTintColor = NSColor(calibratedWhite: 1.0, alpha: 0.55)
        close.target = self
        close.action = #selector(closeNote)
        container.addSubview(close)

        glass.contentView = container
        window.contentView = glass

        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        applyTint(focused: window.isKeyWindow)
    }

    private func applyTint(focused: Bool) {
        glass?.tintColor = focused ? Style.focusedTint : Style.idleTint
    }

    func windowDidBecomeKey(_ notification: Notification) { applyTint(focused: true) }

    func windowDidResignKey(_ notification: Notification) {
        applyTint(focused: false)
        store.saveNow(textView.string)             // flush when you click away
    }

    func textDidChange(_ notification: Notification) {
        store.scheduleSave(textView.string)        // debounced write
    }

    @objc func closeNote() {
        store.saveNow(textView.string)
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow(textView.string)
    }
}

// MARK: - Boot

/// Minimal menu so Cmd+Q / Cmd+X/C/V/A work in the text view.
private func makeMainMenu() -> NSMenu {
    let menu = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit Postit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
