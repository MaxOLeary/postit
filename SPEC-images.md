# SPEC: images in notes

Status: draft, waiting on Max's OK. No code until approved.

## Goal
Get images into a sticky three ways: paste (Cmd+V), drag a file from Finder, or drag straight from another app (Zen, Preview). Each image fits the note width and resizes when you drag its corner. The Markdown mirror copies the image files and links them with `![](...)`, so Obsidian shows them.

Right now an image would vanish without a warning. `GrowingTextView.rtfBase64` saves plain RTF, and plain RTF drops attachments.

## Design

**Storage: image files live outside the JSON.**
- Each image is saved once to `~/Library/Application Support/Postit/images/<sha256>.<ext>` with mode 0600. The sha256 name means the same image pasted twice is stored once.
- Why not RTFD? It would stuff megabytes of base64 into the note JSON, and that file gets rewritten 0.4s after every keystroke.
- PNG, JPEG and GIF files keep their original bytes. TIFF and other pasteboard images get converted to PNG.

**Model.**
- Add `images: [ImageRef]?` to `Block` (`main.swift:731`).
- `ImageRef` is `{ at: Int, file: String, width: CGFloat }`.
- `at` is a UTF-16 offset into the block's stripped text. "Stripped" means the attachment characters are taken out, so it matches the saved `text` and `rtf` exactly.
- Old notes decode unchanged, because the new field is optional.

**Save and load.**
- A new helper sits next to `rtfBase64` / `asBlock` (`:2685`, `:2804`, and the section body's `asBlock` at `:3236`). It walks the text storage, pulls out each attachment, records its `ImageRef`, and builds RTF and plain text from the stripped copy.
- `load(rtfData:plain:fontSize:)` (`:2667`) takes the image refs too and puts attachments back in ascending `at` order.
- If an image file is missing, show a small grey "missing image" box instead of crashing.

**Display and resize.**
- A small `NSTextAttachmentCell` subclass (a TextKit 1 attachment cell, since the view is pinned to TextKit 1) draws the image at `min(width, container width)`, keeping the aspect ratio.
- On hover, a corner handle appears on the image. In `GrowingTextView.mouseDown` (`:2754`), a press on that handle starts a resize drag instead of a text selection. The same spot already has a checklist-box hit test that can serve as the pattern.
- The resize width is clamped between 40pt and the container width. The new width goes through `shouldChangeText`/`didChangeText`, so undo and save work for free.

**Input.**
- `paste` (`:2695`) checks the pasteboard in this order: image file URLs, then raw image data (`.png`/`.tiff`), then RTFD that carries attachments (copying an image between notes), then the existing RTF path, then plain text.
- Dropping from Finder or another app: the text view also registers `.fileURL`, `.png` and `.tiff` for drags. `performDragOperation` (`:2781`) handles image drops that come from outside Postit. Text drags between Postit's own blocks keep their current behavior.
- Everything goes through one `ImageStore.importImage(data:or url:) -> ImageRef` helper.

**Things that would break if skipped.**
- `NoteData.isBlank` (`:780`): a note holding only an image must not count as blank. If it did, the launch sweep (`deleteBlankSaved`, `:1119`) would delete it.
- `summaryText` / `displayTitle` should skip the U+FFFC attachment character. A note that is only an image gets the title "Image".
- Text drags that carry an image between blocks keep the image, because the pasteboard is RTFD. Check this during the drag work.

**Markdown mirror.**
- `NoteStore.markdown(for:)` (`:1042`) writes `![](postit-images/<file>)` on its own line at each `at` offset.
- `writeMirror` (`:1055`) copies any image files the mirror is missing into `<mirror>/postit-images/`. Existing copies are skipped because the names are hashes.

**Cleanup.**
- At launch, next to `deleteBlankSaved`, delete image files that no saved note references anymore.
- Same for mirror `postit-images/` files. This is app runtime cleanup of the app's own cache, which is the same kind of thing `deleteBlankSaved` already does.
- Only runs at launch, so undoing an image delete during a session never points at a file that's gone.

## Stages (run one at a time, each checked in the running app)
1. [x] **Storage and round-trip.** `ImageStore`, `ImageRef`, the attachment cell, save/load, and the `isBlank`/title fixes.
2. [ ] **Input.** Paste, Finder drop, drop from another app, and copying or dragging an image between notes.
3. [ ] **Resize handle.**
4. [ ] **Mirror and cleanup.** Mirror image files and links, plus the launch cleanup sweep.
5. [ ] **Ship prep.** Snapshot to `versions/main_v<N>_images.swift` and add images to the README features list. Bump `VERSION` to 1.6 only on a ship.

## Done when
- Paste a screenshot, drag a .jpg from Finder, and drag an image from Zen. Each one shows up at note width.
- Dragging the corner resizes the image, and Cmd+Z undoes the resize.
- Quit and relaunch: images and their sizes are still there. Old text-only notes look exactly the same.
- A note holding only an image survives a relaunch.
- The mirror `.md` links the image, and Obsidian shows it.
- Delete an image and relaunch: the orphaned file in `images/` is gone.
- The note JSON stays small. No image bytes go in it.
