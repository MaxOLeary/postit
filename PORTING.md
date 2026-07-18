# Porting Postit to Windows / Linux

This document is the platform-independent spec of Postit. Together with
`Swift/main.swift` (the entire app, heavily commented, with a file map at the
top) it contains everything needed to rebuild the app on another OS with
identical functionality and look.

**How to use it:** on the target machine, clone this repo and work from these
two files. `main.swift` is the source of truth for exact behavior — every
non-obvious decision is explained in a comment where it's implemented. This
file tells you which parts are macOS-specific, what to substitute for them,
what must round-trip byte-for-byte (the data format), and how to know the
port is done (the acceptance checklist at the bottom).

## What the app is

Frameless, dark, semi-transparent sticky notes that float on the desktop.
No taskbar/Dock presence — the app lives in a menu-bar / system-tray icon and
the notes themselves. Each note auto-saves everything (rich text, position,
size, font) and restores across launches.

## Non-negotiables (identical on every platform)

These define the product. A port that changes any of them isn't Postit:

1. **The note look.** Dark rounded-corner (26px radius) translucent panel, no
   title bar, no window frame. On platforms without a live-blur material, a
   flat semi-transparent dark fill is acceptable (that is already the app's
   own fallback below macOS 26 — match `Style.idleTint` over ~55% black).
2. **Direct manipulation.** Drag anywhere on the note background to move it;
   drag edges/corners to resize. Text editing never fights window dragging.
3. **The block model.** A note body is a vertical stack of blocks: freeform
   rich-text blocks and collapsible sections (a bold editable title with a
   fold triangle + a rich-text body). Sections insert at the cursor,
   splitting the text block there.
4. **The typing feel.** All of: double-tap shortcuts (RR/YY/BB/WW/##),
   sentence auto-capitalization with the backspace-retype and Shift
   bypasses, Shift+Up/Down font stepping at the cursor, ink follows the
   cursor color (Google-Docs style). Exact rules live in the
   `text delegate` section of `main.swift`.
5. **Conjoining.** Drag a note onto another's left/right edge, hold ~0.9s,
   the edge glows, release to merge into one window with side-by-side
   columns. Columns separate again by dragging the pill grip at a column's
   top-right. Dividers between columns drag to resize the split
   (160px minimum column width), and the split ratio persists.
6. **The data format** (next section). A notes folder written by the macOS
   app should open on Linux/Windows and vice versa.

## Data format (must stay compatible)

One JSON file per note. On macOS they live in
`~/Library/Application Support/Postit/notes/<uuid>.json`; use the platform's
equivalent app-data directory (`%APPDATA%\Postit\notes` on Windows,
`~/.local/share/Postit/notes` on Linux).

```jsonc
{
  "id": "UUID string",
  "text": "plain-text summary (first lines; feeds the switcher title)",
  "fontSize": 15,                  // last-chosen size, points
  "frame": [x, y, w, h],           // screen coords; [] = unset (default size)
  "blocks": [ ... ],               // single-column note body, or null
  "columns": [[ ... ], [ ... ]],   // conjoined body: one block list per column, or null
  "columnWeights": [0.6, 0.4],     // per-column width fractions, or null = equal
  "rtf": "base64"                  // legacy single-body field; read, never required
}
```

Each block:

```jsonc
{
  "kind": "text" | "section",
  "rtf": "base64 RTF of the body",  // rich text: color + font size runs
  "text": "plain fallback of the body",
  "title": "section header",        // sections only
  "collapsed": false,               // sections only
  "titleSize": 15,                  // section title font pt, null = default
  "titleInk": "Red"                 // section title color by swatch name, null = white
}
```

Rules:

- Exactly one of `blocks` / `columns` is set; a conjoined note that drops to
  one column saves as plain `blocks` again.
- `rtf` is base64-encoded RTF. On non-Apple platforms use a rich-text engine
  that can read and write RTF (Qt's `QTextDocument` can do both). If that is
  truly impractical, keep writing valid `rtf` for the blocks you touch and
  always maintain `text` — but RTF round-trip is strongly preferred, since
  it is what makes a notes folder portable between the ports.
- Unknown fields must survive load→save untouched or at worst be dropped
  only after a faithful migration; never crash on legacy files (missing
  `blocks`, only `rtf`+`text`).
- Saves are debounced (~0.6s after the last keystroke) and flushed on close
  and quit.

Optional: the Markdown mirror. If a folder is configured (macOS: the
`MDMirrorFolder` user default; use a small config file or env var
elsewhere), every save also writes a one-way readable
`<title-slug>-<id6>.md` copy — sections become `##` headers, columns are
split by `---`.

## The look, in numbers

`Style` at the top of `main.swift` is the complete design-token table —
port it as a unit. Highlights:

| Token | Value |
| --- | --- |
| Default note size | 320 × 340 |
| Corner radius | 26 |
| Content padding | 14 |
| Top strip height | 30 |
| Text color | white at 97% |
| Chrome (buttons) color | white at 55% |
| Idle tint over blur | black-ish `(0.16, alpha 0.18)` |
| Focused tint | white `(0.85, alpha 0.12)` |
| Selection highlight | translucent blue `rgba(0.36, 0.52, 0.92, 0.40)` |
| Ink red / yellow / blue | `#D6382C` / `#F2E23A` / `#58B0EC` |
| Default / min / max font | 15 / 10 / 40 pt, system UI font |
| Min column width | 160 |
| Column grip | 28×4 pill, top-right of each column |
| Divider gutter | 14 + 1px line + 14, line = white at 14% |
| Dock dwell before merge arms | 0.9 s |
| Dock magnet zone | edge midline → 40px past the edge, ≥60px vertical overlap |

Toolbar, left to right: `+` (new note), font up/down chevrons with live
numeric readout, `▸` insert-section, the ink tray (hollow ring that fills
with the active ink; hovering slides three swatch dots out to the right),
then at the right edge: note switcher (list icon) and `✕` close.

## macOS-specific pieces → substitutions

| In `main.swift` | What it does | Acceptable substitute |
| --- | --- | --- |
| `NSGlassEffectView` (macOS 26) | Liquid Glass material | Not required. Use the app's own fallback: blurred translucent dark panel if the platform offers it (KDE/Windows acrylic), else flat semi-transparent dark fill |
| `NSVisualEffectView` fallback | translucent blur | same as above |
| `GlassWindow` (`NSPanel`, borderless, non-activating) | frameless window that takes keyboard without stealing app focus | any frameless, per-pixel-translucent window (Qt: `FramelessWindowHint` + `WA_TranslucentBackground`) |
| `isMovableByWindowBackground` | drag background to move | hand-rolled: mouse-down on non-text chrome starts a window move |
| Edge resize on a borderless window | system-provided | hand-rolled edge hit-zones with resize cursors |
| `NSStatusItem` menu bar icon | the app's only persistent UI | system tray icon (`QSystemTrayIcon`); same menu: note list rows (click title = open, click the row's ✕ = delete with confirm), separator, Quit |
| `LSUIElement` | no Dock icon | no taskbar entry / tray-only mode |
| RTF via `NSAttributedString` | rich text storage | `QTextDocument` RTF read/write, or equivalent |
| Field editor / responder-chain tricks | focus and selection routing | native equivalents; the *behaviors* (hover-to-wake, cursor restored on refocus, font readout follows cursor) are what must survive |
| SF Symbols (chevrons, xmark, list.bullet) | toolbar glyphs | any matching thin-line glyph set, or drawn paths |
| `defaults` (`MDMirrorFolder`) | mirror folder setting | config file in the app-data dir |

Multi-window behaviors to preserve: hover a note ~a beat and it wakes with
the cursor where you left it; closing the last note leaves the app running
in the tray; on launch, only the most recently edited note reopens (others
stay on disk, reachable from the switcher); "+" cascades the new note
26px down-right of the frontmost.

## Suggested approach

Recommended stack for the port: **Python + PySide6 (Qt)** — this repo's
`postit.py` is an early Qt prototype of this very app, so the window
scaffolding (frameless translucent window, drag-to-move) already exists as
reference code. Qt covers every substitution in the table above, including
RTF, on both Windows and Linux. Any stack meeting the non-negotiables is
fine; steer by the acceptance checklist, not the toolkit.

Suggested order of attack (each step ends runnable):

1. Frameless translucent rounded window: move by background, edge resize,
   the top strip with working `+` and `✕`.
2. One rich-text block: typing, ink colors, font stepping, selection
   highlight; JSON save/load with RTF round-trip against a file the macOS
   app wrote.
3. Blocks: collapsible sections, insert-at-cursor, section titles.
4. Typing feel: double-tap shortcuts, auto-cap + bypasses, ink follows
   cursor.
5. Tray icon + switcher menu + multi-note + most-recent restore.
6. Conjoining: dock-drag detection, glow, merge, grips, resizable dividers,
   tear-out.
7. Markdown mirror, hover-to-wake, polish pass against the checklist.

## Acceptance checklist

The port is done when all of these hold:

- [ ] A notes folder copied from a Mac opens with content, colors, sizes,
      folds, columns, and split ratios intact — and edits made on the port
      open back on the Mac.
- [ ] Every row of the Shortcuts table in `README.md` works, including the
      auto-cap bypasses (backspace-and-retype stays lowercase; Shift+letter
      at a sentence start stays lowercase).
- [ ] Clicking into colored text continues typing in that color; the ink
      ring/swatches track the cursor.
- [ ] Two notes conjoin by edge-drag + dwell (glow first), the divider
      drags to resize with a 160px floor, the ratio survives relaunch, and
      the grip tears a column back out under the mouse.
- [ ] Tray menu = note list (click opens, ✕ deletes with confirmation) +
      Quit; deleting removes the file; quit flushes unsaved edits.
- [ ] Only the most recently edited note reopens on launch; the rest are
      listed in the switcher.
- [ ] Side-by-side with the Mac app (or `screenshot.png`), a stranger can't
      tell which is which apart from the blur material.
