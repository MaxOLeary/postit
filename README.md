<h1 align="center">Postit</h1>
<p align="center">
  <img src="icon.png" width="128" alt="Postit app icon">
</p>

Post-it notes for the Mac. Translucent glass notes that sit on your desktop.

<img src="screenshot.png" alt="A Postit note on the desktop, showing colored ink and a collapsible section" width="560">

## Download

**[Download Postit](https://github.com/MaxOLeary/postit/releases/latest/download/Postit.zip)**

1. Open the downloaded ZIP.
2. Drag **Postit** into your **Applications** folder and open it.
3. The first time, macOS will warn that the app is from an unidentified
   developer. Right-click the app, choose **Open**, then click **Open** again.
   This only happens once.

Postit lives in the menu bar at the top of the screen. There is no Dock icon.

Works on macOS 11 or later. The glass look needs macOS 26; older versions get
a simpler blur.

## What it does

- Notes save themselves as you type and come back exactly where you left them.
- Colored ink: red, green, and blue, from the toolbar ring or by typing `RR`,
  `GG`, or `BB` (`WW` returns to white).
- Collapsible sections with titles. Type `##` to insert one.
- Bullet lists: type `- ` at the start of a line. Tab nests, Enter on an
  empty bullet ends the list.
- A live calculator: type `:math` on a line and the lines below it are
  computed as you type. Percentages, units, and currency all work. `:end`
  turns it off.
- Merge notes: drag one note onto another's edge and hold. They join into
  columns. Pull a column back out by the handle at its top.
- Every note has a drawer on its left edge listing all your notes; the menu
  bar icon lists them too.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `RR` / `GG` / `BB` | red / green / blue ink |
| `WW` | back to white |
| `##` | insert a section |
| `- ` at the start of a line | bullet list |
| Cmd+= / Cmd+- | bigger / smaller text |
| `:math` on its own line | calculator (`:end` stops it) |

Standard ones work as expected: Cmd+N new note, Cmd+W close, Cmd+Z undo,
Cmd+Q quit. The welcome note on first launch walks through all of this.

## For developers

The entire app is one Swift file, `Swift/main.swift`. It builds with `swiftc`
alone; there is no Xcode project and there are no dependencies.

```bash
cd Swift && ./build.sh
```

Notes are stored one JSON file each in
`~/Library/Application Support/Postit/notes/`. To also keep a plain Markdown
copy of every note in a folder of your choice:

```bash
defaults write com.maxoleary.postit MDMirrorFolder ~/somewhere
```

## License

MIT
