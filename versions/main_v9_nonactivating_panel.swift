// Postit — a native macOS Liquid Glass post-it.
//
// A freeform text area on real Liquid Glass (macOS 26). Type anything; it
// auto-saves. Drag anywhere to move it, grab an edge/corner to resize, and it
// floats above other windows. Zero runtime dependencies — it's a real .app.

import Cocoa

// MARK: - Persistence

final class NoteStore {
    let url: URL
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Postit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("note.txt")
    }
    func load() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func save(_ text: String) { try? text.write(to: url, atomically: true, encoding: .utf8) }
}

// MARK: - A borderless floating panel that can take the keyboard without
// activating the app — this keeps macOS from applying the "active window"
// glass emphasis (the dimming) while you type.

final class GlassWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let store = NoteStore()
    var window: GlassWindow!
    var textView: NSTextView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let radius: CGFloat = 26

        window = GlassWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 340),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.level = .floating                 // always on top
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false                 // kill the square shadow line
        // keep a consistent dark glass whether or not it's the active window
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        // ---- Liquid Glass base ----
        let glass = NSGlassEffectView(frame: window.contentLayoutRect)
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = radius
        glass.appearance = NSAppearance(named: .darkAqua)
        // neutral graphite tint — no color to "light up" when the window is focused
        glass.tintColor = NSColor(calibratedWhite: 0.16, alpha: 0.18)

        // ---- content that rides on top of the glass ----
        let container = NSView(frame: glass.bounds)
        container.autoresizingMask = [.width, .height]

        // text area (scrollable)
        let scroll = NSScrollView(frame: container.bounds.insetBy(dx: 14, dy: 14))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay

        textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.drawsBackground = false
        textView.textColor = NSColor(calibratedWhite: 0.97, alpha: 1.0)
        textView.insertionPointColor = .white
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        textView.string = store.load()
        scroll.documentView = textView
        container.addSubview(scroll)

        // small close button, top-right
        let close = NSButton(frame: NSRect(x: container.bounds.width - 26, y: container.bounds.height - 26, width: 18, height: 18))
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

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    // auto-save on every edit
    func textDidChange(_ notification: Notification) {
        store.save(textView.string)
    }

    @objc func closeNote() {
        store.save(textView.string)
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save(textView.string)
    }
}

// MARK: - Boot

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate

// minimal menu so Cmd+Q / Cmd+W / Cmd+C/V work
let menu = NSMenu()
let appItem = NSMenuItem()
menu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Postit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
let editItem = NSMenuItem()
menu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
app.mainMenu = menu

app.run()
