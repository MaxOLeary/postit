// Postit — native macOS Liquid Glass post-its.
//
// Freeform text on real Liquid Glass (macOS 26). Type anything; it auto-saves.
// A note's body is a stack of blocks: freeform text plus collapsible sections
// (Obsidian-style folds) inserted at the cursor from the toolbar's ▸ chevron.
// Drag anywhere to move, grab an edge/corner to resize. The top strip gives you
// a "+" to spawn another note, a font stepper with a live size readout, the ▸
// add-section button, and a list-bullet switcher. Typing shortcuts: double-tap
// a capital trigger (RR / YY / BB for ink, WW for white, ## for a section) and
// both characters vanish, replaced by the action; Shift+↑/↓ steps the font
// size at the cursor. Every note remembers its
// blocks, font size, and position across launches. A menu-bar item lists every
// saved note so you can reopen (or delete) any. Zero runtime dependencies.

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
    // Conjoined notes: drag one note onto another's edge and they merge into
    // one window with side-by-side columns.
    static let minColumnWidth: CGFloat = 160
    static let gripHeight:     CGFloat = 14
    static let dockZoneWidth:  CGFloat = 56
    static let separatorColor  = NSColor(calibratedWhite: 1.0, alpha: 0.14)
    // Peak of the dock-glow gradient — brightest at the note's edge, fading
    // to clear toward the content.
    static let dockGlowColor   = NSColor(calibratedWhite: 1.0, alpha: 0.30)
    // Two tints: the calm look when idle, and a brighter one while focused to
    // counteract macOS dimming the glass on the active window.
    static let idleTint       = NSColor(calibratedWhite: 0.16, alpha: 0.18)
    static let focusedTint    = NSColor(calibratedWhite: 0.85, alpha: 0.12)
    // Ink swatches — the painter's primaries off a classic RYB color wheel
    // (blue lightened to a sky blue). They live in a popout tray: hover it to
    // slide the swatches out; they tuck back in when the mouse leaves. Click a
    // swatch to color the selection (and the ink you type with from the cursor
    // on); click the hollow ring to go back to the default white.
    static let inks: [(name: String, color: NSColor)] = [
        ("Red",    NSColor(calibratedRed: 0.839, green: 0.220, blue: 0.173, alpha: 1)), // #D6382C
        ("Yellow", NSColor(calibratedRed: 0.949, green: 0.886, blue: 0.227, alpha: 1)), // #F2E23A
        ("Blue",   NSColor(calibratedRed: 0.345, green: 0.690, blue: 0.925, alpha: 1)), // #58B0EC sky blue
    ]

    /// The ink a double-tap trigger character selects, or nil for "W" (and
    /// anything else), which means back to the default white.
    static func ink(for ch: Character) -> (name: String, color: NSColor)? {
        inks.first { $0.name.first == ch }
    }

    /// The color of a named swatch, or the default white for nil/unknown.
    static func inkColor(named name: String?) -> NSColor {
        inks.first { $0.name == name }?.color ?? textColor
    }

    /// Every character that can arm a double-tap shortcut: the ink initials
    /// plus "W" (back to white) and "#" (new section). Derived from `inks` so
    /// a new swatch's trigger works without touching the detection gates.
    static let shortcutTriggers = inks.map { String($0.name.prefix(1)) }.joined() + "W#"
}

// MARK: - Chrome helpers

/// An SF Symbol image at a given point size (semibold by default).
private func symbolImage(_ name: String, point: CGFloat,
                        weight: NSFont.Weight = .semibold) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: point, weight: weight))
}

/// An invisible, click-through view that reports mouse enter/exit — the ink
/// tray sits under one so hovering slides the swatches out and leaving tucks
/// them back in, no clicks needed. Tracking areas fire independent of hit
/// testing, so returning nil from hitTest keeps clicks flowing to the buttons.
private final class HoverZone: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent)  { onExit?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The bare chassis every chrome control shares: borderless, momentary, and
/// never stealing keyboard focus from the text.
private func bareButton(frame: NSRect = .zero,
                        target: AnyObject? = nil, action: Selector? = nil) -> NSButton {
    let b = NSButton(frame: frame)
    b.title = ""
    b.isBordered = false
    b.setButtonType(.momentaryChange)
    b.refusesFirstResponder = true          // don't steal focus from the text
    b.target = target
    b.action = action
    return b
}

/// A borderless, glyph-only button in the chrome tint — the shared look for
/// every toolbar/section symbol button (+ chevrons, switcher, disclosure, ✕).
private func chromeSymbolButton(_ symbol: String, point: CGFloat,
                               target: AnyObject?, action: Selector) -> NSButton {
    let b = bareButton(target: target, action: action)
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = symbolImage(symbol, point: point)
    b.contentTintColor = Style.chromeColor
    return b
}

// MARK: - Model

/// One piece of a note's body. A note is an ordered list of these: freeform
/// `text` runs interleaved with collapsible `section`s (title + foldable body),
/// Obsidian-style. Codable so the whole note round-trips to JSON.
struct Block: Codable {
    enum Kind: String, Codable { case text, section }
    var kind: Kind
    var rtf: String? = nil          // base64 RTF of the body (text block or section body)
    var text: String = ""           // plain fallback of the body
    var title: String = ""          // section header (ignored for text blocks)
    var collapsed: Bool = false     // section fold state (ignored for text blocks)
    var titleSize: CGFloat? = nil   // section header font size (nil = legacy default)
    var titleInk: String? = nil     // section header ink by swatch name (nil = white)

    var rtfData: Data? { rtf.flatMap { Data(base64Encoded: $0) } }
}

/// The saved state of one note. Codable so it round-trips to a small JSON file.
struct NoteData: Codable {
    var id: String
    var text: String = ""                       // switcher summary + legacy plain fallback
    var rtf: String? = nil                      // legacy single-body RTF (first text block, for old readers)
    var fontSize: CGFloat = Style.defaultFont   // last-chosen size - default for new typing / new notes
    var frame: [CGFloat] = []                   // [x, y, w, h] in screen coords; empty == "unset"
    var blocks: [Block]? = nil                  // the block content model; nil on legacy notes
    var columns: [[Block]]? = nil               // conjoined multi-column body; nil == single column

    /// The RTF payload decoded back to Data, if present.
    var rtfData: Data? { rtf.flatMap { Data(base64Encoded: $0) } }

    /// Blocks to build the note from — migrating a legacy single-body note into
    /// one text block so nothing that predates the block model is lost.
    var resolvedBlocks: [Block] {
        if let b = blocks, !b.isEmpty { return b }
        return [Block(kind: .text, rtf: rtf, text: text)]
    }

    /// Columns to build the note from — single-column and legacy notes resolve
    /// to one column via resolvedBlocks.
    var resolvedColumns: [[Block]] {
        if let c = columns, !c.isEmpty { return c }
        return [resolvedBlocks]
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

    /// Just enough of a note to label it in the switcher.
    private struct NoteHead: Codable { let id: String; let text: String }

    /// Every saved note's JSON file, sorted by a filesystem date key
    /// (fetched once per file, not per comparison).
    private static func noteFiles(sortedBy key: URLResourceKey, ascending: Bool) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [key]) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .map { u in (u, (try? u.resourceValues(forKeys: [key]))?.allValues[key] as? Date
                            ?? .distantPast) }
            .sorted { ascending ? $0.1 < $1.1 : $0.1 > $1.1 }
            .map(\.0)
    }

    /// Lightweight list for the switcher: (id, title) per saved note, oldest
    /// first. Decodes only id + text so it skips materializing every note's
    /// blocks and base64 RTF — which the menu never needs.
    static func loadHeads() -> [(id: String, title: String)] {
        noteFiles(sortedBy: .creationDateKey, ascending: true).compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let head = try? JSONDecoder().decode(NoteHead.self, from: data) else { return nil }
            return (head.id, NoteData.title(from: head.text))
        }
    }

    /// The single "main" note to restore on launch: the one edited most
    /// recently. A reload brings back just that one window instead of every
    /// note ever created — the others stay saved on disk (nothing is deleted),
    /// they just aren't reopened. Returns nil if there are no saved notes.
    static func loadMostRecent() -> NoteData? {
        for url in noteFiles(sortedBy: .contentModificationDateKey, ascending: false) {
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
    /// Takes a snapshot *closure* rather than a finished note, so the expensive
    /// RTF serialization runs once when the write fires — not on every keystroke.
    func scheduleSave(_ snapshot: @escaping () -> NoteData?) {
        pending?.cancel()
        let work = DispatchWorkItem { [url] in
            guard let note = snapshot() else { return }
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

/// The grip strip at the top of each column in a conjoined note. Dragging it
/// past a small threshold tears the column out into its own window. Blocks
/// the drag from falling through to isMovableByWindowBackground so grabbing
/// the grip never moves the whole note.
private final class ColumnGrip: NSView {
    var onDragOut: ((NSEvent) -> Void)?
    private var downAt: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let w: CGFloat = 28, h: CGFloat = 4
        let pill = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2,
                          width: w, height: h)
        Style.chromeColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) > 10 {
            downAt = nil
            onDragOut?(event)
        }
    }

    override func mouseUp(with event: NSEvent) { downAt = nil }
}

/// One column of a note body: a grip strip (visible only when conjoined) over
/// a scroll view whose document is the vertical block stack — the same
/// scroll/stack setup a whole note used to own exactly one of.
private final class NoteColumn {
    let view = NSView()          // wrapper; framed by layoutColumns()
    let grip = ColumnGrip()
    let scroll = NSScrollView()
    let stack = FlippedStack()

    init() {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
        view.addSubview(grip)
        view.addSubview(scroll)
    }

    /// Place the grip (when visible) and the scroll inside the wrapper. The
    /// grip is a small target in the column's top-right corner, so the rest of
    /// the column's top edge still drags the whole window.
    func layout(gripVisible: Bool) {
        grip.isHidden = !gripVisible
        let gripH = gripVisible ? Style.gripHeight : 0
        let gripW: CGFloat = 40
        grip.frame = NSRect(x: max(view.bounds.width - gripW, 0),
                            y: view.bounds.height - Style.gripHeight,
                            width: gripW, height: Style.gripHeight)
        scroll.frame = NSRect(x: 0, y: 0, width: view.bounds.width,
                              height: view.bounds.height - gripH)
    }
}

/// Hosts the side-by-side columns below the strip. Window resizes reach it
/// through its autoresizing mask; it re-runs the manual column layout.
private final class ColumnsHost: NSView {
    var relayout: (() -> Void)?
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        relayout?()
    }
}

/// One block in a note's body. Both view types (freeform text and a fold)
/// conform, so the controller enumerates blocks without type-switching.
protocol BlockView: NSView {
    /// Serialize this block back to its saved form.
    func asBlock() -> Block
    /// The block's contribution to the switcher summary, or nil if blank.
    var summaryText: String? { get }
    /// The text view a font change / initial focus should target.
    var primaryTextView: NSTextView { get }
    /// Whether `tv` is (or belongs to) this block.
    func owns(_ tv: NSTextView) -> Bool
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
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // Only a width change reflows wrapping (and thus the intrinsic height);
        // vertical-only growth doesn't, so skip the extra invalidation there.
        if widthChanged { invalidateIntrinsicContentSize() }
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
        // No system text replacement — it's what turns a double-space into a
        // period (sentence capitalization is done in the controller instead).
        tv.isAutomaticTextReplacementEnabled = false
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
    /// Keeps the size/font at the cursor and the current typing ink (the
    /// default white unless a swatch is active).
    override func paste(_ sender: Any?) {
        guard let plain = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        let font = (typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: Style.defaultFont)
        let color = (typingAttributes[.foregroundColor] as? NSColor) ?? Style.textColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let styled = NSAttributedString(string: plain, attributes: attrs)
        let range = selectedRange()
        if shouldChangeText(in: range, replacementString: plain) {
            textStorage?.replaceCharacters(in: range, with: styled)
            setSelectedRange(NSRange(location: range.location + styled.length, length: 0))
            didChangeText()
        }
    }
}

extension GrowingTextView: BlockView {
    func asBlock() -> Block { Block(kind: .text, rtf: rtfBase64, text: string) }
    var summaryText: String? {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var primaryTextView: NSTextView { self }
    func owns(_ tv: NSTextView) -> Bool { tv === self }
}

/// A collapsible section: a disclosure header with an editable title and a
/// delete button, over a foldable rich-text body. Like an Obsidian fold.
final class SectionView: NSView, NSTextFieldDelegate {
    let body: GrowingTextView
    private var disclosure: NSButton!
    private let titleField = NSTextField()
    private var collapsed: Bool
    private var titleInkName: String?
    private let onChange: () -> Void
    private let onDelete: (SectionView) -> Void
    private let onTitleFontStep: (SectionView, CGFloat) -> Void
    private let onTitleShortcut: (SectionView, Character) -> Void

    var title: String { titleField.stringValue }
    var isCollapsed: Bool { collapsed }

    init(block: Block, fontSize: CGFloat, textDelegate: NSTextViewDelegate,
         onChange: @escaping () -> Void,
         onDelete: @escaping (SectionView) -> Void,
         onTitleFontStep: @escaping (SectionView, CGFloat) -> Void,
         onTitleShortcut: @escaping (SectionView, Character) -> Void) {
        self.body = GrowingTextView.make(delegate: textDelegate, fontSize: fontSize)
        self.collapsed = block.collapsed
        self.onChange = onChange
        self.onDelete = onDelete
        self.onTitleFontStep = onTitleFontStep
        self.onTitleShortcut = onTitleShortcut
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(block: block, fontSize: fontSize)
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    private func build(block: Block, fontSize: CGFloat) {
        disclosure = chromeSymbolButton("chevron.down", point: 9, target: self, action: #selector(toggle))
        disclosure.setContentHuggingPriority(.required, for: .horizontal)
        // A comfortably larger hitbox than the 9pt glyph itself — the fold
        // toggle gets hit constantly and shouldn't demand pixel aim.
        NSLayoutConstraint.activate([
            disclosure.widthAnchor.constraint(equalToConstant: 24),
            disclosure.heightAnchor.constraint(equalToConstant: 22),
        ])
        updateDisclosureImage()

        titleField.stringValue = block.title
        titleField.placeholderString = "Section title"
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.textColor = Style.textColor
        titleField.font = NSFont.systemFont(ofSize: block.titleSize ?? max(fontSize, 13),
                                            weight: .semibold)
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.delegate = self
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        setTitleInk(name: block.titleInk)

        let del = chromeSymbolButton("xmark", point: 9, target: self, action: #selector(deleteTapped))
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

    @objc private func deleteTapped() { onDelete(self) }

    private func updateDisclosureImage() {
        disclosure.image = symbolImage(collapsed ? "chevron.right" : "chevron.down", point: 9)
    }

    func controlTextDidChange(_ obj: Notification) {
        detectTitleShortcut()
        onChange()
    }

    /// Double-tap shortcuts inside the header — same triggers as the body
    /// (RR/YY/BB/WW ink, ## new section). The title edits through the window's
    /// field editor, which never routes the NSTextView delegate hooks the body
    /// blocks use, so this checks the two characters behind the cursor after
    /// each keystroke instead; on a hit both are removed and the action fires.
    private func detectTitleShortcut() {
        guard let ed = titleField.currentEditor() as? NSTextView else { return }
        let sel = ed.selectedRange()
        guard sel.length == 0, sel.location >= 2 else { return }
        let pairRange = NSRange(location: sel.location - 2, length: 2)
        let pair = (ed.string as NSString).substring(with: pairRange)
        guard let ch = pair.first, pair.last == ch,
              Style.shortcutTriggers.contains(ch) else { return }
        ed.insertText("", replacementRange: pairRange)
        onTitleShortcut(self, ch)
    }

    /// Shift+Up / Shift+Down inside the header: forward to the controller's
    /// font stepper instead of AppKit's line-wise selection extension.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            onTitleFontStep(self, +1)
            return true
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            onTitleFontStep(self, -1)
            return true
        default:
            return false
        }
    }

    /// Font size of the section header right now.
    var titleFontSize: CGFloat { titleField.font?.pointSize ?? 13 }

    /// Resize the header font, keeping the live field editor in sync so the
    /// glyphs and the insertion point update while you're typing in it.
    func setTitleFontSize(_ size: CGFloat) {
        let f = NSFont.systemFont(ofSize: size, weight: .semibold)
        titleField.font = f
        syncFieldEditor(.font, f)
    }

    /// Color the whole header with a named ink swatch (nil = default white),
    /// keeping the live field editor in sync the same way.
    func setTitleInk(name: String?) {
        titleInkName = name
        let color = Style.inkColor(named: name)
        titleField.textColor = color
        syncFieldEditor(.foregroundColor, color)
    }

    /// Apply an attribute across the live field editor (when the title is
    /// mid-edit) so existing glyphs and the typing attributes both pick it up.
    private func syncFieldEditor(_ key: NSAttributedString.Key, _ value: Any) {
        guard let ed = titleField.currentEditor() as? NSTextView else { return }
        ed.textStorage?.addAttribute(
            key, value: value,
            range: NSRange(location: 0, length: (ed.string as NSString).length))
        ed.typingAttributes[key] = value
    }

    /// Whether `field` is this section's header (for field-editor routing).
    func ownsTitleField(_ field: NSTextField) -> Bool { field === titleField }

    /// Move keyboard focus into the title field (after inserting a new section).
    func focusTitle() { window?.makeFirstResponder(titleField) }

    /// Serialize back to a Block for saving.
    func asBlock() -> Block {
        Block(kind: .section, rtf: body.rtfBase64, text: body.string,
              title: titleField.stringValue, collapsed: collapsed,
              titleSize: titleFontSize, titleInk: titleInkName)
    }
}

extension SectionView: BlockView {
    var summaryText: String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        let b = body.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? nil : b
    }
    var primaryTextView: NSTextView { body }
    func owns(_ tv: NSTextView) -> Bool { tv === body }
}

/// Which vertical edge of a note another note is hovering over / docking to.
enum DockSide { case left, right }

// MARK: - One note

/// Owns a single post-it window: the glass, the text view, the top-strip
/// controls, and its persistence. Reports lifecycle back to the manager.
final class NoteController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    let id: String
    private weak var manager: NotesManager?
    private let store: NoteStore

    private var window: GlassWindow!
    // The note's translucent base: real Liquid Glass on macOS 26, an
    // NSVisualEffectView blur on older systems.
    private var glass: NSView!
    // Fallback-only: the tint layer sitting over the blur (real glass tints
    // itself via tintColor).
    private weak var fallbackTint: NSView?
    private var sizeLabel: NSTextField!
    private var container: NSView!
    // The note body: one or more side-by-side columns, each a scroll view over
    // a vertical stack of block views (GrowingTextView for freeform text,
    // SectionView for folds). A plain note has exactly one column; conjoined
    // notes have more, split by hairline separators.
    private var columnsHost: ColumnsHost!
    private var columns: [NoteColumn] = []
    private var separators: [NSView] = []
    // The translucent affordance shown while another note hovers over an edge.
    private weak var dockGlow: NSView?
    // The text view the user is currently editing — font changes target it.
    private weak var activeText: NSTextView?
    // Set while the cursor lives in a section title instead — the font
    // stepper, swatches, and ▸ button aim at that section's header.
    private weak var activeTitleSection: SectionView?
    private var fontSize: CGFloat
    // The size new typing should use right now. We enforce it on every edit
    // because AppKit likes to reset typing attributes to the surrounding text.
    private var currentFont = NSFont.systemFont(ofSize: Style.defaultFont)
    // The active ink swatch; nil = default white. Enforced on every edit the
    // same way as the font, so the surrounding text never hijacks the color.
    private var ink: NSColor?
    private var inkButtons: [NSButton] = []
    // The hollow ring the swatches slide out from; its center fills with the
    // active ink so the chosen color stays visible while the tray is closed.
    private var inkRing: NSButton!
    private var inkTrayExpanded = false
    // The last single trigger character typed, so a second tap of the same one
    // can fire its double-tap shortcut (RR/YY/BB/WW ink, ## section). When the
    // first tap replaced a selection, `replaced` keeps that text so the fired
    // shortcut can restore it and act on it instead of leaving it deleted —
    // select a line, type RR, and the line turns red rather than vanishing.
    private var pendingShortcut: (char: Character, location: Int,
                                  tv: ObjectIdentifier, replaced: NSAttributedString?)?
    // Sentence auto-cap bypass, the delete-and-retype pattern: `lastAutoCap`
    // remembers where the auto-capital just fired; backspacing that letter
    // arms `autoCapBypass`, and the next letter typed right there is left
    // exactly as typed (lowercase stays lowercase).
    private var lastAutoCap: (tv: ObjectIdentifier, location: Int)?
    private var autoCapBypass: (tv: ObjectIdentifier, location: Int)?
    // Set when the note is being deleted so windowWillClose skips the save.
    private var discarding = false
    // Pending hover-to-wake: armed on mouse enter, cancelled on exit.
    private var hoverWake: DispatchWorkItem?

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

        // ---- Liquid Glass base (macOS 26) or a translucent blur fallback ----
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(frame: window.contentLayoutRect)
            g.cornerRadius = Style.cornerRadius
            g.tintColor = Style.idleTint
            glass = g
        } else {
            let v = NSVisualEffectView(frame: window.contentLayoutRect)
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = Style.cornerRadius
            v.layer?.masksToBounds = true
            let tint = NSView(frame: v.bounds)
            tint.autoresizingMask = [.width, .height]
            tint.wantsLayer = true
            tint.layer?.backgroundColor = Style.idleTint.cgColor
            v.addSubview(tint)
            fallbackTint = tint
            glass = v
        }
        glass.autoresizingMask = [.width, .height]
        glass.appearance = NSAppearance(named: .darkAqua)

        container = NSView(frame: glass.bounds)
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
        let up = symbolButton("chevron.up", point: 9, action: #selector(fontUp))
        up.frame = NSRect(x: 33, y: Style.stripHeight / 2 - 1, width: 15, height: 11)
        up.autoresizingMask = [.maxXMargin, .minYMargin]
        up.toolTip = "Bigger"
        strip.addSubview(up)

        let down = symbolButton("chevron.down", point: 9, action: #selector(fontDown))
        down.frame = NSRect(x: 33, y: Style.stripHeight / 2 - 10, width: 15, height: 11)
        down.autoresizingMask = [.maxXMargin, .minYMargin]
        down.toolTip = "Smaller"
        strip.addSubview(down)

        // size readout — snug against the chevrons so the stepper reads as one control
        sizeLabel = NSTextField(labelWithString: "\(Int(fontSize))")
        sizeLabel.frame = NSRect(x: 44, y: (Style.stripHeight - 16) / 2, width: 26, height: 16)
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = Style.chromeColor
        sizeLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        sizeLabel.toolTip = "Current font size"
        strip.addSubview(sizeLabel)

        // insert-section — a right-facing chevron that splits the text at the
        // cursor and drops a collapsible section (title + foldable body) there.
        let sectionBtn = symbolButton("chevron.right", point: 12,
                                      action: #selector(insertSection as () -> Void))
        sectionBtn.frame = NSRect(x: 65, y: (Style.stripHeight - 16) / 2, width: 16, height: 16)
        sectionBtn.autoresizingMask = [.maxXMargin, .minYMargin]
        sectionBtn.toolTip = "Add a collapsible section at the cursor"
        strip.addSubview(sectionBtn)

        // ink tray — a hollow ring; hover it and the three primary swatches
        // slide out to its right, tucking back in when the mouse leaves. Click
        // a swatch to ink the selection / typing color, click the ring to go
        // back to the default white. The ring's center fills with the active
        // ink while the tray is collapsed.
        let ringX: CGFloat = 87
        let dotY = (Style.stripHeight - 12) / 2
        inkRing = inkButton(at: NSPoint(x: ringX, y: dotY), action: #selector(inkRingTapped))
        inkRing.layer?.borderWidth = 1.5
        inkRing.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.55).cgColor
        inkRing.toolTip = "Default white — click to clear the ink"
        strip.addSubview(inkRing)

        // Opening is deliberate: only hovering the ring itself slides the
        // swatches out. Both zones are click-through, so the ring and swatch
        // buttons underneath still get every click.
        let ringZone = HoverZone(frame: inkRing.frame.insetBy(dx: -4, dy: -6))
        ringZone.autoresizingMask = [.maxXMargin, .minYMargin]
        ringZone.onEnter = { [weak self] in self?.setInkTray(expanded: true) }
        strip.addSubview(ringZone)

        // The wider zone spanning the slid-out swatches only keeps the open
        // tray alive while the mouse travels across it; leaving collapses it.
        let trayWidth = 18 + CGFloat(Style.inks.count - 1) * 17 + 12   // ring gap + dots
        let trayZone = HoverZone(frame: NSRect(x: ringX - 4, y: 0,
                                               width: trayWidth + 12,
                                               height: Style.stripHeight))
        trayZone.autoresizingMask = [.maxXMargin, .minYMargin]
        trayZone.onExit = { [weak self] in self?.setInkTray(expanded: false) }
        strip.addSubview(trayZone)

        for (i, inkDef) in Style.inks.enumerated() {
            let dot = inkButton(at: NSPoint(x: ringX, y: dotY), action: #selector(inkTapped(_:)))
            dot.layer?.backgroundColor = inkDef.color.cgColor
            dot.layer?.borderWidth = 1
            dot.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.35).cgColor
            dot.tag = i
            dot.toolTip = "\(inkDef.name) ink"
            dot.isHidden = true                 // starts collapsed under the ring
            dot.alphaValue = 0
            strip.addSubview(dot, positioned: .below, relativeTo: inkRing)
            inkButtons.append(dot)
        }

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

        // ---- side-by-side columns below the strip ----
        let contentRect = NSRect(x: Style.padding, y: Style.padding,
                                 width: container.bounds.width - Style.padding * 2,
                                 height: container.bounds.height - Style.stripHeight - Style.padding)
        columnsHost = ColumnsHost(frame: contentRect)
        columnsHost.autoresizingMask = [.width, .height]
        columnsHost.relayout = { [weak self] in self?.layoutColumns() }
        container.addSubview(columnsHost)

        currentFont = NSFont.systemFont(ofSize: fontSize)
        for blocks in data.resolvedColumns {
            insertColumn(makeColumn(blocks: blocks), at: columns.count)
        }
        layoutColumns()

        // Focus follows the mouse: resting the cursor on a note for a beat
        // wakes it — no click needed after visiting another app (becoming key
        // also restores the text cursor, via restoreCursor). The dwell keeps a
        // mouse just passing through from yanking the keyboard mid-typing.
        let wakeZone = HoverZone(frame: container.bounds)
        wakeZone.autoresizingMask = [.width, .height]
        wakeZone.onEnter = { [weak self] in
            guard let self, !self.window.isKeyWindow else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.window.makeKeyAndOrderFront(nil)
            }
            self.hoverWake?.cancel()
            self.hoverWake = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        wakeZone.onExit = { [weak self] in
            self?.hoverWake?.cancel()
            self?.hoverWake = nil
        }
        container.addSubview(wakeZone)

        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.contentView = container
        } else {
            container.frame = glass.bounds
            container.autoresizingMask = [.width, .height]
            glass.addSubview(container)
        }
        window.contentView = glass
        window.delegate = self

        // position: restore saved frame (pulled back onto a screen), else center
        if data.frame.count == 4 {
            let saved = NSRect(x: data.frame[0], y: data.frame[1],
                               width: data.frame[2], height: data.frame[3])
            window.setFrame(NoteController.onScreen(saved), display: false)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        if let first = firstTextView() {
            window.makeFirstResponder(first)
            activeText = first
        }
        applyTint(focused: window.isKeyWindow)

        // Watch every text-view selection change to catch the window's field
        // editor: section titles edit through it, and it never routes the
        // NSTextView delegate hooks the body blocks use — this is how clicking
        // into a title aims the font controls at it and updates the readout.
        NotificationCenter.default.addObserver(
            self, selector: #selector(anySelectionChanged(_:)),
            name: NSTextView.didChangeSelectionNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Pull a saved frame back onto a screen, so a note can never restore to a
    /// spot you can't reach (a display that's gone, or a frame that a buggy
    /// drag once saved off-screen). "On screen" means at least a ~40pt band of
    /// the note is visible somewhere.
    private static func onScreen(_ f: NSRect) -> NSRect {
        let screens = NSScreen.screens
        if screens.contains(where: { $0.visibleFrame.intersects(f.insetBy(dx: 40, dy: 40)) }) {
            return f
        }
        guard let vis = (NSScreen.main ?? screens.first)?.visibleFrame else { return f }
        var g = f
        g.origin.x = min(max(g.origin.x, vis.minX), max(vis.maxX - g.width, vis.minX))
        g.origin.y = min(max(g.origin.y, vis.minY), max(vis.maxY - g.height, vis.minY))
        return g
    }

    /// If the selection landed in the field editor of one of our section
    /// titles, mark that section active and show its font size in the readout.
    @objc private func anySelectionChanged(_ note: Notification) {
        guard let fe = note.object as? NSTextView, fe.isFieldEditor,
              fe.window === window,
              let field = fe.delegate as? NSTextField,
              let section = allBlockViews.compactMap({ $0 as? SectionView })
                  .first(where: { $0.ownsTitleField(field) }) else { return }
        activeTitleSection = section
        sizeLabel.stringValue = "\(Int(round(section.titleFontSize)))"
    }

    // ---- block management ----

    private func makeTextView(from block: Block) -> GrowingTextView {
        let tv = GrowingTextView.make(delegate: self, fontSize: fontSize)
        tv.load(rtfData: block.rtfData, plain: block.text, fontSize: fontSize)
        return tv
    }

    private func makeSectionView(from block: Block) -> SectionView {
        SectionView(block: block, fontSize: fontSize, textDelegate: self,
                    onChange: { [weak self] in self?.saveDebounced() },
                    onDelete: { [weak self] section in self?.removeSection(section) },
                    onTitleFontStep: { [weak self] section, delta in
                        self?.changeTitleFont(of: section, by: delta)
                    },
                    onTitleShortcut: { [weak self] section, ch in
                        self?.runTitleShortcut(ch, in: section)
                    })
    }

    // ---- columns ----

    /// Build one column and populate it with block views.
    private func makeColumn(blocks: [Block]) -> NoteColumn {
        let col = NoteColumn()
        col.grip.onDragOut = { [weak self, weak col] event in
            guard let self, let col else { return }
            self.dragOutColumn(col, with: event)
        }
        for block in blocks {
            switch block.kind {
            case .text:    appendBlockView(makeTextView(from: block), in: col)
            case .section: appendBlockView(makeSectionView(from: block), in: col)
            }
        }
        ensureNonEmpty(col)
        return col
    }

    private func insertColumn(_ col: NoteColumn, at index: Int) {
        columnsHost.addSubview(col.view)
        columns.insert(col, at: index)
    }

    /// Manual side-by-side layout: equal column widths with a hairline
    /// separator (padded on both sides) between neighbors. Also maintains the
    /// window's minimum size so columns can't be crushed below usability.
    private func layoutColumns() {
        let n = columns.count
        guard n > 0, columnsHost != nil else { return }

        // Keep exactly one separator between each pair of columns.
        while separators.count > n - 1 { separators.removeLast().removeFromSuperview() }
        while separators.count < n - 1 {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = Style.separatorColor.cgColor
            columnsHost.addSubview(line)
            separators.append(line)
        }

        let bounds = columnsHost.bounds
        let gutter = Style.padding * 2 + 1              // padding | 1px line | padding
        let colW = (bounds.width - gutter * CGFloat(n - 1)) / CGFloat(n)
        var x: CGFloat = 0
        for (i, col) in columns.enumerated() {
            col.view.frame = NSRect(x: x, y: 0, width: colW, height: bounds.height)
            col.layout(gripVisible: n > 1)
            if i < n - 1 {
                separators[i].frame = NSRect(x: x + colW + Style.padding, y: 0,
                                             width: 1, height: bounds.height)
            }
            x += colW + gutter
        }
        window.contentMinSize = NSSize(
            width: CGFloat(n) * Style.minColumnWidth
                + gutter * CGFloat(n - 1) + Style.padding * 2,
            height: 200)
    }

    /// Tear a column out into its own free-floating note (un-join): remove it
    /// from this window, shrink to fit what's left, and spawn a new note under
    /// the cursor that follows the mouse until the button lifts. The follow is
    /// a manual tracking loop on this window's event stream — handing the drag
    /// to the new window (performDrag) flings it, because the gesture's events
    /// live in this window's coordinates.
    private func dragOutColumn(_ col: NoteColumn, with event: NSEvent) {
        guard columns.count > 1, let idx = columns.firstIndex(where: { $0 === col }) else { return }
        let blocks = blockViews(in: col).map { $0.asBlock() }
        let colW = col.view.frame.width + Style.padding * 2 + 1   // its share incl. one gutter
        if let at = activeText, column(containing: at) === col { activeText = nil }
        if let s = activeTitleSection, column(containing: s) === col { activeTitleSection = nil }
        columns.remove(at: idx)
        col.view.removeFromSuperview()

        // Shrink around the departed column: pulling the leftmost one keeps
        // the right edge fixed, any other keeps the left edge fixed.
        var f = window.frame
        f.size.width -= colW
        if idx == 0 { f.origin.x += colW }
        window.setFrame(f, display: true)
        layoutColumns()
        saveDebounced()

        guard let fresh = manager?.spawnExtractedNote(
            blocks: blocks, fontSize: fontSize,
            size: NSSize(width: colW, height: f.height)) else { return }

        // Ride out the rest of the gesture: keep the new note glued under the
        // cursor until the button lifts. Docking stays suppressed so the torn
        // column can't instantly re-merge into the note it just left.
        let newWin = fresh.windowRef
        let size = newWin.frame.size
        manager?.dockingSuppressed = true
        while NSEvent.pressedMouseButtons & 1 != 0 {
            _ = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                 until: Date().addingTimeInterval(0.03),
                                 inMode: .eventTracking, dequeue: true)
            let m = NSEvent.mouseLocation
            newWin.setFrameOrigin(NSPoint(x: m.x - size.width / 2,
                                          y: m.y - size.height + 20))
        }
        manager?.dockingSuppressed = false
        fresh.focus()
    }

    /// The note's content as per-column block lists (for a dock-merge handoff).
    func snapshotColumns() -> [[Block]] {
        columns.map { blockViews(in: $0).map { $0.asBlock() } }
    }

    /// Take on another note's columns (a dock-merge): insert them on `side`,
    /// grow the window to `frame`, and hand focus to the first arrival.
    func adoptColumns(_ cols: [[Block]], on side: DockSide, frame: NSRect) {
        let fresh = cols.map { makeColumn(blocks: $0) }
        for (i, col) in fresh.enumerated() {
            insertColumn(col, at: side == .left ? i : columns.count)
        }
        window.setFrame(frame, display: true)
        layoutColumns()
        showDockGlow(nil)
        if let tv = fresh.first.flatMap({ blockViews(in: $0).first?.primaryTextView }) {
            window.makeFirstResponder(tv)
            activeText = tv
        }
        saveDebounced()
    }

    /// Show (or clear, with nil) the edge glow that marks where a dragged note
    /// will dock when released: a gradient, brightest at the edge and fading
    /// inward toward the content.
    func showDockGlow(_ side: DockSide?) {
        dockGlow?.removeFromSuperview()
        guard let side else { return }
        let grad = CAGradientLayer()
        grad.colors = [Style.dockGlowColor.cgColor,
                       Style.dockGlowColor.withAlphaComponent(0).cgColor]
        grad.startPoint = CGPoint(x: side == .left ? 0 : 1, y: 0.5)
        grad.endPoint   = CGPoint(x: side == .left ? 1 : 0, y: 0.5)
        grad.cornerRadius = Style.cornerRadius
        grad.maskedCorners = side == .left
            ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        let v = NSView()
        v.layer = grad
        v.wantsLayer = true
        let b = container.bounds
        let x = side == .left ? 0 : b.width - Style.dockZoneWidth
        v.frame = NSRect(x: x, y: 0, width: Style.dockZoneWidth, height: b.height)
        container.addSubview(v)
        dockGlow = v
    }

    /// The column that owns a descendant view (a text view, section, grip…).
    private func column(containing v: NSView) -> NoteColumn? {
        columns.first { v.isDescendant(of: $0.view) }
    }

    /// The column the cursor is in — where new sections land and where the
    /// backstop toolbar actions aim. Falls back to the first column.
    private var activeColumn: NoteColumn {
        if let s = activeTitleSection, let c = column(containing: s) { return c }
        if let at = activeText, let c = column(containing: at) { return c }
        return columns[0]
    }

    // ---- block management ----

    /// One column's blocks in order, viewed through the BlockView protocol so
    /// callers never type-switch on the concrete view class.
    private func blockViews(in col: NoteColumn) -> [BlockView] {
        col.stack.arrangedSubviews.compactMap { $0 as? BlockView }
    }

    /// Every block across all columns, left to right.
    private var allBlockViews: [BlockView] { columns.flatMap { blockViews(in: $0) } }

    private func appendBlockView(_ v: NSView, in col: NoteColumn) {
        col.stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: col.stack.widthAnchor).isActive = true
    }

    private func insertBlockView(_ v: NSView, at index: Int, in col: NoteColumn) {
        col.stack.insertArrangedSubview(v, at: index)
        v.widthAnchor.constraint(equalTo: col.stack.widthAnchor).isActive = true
    }

    /// Guarantee a column holds at least one text block to type into.
    private func ensureNonEmpty(_ col: NoteColumn) {
        if col.stack.arrangedSubviews.isEmpty {
            appendBlockView(makeTextView(from: Block(kind: .text)), in: col)
        }
    }

    private func removeSection(_ v: SectionView) {
        guard let col = column(containing: v) else { return }
        let block = v.asBlock()
        let index = col.stack.arrangedSubviews.firstIndex(of: v) ?? 0
        if let at = activeText, v.owns(at) { activeText = nil }
        if activeTitleSection === v { activeTitleSection = nil }
        col.stack.removeArrangedSubview(v)
        v.removeFromSuperview()
        ensureNonEmpty(col)
        window.undoManager?.registerUndo(withTarget: self) { [weak col] me in
            me.restoreSection(block, at: index, in: col)
        }
        window.undoManager?.setActionName("Delete Section")
        saveDebounced()
    }

    /// Undo of a section delete: rebuild the section from its saved block and
    /// put it back where it was (registering the inverse for redo). The column
    /// is captured weakly — if it has since been torn out of this note, the
    /// undo quietly no-ops instead of resurrecting the section somewhere else.
    private func restoreSection(_ block: Block, at index: Int, in col: NoteColumn?) {
        guard let col, columns.contains(where: { $0 === col }) else { return }
        let sv = makeSectionView(from: block)
        insertBlockView(sv, at: min(index, col.stack.arrangedSubviews.count), in: col)
        window.undoManager?.registerUndo(withTarget: self) { me in
            me.removeSection(sv)
        }
        window.undoManager?.setActionName("Delete Section")
        saveDebounced()
    }

    /// Index of the block currently being edited within its column (so a new
    /// section lands right after it). Falls back to the column's last block.
    private func activeBlockIndex(in col: NoteColumn) -> Int {
        let views = blockViews(in: col)
        if let s = activeTitleSection, let i = views.firstIndex(where: { $0 === s }) { return i }
        if let at = activeText, let i = views.firstIndex(where: { $0.owns(at) }) { return i }
        return max(views.count - 1, 0)
    }

    private func firstTextView() -> NSTextView? {
        columns.first.flatMap { blockViews(in: $0).first?.primaryTextView }
    }

    /// The switcher summary: each column's first section title or non-empty
    /// text line, joined across a conjoined note's columns.
    private func currentSummary() -> String {
        columns.compactMap { col in blockViews(in: col).lazy.compactMap { $0.summaryText }.first }
            .joined(separator: " · ")
    }

    private func saveDebounced() { store.scheduleSave { [weak self] in self?.snapshot() } }

    @objc private func insertSection() {
        // Editing a section title → the new section goes right below that one.
        if let s = activeTitleSection { insertSection(after: s); return }
        // Cursor is in a top-level text block → split it at the cursor so the
        // new section lands exactly where you are, and text after the cursor
        // moves into a fresh text block just below it.
        let col = activeColumn
        let arranged = col.stack.arrangedSubviews
        if let tv = activeText as? GrowingTextView, let idx = arranged.firstIndex(of: tv) {
            splitAndInsertSection(in: tv, at: idx, in: col)
            return
        }
        // Cursor is in a section body (or nowhere) → insert right after that block.
        insertFreshSection(at: min(activeBlockIndex(in: col) + 1, arranged.count), in: col)
    }

    /// Insert a fresh section immediately after `section` and focus its title
    /// (the ## shortcut / ▸ button while editing a section header).
    private func insertSection(after section: SectionView) {
        guard let col = column(containing: section),
              let idx = col.stack.arrangedSubviews.firstIndex(of: section) else { return }
        insertFreshSection(at: idx + 1, in: col)
    }

    /// Insert an empty section at `index` and focus its title, keeping a
    /// trailing text block below the last section so there's room to type.
    private func insertFreshSection(at index: Int, in col: NoteColumn) {
        let sv = makeSectionView(from: Block(kind: .section))
        insertBlockView(sv, at: index, in: col)
        if index == col.stack.arrangedSubviews.count - 1 {
            appendBlockView(makeTextView(from: Block(kind: .text)), in: col)
        }
        sv.focusTitle()
        saveDebounced()
    }

    /// Split `tv` at the cursor: keep the text before it, insert a new section
    /// after it, and move any text after the cursor into a new text block below.
    private func splitAndInsertSection(in tv: GrowingTextView, at index: Int, in col: NoteColumn) {
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

        // A text block below the section: carries the after-cursor text (or is
        // empty, giving you a fresh line to type under the fold).
        let afterView = GrowingTextView.make(delegate: self, fontSize: fontSize)
        if afterAttr.length > 0 {
            afterView.textStorage?.setAttributedString(afterAttr)
            afterView.invalidateIntrinsicContentSize()
        }
        insertBlockView(afterView, at: index + 1, in: col)
        // The section slots in between, pushing the carried text below it.
        insertFreshSection(at: index + 1, in: col)
    }

    /// A borderless text button styled like the existing subtle "✕".
    private func chromeButton(_ title: String, size: CGFloat, fontSize: CGFloat) -> NSButton {
        let b = bareButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        b.title = title
        b.font = NSFont.systemFont(ofSize: fontSize)
        b.contentTintColor = Style.chromeColor
        return b
    }

    /// A borderless SF Symbol button targeting this controller.
    private func symbolButton(_ symbol: String, point: CGFloat, action: Selector) -> NSButton {
        chromeSymbolButton(symbol, point: point, target: self, action: action)
    }

    /// A 12pt circular tray button - the shared chassis for the hollow ink
    /// ring and the colored swatch dots (they differ only in fill and border).
    private func inkButton(at origin: NSPoint, action: Selector) -> NSButton {
        let b = bareButton(frame: NSRect(origin: origin, size: NSSize(width: 12, height: 12)),
                           target: self, action: action)
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        b.autoresizingMask = [.maxXMargin, .minYMargin]
        return b
    }

    // ---- state → NoteData ----
    private func snapshot() -> NoteData {
        let f = window.frame
        // A single column saves as plain `blocks` — the same shape as before
        // conjoining existed, so old files round-trip and a note that drops
        // back to one column becomes a normal note file again automatically.
        let cols = columns.map { col in blockViews(in: col).map { $0.asBlock() } }
        return NoteData(id: id, text: currentSummary(), fontSize: fontSize,
                        frame: [f.origin.x, f.origin.y, f.size.width, f.size.height],
                        blocks: cols.count == 1 ? cols[0] : nil,
                        columns: cols.count == 1 ? nil : cols)
    }

    private func applyTint(focused: Bool) {
        let tint = focused ? Style.focusedTint : Style.idleTint
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.tintColor = tint
        } else {
            fallbackTint?.layer?.backgroundColor = tint.cgColor
        }
    }

    // ---- actions ----
    @objc private func newNote() { manager?.newNote() }

    @objc private func fontUp()   { changeFont(by: +1) }
    @objc private func fontDown() { changeFont(by: -1) }

    private func changeFont(by delta: CGFloat) {
        // Cursor in a section title → step that header's font instead.
        if let s = activeTitleSection { changeTitleFont(of: s, by: delta); return }
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

    /// Step a section header's font size, mirroring it in the readout.
    private func changeTitleFont(of section: SectionView, by delta: CGFloat) {
        let newSize = min(max(section.titleFontSize + delta, Style.minFont), Style.maxFont)
        guard newSize != section.titleFontSize else { return }
        section.setTitleFontSize(newSize)
        sizeLabel.stringValue = "\(Int(round(newSize)))"
        saveDebounced()
    }

    /// A double-tap fired inside a section header: ink triggers color the
    /// whole title (WW back to white), ## starts a fresh section right below.
    private func runTitleShortcut(_ ch: Character, in section: SectionView) {
        if ch == "#" {
            insertSection(after: section)   // saves via insertFreshSection
        } else {
            section.setTitleInk(name: Style.ink(for: ch)?.name)
            saveDebounced()
        }
    }

    /// Slide the swatch dots out from behind the ring, or tuck them back under.
    private func setInkTray(expanded: Bool) {
        guard expanded != inkTrayExpanded else { return }
        inkTrayExpanded = expanded
        if expanded { inkButtons.forEach { $0.isHidden = false } }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            for (i, dot) in inkButtons.enumerated() {
                let x = expanded ? inkRing.frame.minX + 18 + CGFloat(i) * 17
                                 : inkRing.frame.minX
                dot.animator().setFrameOrigin(NSPoint(x: x, y: dot.frame.origin.y))
                dot.animator().alphaValue = expanded ? 1 : 0
            }
        }, completionHandler: { [weak self] in
            // Hide only if the tray is still collapsed (guards a quick reopen
            // racing the collapse animation) so invisible dots can't eat clicks.
            guard let self, !self.inkTrayExpanded else { return }
            self.inkButtons.forEach { $0.isHidden = true }
        })
    }

    /// Ring click: back to the default white ink (recolors any selection too).
    /// While a section title is being edited, it clears that title's ink.
    @objc private func inkRingTapped() {
        if let s = activeTitleSection {
            s.setTitleInk(name: nil)
            saveDebounced()
            return
        }
        applyInk(nil)
    }

    /// Swatch click: switch to that ink and recolor any selected text. While a
    /// section title is being edited, it colors that title instead.
    @objc private func inkTapped(_ sender: NSButton) {
        if let s = activeTitleSection {
            s.setTitleInk(name: Style.inks[sender.tag].name)
            saveDebounced()
            return
        }
        applyInk(Style.inks[sender.tag].color)
    }

    /// Make `color` (nil = default white) the active ink: recolor the current
    /// selection, aim the typing attributes so the next character uses it, and
    /// refresh the ring/swatch chrome. Wrapped in shouldChangeText/didChangeText
    /// so recoloring a selection is undoable.
    private func applyInk(_ color: NSColor?) {
        ink = color
        for (i, b) in inkButtons.enumerated() {
            let active = ink == Style.inks[i].color
            b.layer?.borderWidth = active ? 2 : 1
            b.layer?.borderColor = NSColor(calibratedWhite: 1,
                                           alpha: active ? 0.95 : 0.35).cgColor
        }
        inkRing.layer?.backgroundColor = (ink ?? .clear).cgColor
        let target = ink ?? Style.textColor
        if let tv = activeText ?? firstTextView() {
            let range = tv.selectedRange()
            if range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) {
                tv.textStorage?.addAttribute(.foregroundColor, value: target, range: range)
                tv.didChangeText()
            }
            tv.typingAttributes[.foregroundColor] = target
            window.makeFirstResponder(tv)
        }
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
    /// Equivalent to "no block contributes a summary line."
    var isEmpty: Bool { currentSummary().isEmpty }

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

    /// Force every edit to use the chosen size and ink. AppKit resets the text
    /// view's typing attributes to the surrounding text after each keystroke,
    /// which is what made a bumped-up size silently fall back — this defeats
    /// that, and gives the same guarantee for color: no active swatch means
    /// you type white even with the cursor parked inside colored text.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        textView.typingAttributes[.font] = currentFont
        textView.typingAttributes[.foregroundColor] = ink ?? Style.textColor

        // Double-tap shortcuts: type the same trigger twice in a row (RR, YY,
        // BB, WW, ##) and both characters vanish, replaced by the action. The
        // location check means only back-to-back keystrokes count — a trigger
        // typed next to a pre-existing copy of itself doesn't fire.
        if let s = replacementString, s.count == 1, let ch = s.first,
           Style.shortcutTriggers.contains(ch) {
            if let p = pendingShortcut, p.char == ch,
               p.tv == ObjectIdentifier(textView),
               affectedCharRange.location == p.location + 1 {
                pendingShortcut = nil
                consumeShortcut(ch, in: textView, firstCharAt: p.location,
                                restoring: p.replaced)
                return false                    // swallow the second character
            }
            let replaced = affectedCharRange.length > 0
                ? textView.textStorage?.attributedSubstring(from: affectedCharRange)
                : nil
            pendingShortcut = (ch, affectedCharRange.location,
                               ObjectIdentifier(textView), replaced)
        } else if replacementString?.isEmpty == false {
            pendingShortcut = nil               // any other typing breaks the pair
        }

        // Backspacing the letter the auto-cap just uppercased reads as
        // "I wanted lowercase" — arm the one-shot bypass for that spot.
        let tvID = ObjectIdentifier(textView)
        if replacementString?.isEmpty == true, affectedCharRange.length == 1,
           let cap = lastAutoCap, cap.tv == tvID,
           cap.location == affectedCharRange.location {
            autoCapBypass = cap
            lastAutoCap = nil
        }

        // Auto-capitalize sentence starts: a lowercase letter typed at the
        // start of a block, right after a newline, or after end-of-sentence
        // punctuation plus a space comes out uppercase.
        if let s = replacementString, s.count == 1, let ch = s.first,
           ch.isLowercase, !textView.hasMarkedText(),
           startsSentence(at: affectedCharRange.location, in: textView) {
            // The bypass: this exact spot just had its auto-capital deleted,
            // so this letter goes in untouched.
            if let bp = autoCapBypass, bp.tv == tvID,
               bp.location == affectedCharRange.location {
                autoCapBypass = nil
                return true
            }
            let upper = s.uppercased()
            if textView.shouldChangeText(in: affectedCharRange, replacementString: upper) {
                textView.textStorage?.replaceCharacters(
                    in: affectedCharRange,
                    with: NSAttributedString(string: upper,
                                             attributes: textView.typingAttributes))
                textView.didChangeText()
                textView.setSelectedRange(
                    NSRange(location: affectedCharRange.location + (upper as NSString).length,
                            length: 0))
                // The uppercased letter isn't a deliberate capital — don't let
                // it arm a double-tap shortcut ("rR" must not fire red).
                pendingShortcut = nil
                lastAutoCap = (tvID, affectedCharRange.location)
            }
            return false
        }
        return true
    }

    /// Whether a character typed at `location` begins a sentence: the start
    /// of the block, right after a newline, or after . ! ? followed by
    /// whitespace. Walks back over any run of spaces first.
    private func startsSentence(at location: Int, in tv: NSTextView) -> Bool {
        let s = tv.string as NSString
        var i = location - 1
        var sawSpace = false
        while i >= 0 {
            guard let scalar = Unicode.Scalar(s.character(at: i)) else { return false }
            let char = Character(scalar)
            if char == " " || char == "\t" { sawSpace = true; i -= 1; continue }
            if char.isNewline { return true }
            return sawSpace && ".!?".contains(char)
        }
        return true                             // nothing before it — block start
    }

    /// Finish a fired double-tap: swap the first trigger character (the second
    /// was never inserted) back for whatever it replaced — a selection the
    /// first tap deleted, or nothing — re-select that text, and run the
    /// action, so an ink shortcut lands on the restored selection. Deferred a
    /// tick so the text view finishes the keystroke it's mid-way through
    /// before the storage mutates under it.
    private func consumeShortcut(_ ch: Character, in tv: NSTextView, firstCharAt location: Int,
                                 restoring replaced: NSAttributedString?) {
        DispatchQueue.main.async { [weak self, weak tv] in
            guard let self, let tv else { return }
            let restored = replaced ?? NSAttributedString()
            let del = NSRange(location: location, length: 1)
            if let ts = tv.textStorage, del.upperBound <= ts.length,
               tv.shouldChangeText(in: del, replacementString: restored.string) {
                ts.replaceCharacters(in: del, with: restored)
                tv.didChangeText()
            }
            // Cursor after the restored text for ##; the text itself
            // re-selected for the ink shortcuts so the color lands on it.
            // Clamped to the storage: if the guarded restore above was skipped,
            // the unclamped range could run past the end and raise.
            let len = (tv.string as NSString).length
            if ch == "#" {
                tv.setSelectedRange(NSRange(location: min(location + restored.length, len),
                                            length: 0))
                self.insertSection()
            } else {
                let loc = min(location, len)
                tv.setSelectedRange(NSRange(location: loc,
                                            length: min(restored.length, len - loc)))
                self.applyInk(Style.ink(for: ch)?.color)
            }
        }
    }

    /// Shift+Up / Shift+Down step the font size at the cursor (resizing the
    /// selection too, if there is one) — trades AppKit's line-wise selection
    /// extension for a quick size knob.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUpAndModifySelection(_:)):
            changeFont(by: +1)
            return true
        case #selector(NSResponder.moveDownAndModifySelection(_:)):
            changeFont(by: -1)
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            return backspaceAcrossBlocks(textView)
        default:
            return false
        }
    }

    /// Backspace with the cursor at the very start of a top-level text block:
    /// AppKit can't delete across separate text views, which is what made the
    /// blank line under a collapsed section undeletable. An empty block gets
    /// removed outright; a non-empty one merges into a preceding text block.
    /// Returns false to let the text view handle every normal backspace.
    private func backspaceAcrossBlocks(_ tv: NSTextView) -> Bool {
        let sel = tv.selectedRange()
        guard sel.location == 0, sel.length == 0,
              let col = column(containing: tv),
              let idx = col.stack.arrangedSubviews.firstIndex(where: { $0 === tv }),
              idx > 0 else { return false }
        let prev = blockViews(in: col)[idx - 1]

        if tv.string.isEmpty {
            removeBlockView(tv)
            focusEnd(of: prev)
            saveDebounced()
            return true
        }
        // Two adjacent top-level text blocks (left over from a deleted
        // section) → glue this one onto the end of the previous.
        if let prevTV = prev as? GrowingTextView, let ts = tv.textStorage {
            let joinAt = (prevTV.string as NSString).length
            prevTV.textStorage?.append(
                ts.attributedSubstring(from: NSRange(location: 0, length: ts.length)))
            prevTV.invalidateIntrinsicContentSize()
            removeBlockView(tv)
            prevTV.setSelectedRange(NSRange(location: joinAt, length: 0))
            window.makeFirstResponder(prevTV)
            saveDebounced()
            return true
        }
        // Previous block is a section: don't merge content into the fold,
        // just hop the cursor up into it.
        focusEnd(of: prev)
        return true
    }

    private func removeBlockView(_ v: NSView) {
        guard let col = column(containing: v) else { return }
        if let at = activeText, at === v { activeText = nil }
        col.stack.removeArrangedSubview(v)
        v.removeFromSuperview()
        ensureNonEmpty(col)
    }

    /// Put the cursor at the end of a block — a collapsed section takes focus
    /// on its title instead (its body view is hidden).
    private func focusEnd(of block: BlockView) {
        if let sv = block as? SectionView, sv.isCollapsed {
            sv.focusTitle()
            return
        }
        let tv = block.primaryTextView
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        window.makeFirstResponder(tv)
    }

    /// Track which block is active and the size at its cursor/selection so
    /// `currentFont`, the stepper, and the readout follow what you're editing.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        activeText = tv
        activeTitleSection = nil    // cursor is back in a body block
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
    func windowDidBecomeKey(_ notification: Notification) {
        applyTint(focused: true)
        restoreCursor()
    }

    /// Coming back from another app puts the cursor right back where it was —
    /// no re-clicking into the text and hunting for your spot. The text view
    /// keeps its selection while the window is idle; this just re-arms it as
    /// first responder and scrolls the caret into view. A section title gets
    /// its cursor parked at the end instead (re-focusing a text field selects
    /// everything, and typing would then wipe the title).
    private func restoreCursor() {
        if let s = activeTitleSection {
            s.focusTitle()
            if let ed = window.fieldEditor(false, for: nil) as? NSTextView {
                ed.setSelectedRange(NSRange(location: (ed.string as NSString).length, length: 0))
            }
            return
        }
        guard let tv = activeText, tv.window === window else { return }
        if window.firstResponder !== tv { window.makeFirstResponder(tv) }
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    func windowDidResignKey(_ notification: Notification) {
        applyTint(focused: false)
        store.saveNow(snapshot())
    }

    func windowDidMove(_ notification: Notification) {
        saveDebounced()
        manager?.noteDidMove(self)      // might be a drag toward another note
    }
    func windowDidResize(_ notification: Notification) { saveDebounced() }

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
    // Drag-to-dock state: the note being dragged, the ~30Hz mouse watcher,
    // and the note edge currently glowing as the merge target.
    private weak var draggingNote: NoteController?
    private var dockTimer: Timer?
    private var dockCandidate: (target: NoteController, side: DockSide)?
    // Set during a tear-out drag so the freshly extracted note can't dock
    // straight back into the note it was just pulled from.
    var dockingSuppressed = false

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

    // MARK: drag-to-dock (conjoining notes)

    /// A note window moved. If the user is mid-drag, start watching the mouse
    /// at ~30Hz: while the button is down, glow whichever other note's edge it
    /// hovers; when it lifts inside a dock zone, conjoin the two notes. The
    /// window server handles the drag itself (isMovableByWindowBackground), so
    /// polling is the one reliable way to see both the hover and the release —
    /// windowDidMove stops firing whenever the mouse pauses.
    func noteDidMove(_ c: NoteController) {
        guard !dockingSuppressed,
              NSEvent.pressedMouseButtons & 1 != 0 else { return }  // programmatic setFrame
        draggingNote = c
        guard dockTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.dockTick()
        }
        // .common, not scheduledTimer: window drags can hold the run loop in
        // event-tracking mode, where a default-mode timer never fires.
        RunLoop.main.add(t, forMode: .common)
        dockTimer = t
    }

    private func dockTick() {
        guard let dragged = draggingNote, NSEvent.pressedMouseButtons & 1 != 0 else {
            finishDrag()
            return
        }
        // Magnet test on the windows themselves, not the mouse: the dragged
        // note's near edge sitting over (or within a small gap of) a target's
        // edge — with real vertical overlap — reads as "wants to join". The
        // mouse can be anywhere on the dragged note.
        let df = dragged.windowRef.frame
        var found: (NoteController, DockSide)?
        // Front-to-back (orderedIndex 0 is frontmost — NSApp.orderedWindows
        // can omit panels), so stacked notes resolve to the one on top.
        for target in controllers.sorted(by: { $0.windowRef.orderedIndex < $1.windowRef.orderedIndex }) {
            guard target !== dragged, target.windowRef.isVisible else { continue }
            let f = target.windowRef.frame
            let overlapY = min(df.maxY, f.maxY) - max(df.minY, f.minY)
            guard overlapY >= min(60, min(df.height, f.height) / 3) else { continue }
            // Dragged sits to the right: its left edge anywhere from the
            // target's midline to a 40pt gap past its right edge.
            if df.minX > f.midX, df.minX < f.maxX + 40 { found = (target, .right); break }
            // Mirrored for the left side.
            if df.maxX < f.midX, df.maxX > f.minX - 40 { found = (target, .left); break }
        }
        if dockCandidate?.target !== found?.0 || dockCandidate?.side != found?.1 {
            dockCandidate?.target.showDockGlow(nil)
            dockCandidate = found.map { (target: $0.0, side: $0.1) }
            dockCandidate?.target.showDockGlow(dockCandidate?.side)
        }
    }

    /// The drag ended (mouse up). If it ended over a dock zone, merge.
    private func finishDrag() {
        dockTimer?.invalidate()
        dockTimer = nil
        let candidate = dockCandidate
        dockCandidate = nil
        candidate?.target.showDockGlow(nil)
        let dragged = draggingNote
        draggingNote = nil
        guard let dragged, let (target, side) = candidate else { return }
        commitMerge(dragged: dragged, into: target, side: side)
    }

    /// Conjoin: the dragged note's columns join `target` on `side`, the window
    /// grows to fit both, and the dragged note (window + file) is absorbed.
    private func commitMerge(dragged: NoteController, into target: NoteController, side: DockSide) {
        let cols = dragged.snapshotColumns()
        let t = target.windowRef.frame
        let d = dragged.windowRef.frame
        let w = t.width + d.width
        let h = max(t.height, d.height)
        let x = side == .right ? t.minX : t.maxX - w
        dragged.discard()                       // close without saving
        NoteStore(id: dragged.id).delete()      // its content lives in target now
        target.adoptColumns(cols, on: side,
                            frame: NSRect(x: x, y: t.maxY - h, width: w, height: h))
        target.focus()
    }

    /// A column torn out of a conjoined note becomes its own note under the
    /// cursor. The caller (dragOutColumn) keeps it following the mouse.
    @discardableResult
    func spawnExtractedNote(blocks: [Block], fontSize: CGFloat, size: NSSize) -> NoteController {
        var data = NoteData(id: UUID().uuidString, fontSize: fontSize, blocks: blocks)
        let mouse = NSEvent.mouseLocation
        data.frame = [mouse.x - size.width / 2, mouse.y - size.height + 20,
                      size.width, size.height]
        let c = open(data)
        c.flush()                               // its file exists on disk right away
        c.windowRef.makeKeyAndOrderFront(nil)
        return c
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

        let heads = NoteStore.loadHeads()
        let openByID = Dictionary(controllers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        if heads.isEmpty {
            let empty = NSMenuItem(title: "No saved notes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Notes", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for head in heads {
                let mi = noteItem(head, open: openByID, action: #selector(switchToNote(_:)))
                mi.state = openByID[head.id] != nil ? .on : .off   // ✓ = currently open
                menu.addItem(mi)
            }

            // Delete submenu — pick a note here to remove it (with a confirm
            // popup). Keeps the main list a pure one-click "open".
            menu.addItem(.separator())
            let deleteParent = NSMenuItem(title: "Delete Note", action: nil, keyEquivalent: "")
            let deleteMenu = NSMenu()
            for head in heads {
                deleteMenu.addItem(noteItem(head, open: openByID, action: #selector(deleteNoteItem(_:))))
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

    /// A menu item for one saved note — the live title if it's open, else the
    /// on-disk title — carrying the note id for `action`.
    private func noteItem(_ head: (id: String, title: String),
                          open: [String: NoteController], action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: open[head.id]?.displayTitle ?? head.title,
                            action: action, keyEquivalent: "")
        mi.target = self
        mi.representedObject = head.id
        return mi
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
    // Undo/Redo travel the responder chain to the focused view's undo manager
    // — without these items Cmd+Z never dispatches at all.
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
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

// Kill the system's double-space → period substitution app-wide: the
// per-view text-replacement flag doesn't cover it on every macOS build, and
// an app-domain default beats the global System Settings pref.
UserDefaults.standard.set(false, forKey: "NSAutomaticPeriodSubstitutionEnabled")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, no app-switcher tile
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = makeMainMenu()
app.run()
