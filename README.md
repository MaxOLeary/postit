# Postit Todo

Liquid-glass desktop post-it notes for macOS.

## THE app (read this first)

**The real app is the Swift one: `Swift/main.swift` → `Postit.app`.**
It's the dark glassy multi-note app Max actually runs daily (menu-bar icon,
font stepper, note switcher, collapsible sections). When Max says "apply it
to the app," "the postit app," or "relaunch," he means this one.

To apply a change:

```bash
# 1. edit Swift/main.swift
# 2. build + install + relaunch (script kills the running app and
#    reinstalls to /Applications/Postit.app):
cd Swift && ./build.sh
open /Applications/Postit.app
# 3. snapshot the new version:
cp Swift/main.swift versions/main_v<N>_<feature>.swift
```

Notes are saved per-note as JSON (with base64 RTF bodies, so rich text and
colors persist) under `~/Library/Application Support/Postit/notes/`.

## The Python version (prototype, NOT the app)

`postit.py` (launched by `Postit.command`) is the earlier PySide6 prototype.
It still works and sometimes gets features first as a sketch, but shipping a
feature means porting it to `Swift/main.swift` and rebuilding. Its note lives
in `note.json` next to the script.

## Versions

`versions/` holds a snapshot per milestone: `postit_v*.py` for the Python
line, `main_v*.swift` for the Swift line (current as of v29: ink swatches).
Snapshot before/after meaningful changes so any state is recoverable.
