# Quiet toolbar with an Aa style menu

Goal:
Replace the always-on 30-point tool strip with a quiet glass pill on the top edge, like the format button in Apple Notes. At rest the note shows a thin pill. When the pointer is on the note, the pill eases open into one bar of large tools: New, Drop down, Aa, Debrief, and Close. Aa opens one dropdown that holds all text formatting, so the old Color and Size buttons go away.

The Aa dropdown, top to bottom (modeled on the Apple Notes screenshots from 2026-10-08):
- A row of toggles: **B**, *I*, U, then a color dot. A toggle lights up when the selection already has that style.
- The color dot opens a small side menu: Red, Green, Blue (the current inks, same colors), plus White to go back to default. The dot shows the selection's current ink.
- Paragraph styles, one checkmark on the current one: Title, Heading, Subheading, Body, Monostyled. Each row is drawn in its own style.
- A divider, then lists: Bulleted List, Dashed List, Numbered List.

Paragraph styles (starting values, tune by eye):
- Title: 28 pt bold.
- Heading: 22 pt bold.
- Subheading: 17 pt semibold.
- Body: 15 pt regular (today's `Style.defaultFont`).
- Monostyled: 14 pt system monospaced.
Font: note text uses **Libron** (Nico Verbruggen, OFL license, https://github.com/nicoverbruggen/libron) in Regular, Italic, Bold, and Bold Italic, everywhere except Monostyled. Bundle the four TTFs plus the OFL text inside `Postit.app` so people who download the zip get it too. The OFL allows bundling. Libron is the default for new notes. Old notes that saved the system font switch to Libron when they load. Bar labels and menu chrome stay in the system font.
A style applies to the whole paragraph the cursor is in, or every paragraph the selection touches. It keeps bold/italic/underline and ink that are already on the text.

Out of scope:
The menu-bar icon and its menu. Strikethrough, highlighter, and block quote. New ink colors. Shipping a GitHub release. The section header field (it keeps its own size).

Keep working exactly as today:
Keyboard shortcuts Cmd+T, Cmd+W, `##`, RR / GG / BB / WW, and Cmd+= / Cmd+- for size. Typing `- ` or `* ` still starts a bullet, Tab / Shift+Tab still nest it. Old notes open with their sizes and inks unchanged. Add Cmd+B, Cmd+I, Cmd+U if they don't already work.

Architecture (short):
The live app is `Swift/main.swift`. Notes are RTF in `GrowingTextView`, so bold, italic, underline, size, and font family already save and load with no format change. Today a 30-point strip (`Style.stripHeight`) holds the plus, the section chevron, the ink ring (`InkTab`), the size button, the meeting bubble, and close. Ink and size open hanging glass menus (the hanging-panel class around line 511); the Aa dropdown reuses that look.

The resting pill is about 90 by 13, centered on the top edge. Opening eases it into the bar over about 0.4 seconds, no bounce. Open targets are about 44 points with the word under the mark. Debrief stays hidden when Whisper is not installed. At rest only the pill's height comes out of the note; the first line moves down while the bar is open so the bar never covers it.

Bulleted List reuses `Bullets` as is. Dashed List and Numbered List are new prefixes built the same way (glyph-plus-space prefix with a hanging indent), so the Markdown mirror can turn them into `- ` and `1. `. Numbers renumber themselves when a line is added or removed. Picking a list row on a line that already has that list turns it off.

Markdown mirror: Title / Heading / Subheading paragraphs become `#` / `##` / `###`, Monostyled becomes a code span or fenced block, bold/italic become `**` / `*`. Underline and ink are dropped, same as ink is today.

Stages:
- [ ] 1. Resting pill and the open bar, with New, Drop down, Debrief, and Close calling the actions that exist today. Aa is present but opens nothing yet.
- [ ] 2. Aa dropdown with the B / I / U toggles and the color side menu, replacing the old ink ring and size button. Toggles reflect the selection.
- [ ] 3. The five paragraph styles, with the checkmark tracking the cursor's paragraph.
- [ ] 4. Lists: Bulleted (existing code), Dashed, Numbered with auto-renumbering.
- [ ] 5. Markdown mirror learns headings, mono, bold/italic, dashed and numbered lists.
- [ ] 6. `cd Swift && ./build.sh`, relaunch, and run the check below on a fresh note and an old note.

Verification (how we will know each stage worked):
Stage 1: a note shows the thin pill, the pointer opens the labeled bar, and the four tools do what the old buttons did. Debrief is hidden with Whisper absent.
Stage 2: select a word, hit B, it goes bold and B lights up; same for I and U. Pick Red from the color menu and the word turns the same red RR gives. Cmd+B/I/U match the buttons.
Stage 3: put the cursor in a line, pick Heading, the whole line becomes heading and reopening Aa shows the check on Heading. Quit and relaunch, it's still a heading.
Stage 4: each list row turns lines into that list and back off. Delete a middle numbered line and the numbers close up.
Stage 5: the mirror `.md` file shows `#`, `##`, `**bold**`, `- `, `1. ` where expected.
Stage 6: app rebuilds and relaunches; an old note looks unchanged; both pill states are visible. There are no automated tests.

Current stage:
Spec rewritten 2026-10-08 for the Aa menu. Waiting for Max to say go. Nothing in the app has changed.
2026-10-19: Libron font built ahead of the stages. Four TTFs + OFL.txt in `Swift/fonts/`, copied to `Contents/Resources/Fonts` by build.sh and registered via `ATSApplicationFontsPath`. `Style.noteFont` is the note-text font; `Style.libronize` converts old notes on load (keeps size, bold, italic; skips monospaced). Section headers and chrome stay system font. Toolbar stages 1-6 still not started.
