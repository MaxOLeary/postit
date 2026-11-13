Windows build. Python 3.12 or newer. PySide6 comes from Qt (Finland) on PyPI.

```bat
cd postit
py -3 -m venv qt\.venv
qt\.venv\Scripts\python -m pip install -r qt\requirements.txt
qt\.venv\Scripts\python qt\main.py --check
qt\.venv\Scripts\python qt\main.py
```

`--check` has to print `CHECK OK`. Then `qt\main.py` with no arguments opens the tray app. Notes are one JSON file each in `%APPDATA%\Postit\notes`. That folder is created on first launch. Set `POSTIT_NOTES_DIR` to use a different folder.

On macOS the same app is `qt/.venv/bin/python qt/main.py`. With `POSTIT_NOTES_DIR` unset, macOS writes `qt/dev-notes/` unless `POSTIT_PLATFORM_NOTES=1`, which is the only switch that points it at `~/Library/Application Support/Postit/notes`. Linux uses `~/.local/share/Postit/notes`.

This is the notes app. It reads and writes the same JSON the Mac app uses. There is no installer exe in this tree.
