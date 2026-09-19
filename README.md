<h1 align="center">Postit</h1>
<p align="center">
  <img src="icon.png" width="128" alt="Postit app icon">
</p>

Post-it notes for the Mac. Translucent glass notes that sit on your desktop.

<img src="screenshot.png" alt="The Postit welcome note on the desktop, with the note drawer open and the meetings section expanded" width="560">

## Download

**[Download Postit](https://github.com/MaxOLeary/postit/releases/latest/download/Postit.zip)**

1. Open the downloaded ZIP.
2. Drag **Postit** into your **Applications** folder and open it.

<!-- remove after notarization -->
The first open shows a warning: "Apple could not verify Postit is free of
malware". Click **Done**. Never click **Move to Trash**. Then:

1. Open **System Settings**, then **Privacy & Security**.
2. Scroll down to the **Security** section. Click **Open Anyway** next to
   the line about Postit.
3. Confirm with Touch ID or your password, then open Postit again.

That is it, once. Postit is signed with an in-house certificate, not yet
an Apple one, so macOS can see who signed it but cannot check it against
Apple's list. (Right-clicking the app and choosing Open does not work on
macOS 15 or later, so skip that trick.)

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
- Checklists: type `[] ` at the start of a line. Click the box to tick it
  off; done lines get struck through.
- A live calculator: type `:math` on a line and the lines below it are
  computed as you type. Percentages, units, and currency all work. `:end`
  turns it off.
- Merge notes: drag one note onto another's edge and hold. They join into
  columns. Pull a column back out by the handle at its top.
- Every note has a drawer on its left edge listing all your notes; the menu
  bar icon lists them too.

## Meetings

Install [Whisper](https://github.com/MaxOLeary/whisper) too (Apple Silicon,
macOS 14 or later) and a speech bubble appears in Postit's toolbar and menu.
Click it to record a meeting. When you stop, the notes and the transcript land
as a new sticky. Without Whisper the bubble stays hidden.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `RR` / `GG` / `BB` | red / green / blue ink |
| `WW` | back to white |
| `##` | insert a section |
| `- ` at the start of a line | bullet list |
| `[] ` at the start of a line | checkbox (click it to tick it off) |
| Cmd+Shift+L / Cmd+Shift+D | checklist on/off / mark done |
| Cmd+= / Cmd+- | bigger / smaller text |
| `:math` on its own line | calculator (`:end` stops it) |

Standard ones work as expected: Cmd+N new note, Cmd+W close, Cmd+Z undo,
Cmd+Q quit. The welcome note on first launch walks through all of this.

## For developers

The entire app is one Swift file, `Swift/main.swift`. It builds with `swiftc`
alone; there is no Xcode project and there are no dependencies.

```bash
cd Swift && ./build.sh          # builds, signs, installs /Applications/Postit.app
cd Swift && ./build.sh --ship   # also verifies, refreshes the committed Postit.app, uploads the release
```

`--ship` needs the signing cert on this Mac.

Notes are stored one JSON file each in
`~/Library/Application Support/Postit/notes/`. To also keep a plain Markdown
copy of every note in a folder of your choice:

```bash
defaults write com.maxoleary.postit MDMirrorFolder ~/somewhere
```

## License

MIT
