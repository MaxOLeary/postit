// Postit — native macOS Liquid Glass post-its.
//
// Freeform text on real Liquid Glass (macOS 26). Type anything; it auto-saves.
// A note's body is a stack of blocks: freeform text plus collapsible sections
// (Obsidian-style folds) added from the toolbar's ◂ triangle. Drag anywhere to
// move, grab an edge/corner to resize. The top strip gives you a "+" to spawn
// another note, a font stepper with a live size readout, the ◂ add-section
// button, and a ☰ switcher. Every note remembers its blocks, font size, and
// position across launches. A menu-bar item lists every saved note so you can
// reopen (or delete) any of them. Zero runtime dependencies — a real .app.

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

/// One piece of a note's body. A note is an ordered list of these: freeform
/// `text` runs interleaved with collapsible `section`s (title + foldable body),
/// Obsidian-style. Codable so the whole note round-trips to JSON.
struct Block: Codable {
    enum Kind: String, Codable { case text, section }
    var kind: Kind
    var rtf: String?        // base64 RTF of the body (text block or section body)
    var text: String        // plain fallback of the body
    var title: String       // section header (ignored for text blocks)
    var collapsed: Bool     // section fold state (ignored for text blocks)

    init(kind: Kind, rtf: String? = nil, text: String = "",
         title: String = "", collapsed: Bool = false) {
        self.kind = kind
        self.rtf = rtf
        self.text = text
        self.title = title
        self.collapsed = collapsed
    }

    var rtfData: Data? { rtf.flatMap { Data(base64Encoded: $0) } }
}

/// The saved state of one note. Codable so it round-trips to a small JSON file.
struct NoteData: Codable {
    var id: String
    var text: String            // switcher summary + legacy plain fallback
    var rtf: String?            // legacy single-body RTF (first text block, for old readers)
    var fontSize: CGFloat       // last-chosen size — default for new typing / new notes
    var frame: [CGFloat]        // [x, y, w, h] in screen coords; empty == "unset"
    var blocks: [Block]?        // the block content model; nil on legacy notes

    init(id: String, text: String = "", rtf: String? = nil,
         fontSize: CGFloat = Style.defaultFont, frame: [CGFloat] = [],
         blocks: [Block]? = nil) {
        self.id = id
        self.text = text
        self.rtf = rtf
        self.fontSize = fontSize
        self.frame = frame
        self.blocks = blocks
    }

    /// The RTF payload decoded back to Data, if present.
    var rtfData: Data? { rtf.flatMap { Data(base64Encoded: $0) } }

    /// Blocks to build the note from — migrating a legacy single-body note into
    /// one text block so nothing that predates the block model is lost.
    var resolvedBlocks: [Block] {
        if let b = blocks, !b.isEmpty { return b }
        return [Block(kind: .text, rtf: rtf, text: text)]
    }

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

// MARK: - Block views

/// A vertical stack whose top-left is the origin, so it reads top-down as the
/// document view of a scroll view.
final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// An NSTextView that sizes its own height to its content, so several can be
/// stacked in a scroll view (one per block) instead of each owning a scroller.
final class GrowingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 20)
        }
        lm.ensureLayout(for: tc)
        let h = ceil(lm.usedRect(for: tc).height) + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: max(h, 20))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)          // width changed → reflow → new height
        invalidateIntrinsicContentSize()
    }

    /// Build a text view configured for auto-height inside an autolayout stack.
    static func make(delegate: NSTextViewDelegate, fontSize: CGFloat) -> GrowingTextView {
        let tv = GrowingTextView(frame: .zero)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textColor = Style.textColor
        tv.insertionPointColor = .white
        tv.textContainerInset = NSSize(width: 2, height: 4)
        // Explicit selection fill. The system highlight assumes an opaque
        // backing and leaves thin blue line artifacts on the transparent glass;
        // a plain translucent color composites cleanly instead.
        tv.selectedTextAttributes = [
            .backgroundColor: NSColor(calibratedRed: 0.36, green: 0.52, blue: 0.92, alpha: 0.40)
        ]
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.size = NSSize(width: 0, height: 10_000_000)
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        let f = NSFont.systemFont(ofSize: fontSize)
        tv.font = f
        tv.typingAttributes = [.font: f, .foregroundColor: Style.textColor]
        tv.delegate = delegate
        return tv
    }

    /// Load a block's saved content (RTF if present, else plain text).
    func load(rtfData: Data?, plain: String, fontSize: CGFloat) {
        let base = NSFont.systemFont(ofSize: fontSize)
        if let d = rtfData, let attr = NSAttributedString(rtf: d, documentAttributes: nil) {
            textStorage?.setAttributedString(attr)
        } else if !plain.isEmpty {
            string = plain
            let whole = NSRange(location: 0, length: (plain as NSString).length)
            textStorage?.addAttribute(.font, value: base, range: whole)
            textStorage?.addAttribute(.foregroundColor, value: Style.textColor, range: whole)
        }
        invalidateIntrinsicContentSize()
    }

    /// The current content as base64 RTF (keeps per-range fonts).
    var rtfBase64: String? {
        guard let ts = textStorage else { return nil }
        return ts.rtf(from: NSRange(location: 0, length: ts.length),
                      documentAttributes: [:])?.base64EncodedString()
    }

    /// Paste as plain text restyled to the note's look — so text copied from a
    /// browser or another app doesn't drag in black text or a foreign font.
    /// Keeps the size/font at the cursor and forces the note's white color.
    override func paste(_ sender: Any?) {
        guard let plain = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        let font = (typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: Style.defaultFont)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Style.textColor]
        let styled = NSAttributedString(string: plain, attributes: attrs)
        let range = selectedRange()
        if shouldChangeText(in: range, replacementString: plain) {
            textStorage?.replaceCharacters(in: range, with: styled)
            setSelectedRange(NSRange(location: range.location + styled.length, length: 0))
            didChangeText()
        }
    }
}

/// A collapsible section: a disclosure header with an editable title and a
/// delete button, over a foldable rich-text body. Like an Obsidian fold.
final class SectionView: NSView, NSTextFieldDelegate {
    let body: GrowingTextView
    private let disclosure = NSButton()
    private let titleField = NSTextField()
    private var collapsed: Bool
    private let onChange: () -> Void
    private let onDelete: () -> Void

    var title: String { titleField.stringValue }

    init(block: Block, fontSize: CGFloat, textDelegate: NSTextViewDelegate,
         onChange: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.body = GrowingTextView.make(delegate: textDelegate, fontSize: fontSize)
        self.collapsed = block.collapsed
        self.onChange = onChange
        self.onDelete = onDelete
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(block: block, fontSize: fontSize)
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    private func build(block: Block, fontSize: CGFloat) {
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.setButtonType(.momentaryChange)
        disclosure.refusesFirstResponder = true
        disclosure.contentTintColor = Style.chromeColor
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.setContentHuggingPriority(.required, for: .horizontal)
        updateDisclosureImage()

        titleField.stringValue = block.title
        titleField.placeholderString = "Section title"
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.textColor = Style.textColor
        titleField.font = NSFont.systemFont(ofSize: max(fontSize, 13), weight: .semibold)
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.delegate = self
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let del = NSButton()
        del.isBordered = false
        del.imagePosition = .imageOnly
        del.setButtonType(.momentaryChange)
        del.refusesFirstResponder = true
        del.contentTintColor = Style.chromeColor
        del.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete section")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        del.target = self
        del.action = #selector(deleteTapped)
        del.toolTip = "Delete section"
        del.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [disclosure, titleField, del])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        body.load(rtfData: block.rtfData, plain: block.text, fontSize: fontSize)
        body.textContainerInset = NSSize(width: 16, height: 4)   // indent under the header

        let vstack = FlippedStack(views: [header, body])
        vstack.orientation = .vertical
        vstack.spacing = 3
        vstack.alignment = .leading
        vstack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vstack)
        NSLayoutConstraint.activate([
            vstack.leadingAnchor.constraint(equalTo: leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: trailingAnchor),
            vstack.topAnchor.constraint(equalTo: topAnchor),
            vstack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: vstack.widthAnchor),
            body.widthAnchor.constraint(equalTo: vstack.widthAnchor),
        ])
        body.isHidden = collapsed
    }

    @objc private func toggle() {
        collapsed.toggle()
        body.isHidden = collapsed
        updateDisclosureImage()
        onChange()
    }

    @objc private func deleteTapped() { onDelete() }

    private func updateDisclosureImage() {
        let name = collapsed ? "chevron.right" : "chevron.down"
        disclosure.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
    }

    func controlTextDidChange(_ obj: Notification) { onChange() }

    /// True if `tv` is this section's body (used to locate the active block).
    func contains(_ tv: NSTextView) -> Bool { tv === body }

    /// Move keyboard focus into the title field (after inserting a new section).
    func focusTitle() { window?.makeFirstResponder(titleField) }

    /// Serialize back to a Block for saving.
    func asBlock() -> Block {
        Block(kind: .section, rtf: body.rtfBase64, text: body.string,
              title: titleField.stringValue, collapsed: collapsed)
    }
}

// MARK: - One note

/// Owns a single post-it window: the glass, the text view, the top-strip
/// controls, and its persistence. Reports lifecycle back to the manager.
final class NoteController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    let id: String
    private weak var manager: NotesManager?
    private let store: NoteStore

    private var window: GlassWindow!
    private var glass: NSGlassEffectView!
    private var sizeLabel: NSTextField!
    // The note body: a scroll view whose document is a vertical stack of block
    // views (GrowingTextView for freeform text, SectionView for folds).
    private var scroll: NSScrollView!
    private var contentStack: FlippedStack!
    // The text view the user is currently editing — font changes target it.
    private weak var activeText: NSTextView?
    private var fontSize: CGFloat
    // The size new typing should use right now. We enforce it on every edit
    // because AppKit likes to reset typing attributes to the surrounding text.
    private var currentFont = NSFont.systemFont(ofSize: Style.defaultFont)
    // Set when the note is being deleted so windowWillClose skips the save.
    private var discarding = false

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

        // size readout — snug against the chevrons so the stepper reads as one control
        sizeLabel = NSTextField(labelWithString: "\(Int(fontSize))")
        sizeLabel.frame = NSRect(x: 49, y: (Style.stripHeight - 16) / 2, width: 26, height: 16)
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = Style.chromeColor
        sizeLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        sizeLabel.toolTip = "Current font size"
        strip.addSubview(sizeLabel)

        // insert-section — a right-facing chevron that splits the text at the
        // cursor and drops a collapsible section (title + foldable body) there.
        let sectionBtn = symbolButton("chevron.right", point: 12,
                                      action: #selector(insertSection))
        sectionBtn.frame = NSRect(x: 80, y: (Style.stripHeight - 16) / 2, width: 16, height: 16)
        sectionBtn.autoresizingMask = [.maxXMargin, .minYMargin]
        sectionBtn.toolTip = "Add a collapsible section at the cursor"
        strip.addSubview(sectionBtn)

        // switcher dropdown — same note list as the menu-bar item, anchored just
        // left of the close button so both live top-right.
        let switcher = symbolButton("list.bullet", point: 12, action: #selector(showSwitcher(_:)))
        switcher.frame = NSRect(x: strip.bounds.width - 50, y: (Style.stripHeight - 18) / 2,
                                width: 18, height: 18)
        switcher.autoresizingMask = [.minXMargin, .minYMargin]
        switcher.toolTip = "Switch to another note"
        strip.addSubview(switcher)

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

        // ---- scrollable block stack below the strip ----
        let contentRect = NSRect(x: Style.padding, y: Style.padding,
                                 width: container.bounds.width - Style.padding * 2,
                                 height: container.bounds.height - Style.stripHeight - Style.padding)
        scroll = NSScrollView(frame: contentRect)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay

        contentStack = FlippedStack()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = contentStack
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: clip.topAnchor),
            contentStack.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        container.addSubview(scroll)

        currentFont = NSFont.systemFont(ofSize: fontSize)
        for block in data.resolvedBlocks {
            switch block.kind {
            case .text:    appendBlockView(makeTextView(from: block))
            case .section: appendBlockView(makeSectionView(from: block))
            }
        }
        if contentStack.arrangedSubviews.isEmpty {
            appendBlockView(makeTextView(from: Block(kind: .text)))
        }

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
        if let first = firstTextView() {
            window.makeFirstResponder(first)
            activeText = first
        }
        applyTint(focused: window.isKeyWindow)
    }

    // ---- block management ----

    private func makeTextView(from block: Block) -> GrowingTextView {
        let tv = GrowingTextView.make(delegate: self, fontSize: fontSize)
        tv.load(rtfData: block.rtfData, plain: block.text, fontSize: fontSize)
        return tv
    }

    private func makeSectionView(from block: Block) -> SectionView {
        var ref: SectionView!
        let sv = SectionView(block: block, fontSize: fontSize, textDelegate: self,
                             onChange: { [weak self] in self?.saveDebounced() },
                             onDelete: { [weak self] in self?.removeSection(ref) })
        ref = sv
        return sv
    }

    private func appendBlockView(_ v: NSView) {
        contentStack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func insertBlockView(_ v: NSView, at index: Int) {
        contentStack.insertArrangedSubview(v, at: index)
        v.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func removeSection(_ v: SectionView?) {
        guard let v = v else { return }
        if let at = activeText, v.contains(at) { activeText = nil }
        contentStack.removeArrangedSubview(v)
        v.removeFromSuperview()
        if contentStack.arrangedSubviews.isEmpty {
            appendBlockView(makeTextView(from: Block(kind: .text)))
        }
        saveDebounced()
    }

    /// Index of the block currently being edited (so a new section lands right
    /// after it). Falls back to the last block.
    private func activeBlockIndex() -> Int {
        let arranged = contentStack.arrangedSubviews
        if let at = activeText {
            for (i, v) in arranged.enumerated() {
                if v === at { return i }
                if let s = v as? SectionView, s.contains(at) { return i }
            }
        }
        return max(arranged.count - 1, 0)
    }

    private func firstTextView() -> NSTextView? {
        for v in contentStack.arrangedSubviews {
            if let tv = v as? GrowingTextView { return tv }
            if let s = v as? SectionView { return s.body }
        }
        return nil
    }

    /// The switcher summary: first section title or first non-empty text line.
    private func currentSummary() -> String {
        for v in contentStack.arrangedSubviews {
            if let s = v as? SectionView {
                let t = s.title.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { return t }
                let b = s.body.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !b.isEmpty { return b }
            } else if let tv = v as? GrowingTextView {
                let t = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return ""
    }

    private func saveDebounced() { store.scheduleSave(snapshot()) }

    @objc private func insertSection() {
        let arranged = contentStack.arrangedSubviews
        // Cursor is in a top-level text block → split it at the cursor so the
        // new section lands exactly where you are, and text after the cursor
        // moves into a fresh text block just below it.
        if let tv = activeText as? GrowingTextView, let idx = arranged.firstIndex(of: tv) {
            splitAndInsertSection(in: tv, at: idx)
            return
        }
        // Cursor is in a section body (or nowhere) → insert right after that
        // block, then ensure a trailing text block to keep typing.
        let index = min(activeBlockIndex() + 1, arranged.count)
        let sv = makeSectionView(from: Block(kind: .section))
        insertBlockView(sv, at: index)
        if index == contentStack.arrangedSubviews.count - 1 {
            appendBlockView(makeTextView(from: Block(kind: .text)))
        }
        sv.focusTitle()
        saveDebounced()
    }

    /// Split `tv` at the cursor: keep the text before it, insert a new section
    /// after it, and move any text after the cursor into a new text block below.
    private func splitAndInsertSection(in tv: GrowingTextView, at index: Int) {
        let afterAttr: NSAttributedString
        if let ts = tv.textStorage {
            let loc = min(tv.selectedRange().location, ts.length)
            let afterRange = NSRange(location: loc, length: ts.length - loc)
            afterAttr = ts.attributedSubstring(from: afterRange)
            if afterRange.length > 0 {
                ts.deleteCharacters(in: afterRange)   // trim to text before cursor
                tv.invalidateIntrinsicContentSize()
            }
        } else {
            afterAttr = NSAttributedString(string: "")
        }

        let sv = makeSectionView(from: Block(kind: .section))
        insertBlockView(sv, at: index + 1)

        // A text block below the section: carries the after-cursor text (or is
        // empty, giving you a fresh line to type under the fold).
        let afterView = GrowingTextView.make(delegate: self, fontSize: fontSize)
        if afterAttr.length > 0 {
            afterView.textStorage?.setAttributedString(afterAttr)
            afterView.invalidateIntrinsicContentSize()
        }
        insertBlockView(afterView, at: index + 2)

        sv.focusTitle()
        saveDebounced()
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
        symbolButton(symbol, point: 9, action: action)
    }

    /// A borderless SF Symbol button — just the glyph, no bezel, sized to taste.
    private func symbolButton(_ symbol: String, point: CGFloat, action: Selector) -> NSButton {
        let b = NSButton(frame: .zero)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyDown
        let cfg = NSImage.SymbolConfiguration(pointSize: point, weight: .semibold)
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
        var blocks: [Block] = []
        for v in contentStack.arrangedSubviews {
            if let tv = v as? GrowingTextView {
                blocks.append(Block(kind: .text, rtf: tv.rtfBase64, text: tv.string))
            } else if let s = v as? SectionView {
                blocks.append(s.asBlock())
            }
        }
        // Keep the first text block's RTF in the legacy field so older readers
        // still show something; `text` carries the switcher summary.
        let firstRtf = blocks.first(where: { $0.kind == .text })?.rtf
        return NoteData(id: id, text: currentSummary(), rtf: firstRtf, fontSize: fontSize,
                        frame: [f.origin.x, f.origin.y, f.size.width, f.size.height],
                        blocks: blocks)
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

        guard let tv = activeText ?? firstTextView() else { saveDebounced(); return }
        let range = tv.selectedRange()
        if range.length > 0 {
            // resize just the highlighted text in the active block
            tv.textStorage?.addAttribute(.font, value: currentFont, range: range)
        }
        // and make whatever you type next use this size (the "cursor" case)
        tv.typingAttributes[.font] = currentFont
        saveDebounced()
    }

    @objc private func closeNote() { window.close() }

    /// Pop the shared switcher menu down from the toolbar button.
    @objc private func showSwitcher(_ sender: NSButton) {
        guard let menu = manager?.makeSwitcherMenu() else { return }
        // Drop it just below the button (button coords are bottom-left origin).
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: -4),
                   in: sender)
    }

    /// True when nothing has been typed in any block (no text, no section title).
    var isEmpty: Bool {
        for v in contentStack.arrangedSubviews {
            if let tv = v as? GrowingTextView,
               !tv.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            if let s = v as? SectionView {
                if !s.title.trimmingCharacters(in: .whitespaces).isEmpty { return false }
                if !s.body.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            }
        }
        return true
    }

    /// Live title for the switcher — reflects unsaved typing, not just disk.
    var displayTitle: String { NoteData.title(from: currentSummary()) }

    /// Bring this note's window forward and give it the keyboard.
    func focus() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let tv = activeText ?? firstTextView() { window.makeFirstResponder(tv) }
    }

    // ---- text delegate (shared by every block's text view) ----
    func textDidChange(_ notification: Notification) {
        if let tv = notification.object as? NSTextView { activeText = tv }
        saveDebounced()
    }

    /// Force every edit to use the chosen size. AppKit resets the text view's
    /// typing attributes to the surrounding text after each keystroke, which is
    /// what made a bumped-up size silently fall back — this defeats that.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        textView.typingAttributes[.font] = currentFont
        return true
    }

    /// Track which block is active and the size at its cursor/selection so
    /// `currentFont`, the stepper, and the readout follow what you're editing.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        activeText = tv
        let sel = tv.selectedRange()
        guard let ts = tv.textStorage else { return }
        var font: NSFont?
        if sel.length > 0, ts.length > 0 {
            font = ts.attribute(.font, at: min(sel.location, ts.length - 1),
                                effectiveRange: nil) as? NSFont
        } else if sel.location > 0, ts.length > 0 {
            font = ts.attribute(.font, at: min(sel.location - 1, ts.length - 1),
                                effectiveRange: nil) as? NSFont
        } else {
            font = tv.typingAttributes[.font] as? NSFont
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
        // When discarding (deleted from the switcher), skip saving entirely —
        // the manager removes the file. Otherwise: empty notes leave no trace,
        // real ones flush to disk.
        if discarding {
            manager?.controllerDidClose(self)
            return
        }
        if isEmpty { store.delete() } else { store.saveNow(snapshot()) }
        manager?.controllerDidClose(self)
    }

    /// Close this note's window without saving — used when the note is being
    /// deleted, so `windowWillClose` doesn't rewrite the file we're removing.
    func discard() {
        discarding = true
        window.close()
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

    /// A freshly built switcher menu — used by the in-note toolbar button, which
    /// pops it up on demand (the menu-bar item builds via the delegate instead).
    func makeSwitcherMenu() -> NSMenu {
        let menu = NSMenu()
        populateSwitcher(menu)
        return menu
    }

    /// Rebuild the menu-bar switcher each time it opens so it always reflects the
    /// current set of saved notes and which ones are open.
    func menuNeedsUpdate(_ menu: NSMenu) { populateSwitcher(menu) }

    /// Fill a menu with the saved-note list + New Note / Quit. Shared by the
    /// menu-bar item and the in-note toolbar dropdown so they never drift.
    private func populateSwitcher(_ menu: NSMenu) {
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

            // Delete submenu — pick a note here to remove it (with a confirm
            // popup). Keeps the main list a pure one-click "open".
            menu.addItem(.separator())
            let deleteParent = NSMenuItem(title: "Delete Note", action: nil, keyEquivalent: "")
            let deleteMenu = NSMenu()
            for note in saved {
                let title = openByID[note.id]?.displayTitle ?? note.displayTitle
                let di = NSMenuItem(title: title, action: #selector(deleteNoteItem(_:)),
                                    keyEquivalent: "")
                di.target = self
                di.representedObject = note.id
                deleteMenu.addItem(di)
            }
            deleteParent.submenu = deleteMenu
            menu.addItem(deleteParent)
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

    /// Confirm, then permanently delete a saved note (file + any open window).
    @objc private func deleteNoteItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let title = sender.title.isEmpty ? "this note" : sender.title
        let alert = NSAlert()
        alert.messageText = "Delete “\(title)”?"
        alert.informativeText = "This permanently removes the note. It can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            deleteNote(id: id)
        }
    }

    /// Discard any open window for the note (without re-saving it) and remove
    /// its file from disk.
    private func deleteNote(id: String) {
        if let c = controllers.first(where: { $0.id == id }) { c.discard() }
        NoteStore(id: id).delete()
    }

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
