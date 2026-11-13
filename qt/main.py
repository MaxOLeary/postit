"""Frameless dark note window. Text and section blocks load and save RTF."""

import base64
import ctypes
import json
import os
import shutil
import sys
import tempfile
import traceback
import uuid
from pathlib import Path

from PySide6.QtCore import QEvent, QPoint, QRect, Qt, QTimer
from PySide6.QtGui import (
    QColor,
    QFont,
    QIcon,
    QKeyEvent,
    QPainter,
    QPainterPath,
    QPalette,
    QPixmap,
    QTextCharFormat,
    QTextCursor,
    QTextDocument,
)
from PySide6.QtWidgets import QApplication, QMenu, QPushButton, QSystemTrayIcon, QTextEdit, QWidget

RADIUS = 26
EDGE = 8
FILL = QColor(28, 28, 30, 210)
INK_RED = QColor("#D6382C")
INK_GREEN = QColor("#61DE80")
INK_BLUE = QColor("#58B0EC")
INK_WHITE = QColor("#FFFFFF")
INKS = {"R": INK_RED, "G": INK_GREEN, "B": INK_BLUE, "W": INK_WHITE}
INK_NAMES = {"Red": INK_RED, "Green": INK_GREEN, "Blue": INK_BLUE}
SHORTCUTS = set("RGBW#")
SECTION_STATE = 7
BULLET_PREFIX = "\u2022 "
CHECK_PREFIX = "\u2610 "
RULE_MARKER = "\u2500"
SAVE_MS = 400
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "round-trip.json"
DEV_NOTES = Path(__file__).resolve().parent / "dev-notes"
NEW_NOTE_LABEL = "New note"
QUIT_LABEL = "Quit"

# Qt's document writer has HTML, not RTF. Notes store a small RTF subset:
# text, a color table, and font size.
SKIP_DEST = {
    "fonttbl",
    "stylesheet",
    "info",
    "pict",
    "header",
    "footer",
    "headerl",
    "headerr",
    "headerf",
    "footerl",
    "footerr",
    "footerf",
    "footnote",
    "expandedcolortbl",
    "listtable",
    "listoverridetable",
    "rsidtbl",
    "generator",
    "filetbl",
    "themedata",
    "colorschememapping",
    "datastore",
    "latentstyles",
    "object",
    "field",
    "fldinst",
    "fldrslt",
}

_open = []


def notes_directory(platform=None):
    """Where note JSON files live. Never creates the directory."""
    override = os.environ.get("POSTIT_NOTES_DIR", "").strip()
    if override:
        return Path(override).expanduser()
    system = platform or sys.platform
    if system == "win32":
        base = os.environ.get("APPDATA", "").strip()
        if not base:
            base = str(Path.home() / "AppData" / "Roaming")
        return Path(base) / "Postit" / "notes"
    if system == "darwin":
        # The Qt app must not write the live Mac notes folder unless asked.
        if os.environ.get("POSTIT_PLATFORM_NOTES", "").strip() == "1":
            return Path.home() / "Library" / "Application Support" / "Postit" / "notes"
        return DEV_NOTES
    return Path.home() / ".local" / "share" / "Postit" / "notes"


def ensure_notes_dir():
    folder = notes_directory()
    folder.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(folder, 0o700)
    except OSError:
        pass
    return folder


def live_notes_names():
    """File names in the Mac app's notes folder. Does not read note bodies."""
    folder = Path.home() / "Library" / "Application Support" / "Postit" / "notes"
    if not folder.is_dir():
        return None
    return set(os.listdir(folder))


def note_title(text):
    if not isinstance(text, str):
        text = ""
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    for line in normalized.split("\n"):
        trimmed = line.strip()
        if not trimmed:
            continue
        lower = trimmed.lower()
        if lower in (":math", ":end"):
            continue
        if trimmed == "---" or set(trimmed) <= {RULE_MARKER}:
            continue
        if len(trimmed) > 40:
            return trimmed[:40] + "\u2026"
        return trimmed
    return "Untitled note"


def _created(path):
    st = path.stat()
    return getattr(st, "st_birthtime", st.st_ctime), path.name


def note_rows(directory=None):
    """(path, title) pairs the tray menu lists, oldest note first."""
    folder = Path(directory) if directory is not None else notes_directory()
    if not folder.is_dir():
        return []
    files = [p for p in folder.iterdir() if p.is_file() and p.suffix == ".json"]
    rows = []
    for path in sorted(files, key=_created):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(data, dict):
            continue
        text = data.get("text") if isinstance(data.get("text"), str) else ""
        rows.append((path, note_title(text)))
    return rows


def iter_tray_actions(directory=None):
    """Rows the tray menu builds: one note, then New note, then Quit."""
    for path, title in note_rows(directory):
        yield ("note", title, path)
    yield ("new", NEW_NOTE_LABEL, None)
    yield ("quit", QUIT_LABEL, None)


def newest_note(directory=None):
    folder = Path(directory) if directory is not None else notes_directory()
    if not folder.is_dir():
        return None
    files = [p for p in folder.iterdir() if p.is_file() and p.suffix == ".json"]
    if not files:
        return None
    return max(files, key=lambda path: (path.stat().st_mtime_ns, path.name))


def edge_at(pos, size):
    left = pos.x() <= EDGE
    right = pos.x() >= size.width() - EDGE
    top = pos.y() <= EDGE
    bottom = pos.y() >= size.height() - EDGE
    if not (left or right or top or bottom):
        return None
    mask = 0
    if left:
        mask |= 1
    if right:
        mask |= 2
    if top:
        mask |= 4
    if bottom:
        mask |= 8
    return mask


def read_control(s, i):
    """i points at a backslash. Returns word, arg, new index, hex byte."""
    i += 1
    if i >= len(s):
        return "", None, i, None
    ch = s[i]
    if ch == "'":
        hexpart = s[i + 1 : i + 3]
        try:
            return "'", None, i + 3, int(hexpart, 16)
        except ValueError:
            return "'", None, i + 1, None
    if not ch.isalpha():
        return ch, None, i + 1, None
    j = i + 1
    while j < len(s) and s[j].isalpha():
        j += 1
    word = s[i:j]
    arg = None
    if j < len(s) and (s[j] == "-" or s[j].isdigit()):
        k = j + 1 if s[j] == "-" else j
        if not (s[j] == "-" and (k >= len(s) or not s[k].isdigit())):
            while k < len(s) and s[k].isdigit():
                k += 1
            try:
                arg = int(s[j:k])
            except ValueError:
                arg = None
            j = k
    if j < len(s) and s[j] == " ":
        j += 1
    return word, arg, j, None


def peek_dest(s, i):
    j = i
    n = len(s)
    while j < n and s[j] in " \r\n":
        j += 1
    if j >= n or s[j] != "\\":
        return None, i, False
    word, _, nxt, _ = read_control(s, j)
    starred = word == "*"
    if starred:
        k = nxt
        while k < n and s[k] in " \r\n":
            k += 1
        if k < n and s[k] == "\\":
            word, _, nxt, _ = read_control(s, k)
        else:
            word = "*"
    return word, nxt, starred


def parse_colortbl(s, i):
    colors = []
    red = green = blue = None
    seen = False
    n = len(s)
    while i < n:
        ch = s[i]
        if ch == "}":
            if seen:
                colors.append((red or 0, green or 0, blue or 0))
            return colors, i + 1
        if ch == "{":
            depth = 1
            i += 1
            while i < n and depth:
                if s[i] == "{":
                    depth += 1
                elif s[i] == "}":
                    depth -= 1
                i += 1
            continue
        if ch == ";":
            colors.append((red or 0, green or 0, blue or 0) if seen else None)
            red = green = blue = None
            seen = False
            i += 1
            continue
        if ch == "\\":
            word, arg, i, _ = read_control(s, i)
            if word == "red":
                red = 0 if arg is None else arg
                seen = True
            elif word == "green":
                green = 0 if arg is None else arg
                seen = True
            elif word == "blue":
                blue = 0 if arg is None else arg
                seen = True
            continue
        i += 1
    return colors, i


def parse_rtf(data, default_size=15):
    s = data.decode("latin-1", errors="replace")
    i = 0
    n = len(s)
    colors = []
    runs = []
    stack = []
    cf = 0
    uc = 1
    fs = int(round(float(default_size) * 2))
    depth = 0
    skip_until = None

    def add_text(text):
        if skip_until is not None or not text:
            return
        color = colors[cf] if 0 <= cf < len(colors) else None
        if runs and runs[-1][1] == color and runs[-1][2] == fs:
            runs[-1] = (runs[-1][0] + text, color, fs)
        else:
            runs.append((text, color, fs))

    while i < n:
        ch = s[i]
        if ch == "{":
            depth += 1
            stack.append((cf, uc, fs))
            i += 1
            if skip_until is not None:
                continue
            dest, nxt, starred = peek_dest(s, i)
            if dest == "colortbl" and not starred:
                colors, i = parse_colortbl(s, nxt)
                depth -= 1
                if stack:
                    cf, uc, fs = stack.pop()
                continue
            if starred or dest in SKIP_DEST:
                skip_until = depth
            continue
        if ch == "}":
            if stack:
                cf, uc, fs = stack.pop()
            if skip_until is not None and depth == skip_until:
                skip_until = None
            depth -= 1
            i += 1
            continue
        if ch == "\\":
            word, arg, i, hexbyte = read_control(s, i)
            if word == "bin" and arg:
                i = min(n, i + arg)
                continue
            if skip_until is not None:
                continue
            if word == "'" and hexbyte is not None:
                add_text(bytes([hexbyte]).decode("cp1252", errors="replace"))
            elif word == "u" and arg is not None:
                cp = arg + 65536 if arg < 0 else arg
                if 0 <= cp <= 0x10FFFF:
                    add_text(chr(cp))
                skipped = 0
                while skipped < uc and i < n:
                    if s[i] in "\r\n":
                        i += 1
                        continue
                    if s[i] == "\\" and i + 1 < n and s[i + 1] in "\\{}":
                        i += 2
                    else:
                        i += 1
                    skipped += 1
            elif word == "uc" and arg is not None:
                uc = arg
            elif word == "cf" and arg is not None:
                cf = arg
            elif word == "fs" and arg is not None:
                fs = arg
            elif word in ("par", "line"):
                add_text("\n")
            elif word == "tab":
                add_text("\t")
            elif word in ("{", "}", "\\"):
                add_text(word)
            elif word == "~":
                add_text("\u00a0")
            continue
        if ch in "\r\n":
            i += 1
            continue
        if skip_until is None:
            add_text(ch)
        i += 1
    return [(text, color, (half / 2.0) if half else float(default_size)) for text, color, half in runs]


def escape_rtf(text):
    out = []
    i = 0
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if ch == "\r" or ch == "\n":
            if ch == "\r" and nxt == "\n":
                i += 1
            out.append("\\par ")
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "{":
            out.append("\\{")
        elif ch == "}":
            out.append("\\}")
        elif ch == "\t":
            out.append("\\tab ")
        else:
            o = ord(ch)
            if o < 128:
                out.append(ch)
            elif o <= 0xFFFF:
                n = o if o < 32768 else o - 65536
                out.append(f"\\u{n}?")
            else:
                out.append("?")
        i += 1
    return "".join(out)


def document_to_rtf(doc, default_size=15):
    pieces = []
    block = doc.begin()
    first = True
    while block.isValid():
        if not first:
            pieces.append(("par",))
        first = False
        it = block.begin()
        while not it.atEnd():
            frag = it.fragment()
            text = frag.text().replace("\u2029", "")
            if text:
                color = frag.charFormat().foreground().color()
                if color.isValid():
                    rgb = (color.red(), color.green(), color.blue())
                else:
                    rgb = (255, 255, 255)
                size = frag.charFormat().fontPointSize()
                if size <= 0:
                    size = float(default_size)
                pieces.append(("text", text, rgb, float(size)))
            it += 1
        block = block.next()

    palette = []

    def index(rgb):
        if rgb not in palette:
            palette.append(rgb)
        return palette.index(rgb) + 1

    body = []
    cf = None
    half = None
    for piece in pieces:
        if piece[0] == "par":
            body.append("\\par ")
            continue
        _, text, rgb, size = piece
        this_half = int(round(size * 2))
        if this_half != half:
            body.append(f"\\fs{this_half} ")
            half = this_half
        ci = index(rgb)
        if ci != cf:
            body.append(f"\\cf{ci} ")
            cf = ci
        body.append(escape_rtf(text))

    entries = [""]
    for r, g, b in palette:
        entries.append(f"\\red{r}\\green{g}\\blue{b}")
    colortbl = "{\\colortbl" + ";".join(entries) + ";}"
    out = (
        "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2907\n"
        "{\\fonttbl\\f0\\fnil\\fcharset0 HelveticaNeue;}\n"
        f"{colortbl}\n"
        "\\pard\\pardirnatural\\partightenfactor0\n"
        "\\f0 "
        + "".join(body)
        + "}"
    )
    return out.encode("ascii")


def set_document_rtf(doc, data, default_size=15):
    runs = parse_rtf(data, default_size)
    cursor = QTextCursor(doc)
    cursor.beginEditBlock()
    cursor.select(QTextCursor.SelectionType.Document)
    cursor.removeSelectedText()
    for text, color, size in runs:
        fmt = QTextCharFormat()
        fmt.setFontPointSize(size or float(default_size))
        if color is not None:
            fmt.setForeground(QColor(color[0], color[1], color[2]))
        else:
            fmt.setForeground(QColor(255, 255, 255))
        cursor.insertText(text, fmt)
    cursor.endEditBlock()


def is_near_red(color):
    if color is None or not color.isValid():
        return False
    r, g, b = color.red(), color.green(), color.blue()
    return r >= 160 and g <= 120 and b <= 120 and r > g + 50 and r > b + 50


def rtf_has_near_red(data):
    s = data.decode("latin-1", errors="replace")
    i = 0
    while True:
        start = s.find("\\red", i)
        if start < 0:
            return False
        word, red, j, _ = read_control(s, start)
        if word == "red" and j < len(s) and s[j] == "\\":
            gword, green, k, _ = read_control(s, j)
            if gword == "green" and k < len(s) and s[k] == "\\":
                bword, blue, i, _ = read_control(s, k)
                if bword == "blue" and is_near_red(QColor(red or 0, green or 0, blue or 0)):
                    return True
                continue
        i = start + 4


def red_text(doc):
    parts = []
    block = doc.begin()
    while block.isValid():
        it = block.begin()
        while not it.atEnd():
            frag = it.fragment()
            text = frag.text().replace("\u2029", "")
            if text and is_near_red(frag.charFormat().foreground().color()):
                parts.append(text)
            it += 1
        block = block.next()
    return "".join(parts)


def source_blocks(note):
    blocks = note.get("blocks")
    if isinstance(blocks, list) and blocks:
        return blocks
    columns = note.get("columns")
    if isinstance(columns, list) and columns and isinstance(columns[0], list) and columns[0]:
        return columns[0]
    return []


def paint_round_trip(doc):
    cursor = QTextCursor(doc)
    white = QTextCharFormat()
    white.setForeground(QColor(255, 255, 255))
    white.setFontPointSize(15)
    red = QTextCharFormat()
    red.setForeground(INK_RED)
    red.setFontPointSize(15)
    cursor.insertText("round ", white)
    cursor.insertText("trip", red)


def rtf_plain(data, default_size=15):
    return "".join(text for text, _, _ in parse_rtf(data, default_size))


def rtf_self_test():
    doc = QTextDocument()
    paint_round_trip(doc)
    raw = document_to_rtf(doc, 15)
    # The color change sits between the two words, so the phrase is not one span.
    if "round trip" not in rtf_plain(raw):
        return "writer dropped the words"
    if not rtf_has_near_red(raw):
        return "writer dropped the red run"
    back = QTextDocument()
    set_document_rtf(back, raw, 15)
    if back.toPlainText() != "round trip":
        return f"reader text {back.toPlainText()!r}"
    if "trip" not in red_text(back):
        return f"reader color {red_text(back)!r}"
    cocoa = (
        "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2907\n"
        "\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\fnil\\fcharset0 HelveticaNeue;}\n"
        "{\\colortbl;\\red255\\green255\\blue255;\\red255\\green255\\blue255;\\red202\\green35\\blue34;}\n"
        "{\\*\\expandedcolortbl;;\\cssrgb\\c100000\\c100000\\c100000\\c97000;\\cssrgb\\c83922\\c21961\\c17255;}\n"
        "\\pard\\tx560\\tx1120\\tx1680\\tx2240\\tx2800\\tx3360\\tx3920\\tx4480\\tx5040\\tx5600\\tx6160\\tx6720\\pardirnatural\\partightenfactor0\n"
        "\n"
        "\\f0\\fs30 \\cf2 round \\cf3 trip}"
    ).encode("latin-1")
    cocoa_doc = QTextDocument()
    set_document_rtf(cocoa_doc, cocoa, 15)
    if cocoa_doc.toPlainText() != "round trip":
        return f"cocoa text {cocoa_doc.toPlainText()!r}"
    if "trip" not in red_text(cocoa_doc):
        return f"cocoa color {red_text(cocoa_doc)!r}"
    return None


def write_fixture(path=FIXTURE):
    reason = rtf_self_test()
    if reason:
        raise RuntimeError(reason)
    doc = QTextDocument()
    paint_round_trip(doc)
    raw = document_to_rtf(doc, 15)
    note = {
        "id": "7f3a9c2e-6b14-4d88-a1e0-5c0e4b2a11d4",
        "text": "round trip",
        "fontSize": 15,
        "frame": [220, 180, 320, 380],
        "blocks": [
            {
                "kind": "text",
                "rtf": base64.b64encode(raw).decode("ascii"),
                "text": "round trip",
                "title": "",
                "collapsed": False,
            }
        ],
    }
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(note, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def is_section_block(block):
    return block.userState() == SECTION_STATE


def ink_from_name(name):
    return QColor(INK_NAMES.get(name, INK_WHITE))


def mark_block(cursor, section):
    cursor.block().setUserState(SECTION_STATE if section else -1)


def atomic_write(path, note):
    file = Path(path)
    tmp = file.with_suffix(file.suffix + ".tmp")
    tmp.write_text(json.dumps(note, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(file)
    try:
        os.chmod(file, 0o600)
    except OSError:
        pass


def block_plain_and_rtf(parts, default_size):
    doc = QTextDocument()
    cursor = QTextCursor(doc)
    for index, block in enumerate(parts):
        if index:
            cursor.insertBlock()
        it = block.begin()
        while not it.atEnd():
            frag = it.fragment()
            text = frag.text().replace("\u2029", "")
            if text:
                cursor.insertText(text, frag.charFormat())
            it += 1
    plain = doc.toPlainText()
    if not plain:
        return "", None
    rtf = base64.b64encode(document_to_rtf(doc, default_size)).decode("ascii")
    return plain, rtf


class NoteEdit(QTextEdit):
    """Typing shortcuts from the Mac editor: ink, section, bullet, box, rule."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.ink = QColor(INK_WHITE)
        self._pending = None

    def keyPressEvent(self, event):
        mods = event.modifiers()
        if mods & (
            Qt.KeyboardModifier.ControlModifier
            | Qt.KeyboardModifier.MetaModifier
            | Qt.KeyboardModifier.AltModifier
        ):
            self._pending = None
            super().keyPressEvent(event)
            return
        if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            self._pending = None
            if self._on_return():
                return
            super().keyPressEvent(event)
            return
        text = event.text()
        if text and len(text) == 1:
            self._on_char(text)
            return
        if text or event.key() == Qt.Key.Key_Backspace:
            self._pending = None
        super().keyPressEvent(event)

    def _char_format(self, bold=None):
        fmt = QTextCharFormat()
        size = self.font().pointSize()
        fmt.setFontPointSize(float(size if size > 0 else 15))
        fmt.setForeground(QColor(self.ink))
        if bold is None:
            bold = is_section_block(self.textCursor().block())
        fmt.setFontWeight(QFont.Weight.Bold if bold else QFont.Weight.Normal)
        return fmt

    def _insert(self, text, bold=None):
        cursor = self.textCursor()
        cursor.insertText(text, self._char_format(bold))
        self.setTextCursor(cursor)

    def _on_char(self, ch):
        cursor = self.textCursor()
        if ch == " " and not cursor.hasSelection():
            if self._swap_prefix("-", BULLET_PREFIX) or self._swap_prefix("[]", CHECK_PREFIX):
                self._pending = None
                return
        if (
            ch in SHORTCUTS
            and not cursor.hasSelection()
            and self._pending is not None
            and self._pending[0] == ch
            and self._pending[1] + 1 == cursor.position()
        ):
            offset = cursor.position() - cursor.block().position()
            line = cursor.block().text()
            if offset >= 1 and line[offset - 1] == ch:
                cursor.beginEditBlock()
                cursor.movePosition(
                    QTextCursor.MoveOperation.Left, QTextCursor.MoveMode.KeepAnchor, 1
                )
                cursor.removeSelectedText()
                self.setTextCursor(cursor)
                cursor.endEditBlock()
                self._pending = None
                if ch == "#":
                    self._make_section()
                else:
                    self.ink = QColor(INKS[ch])
                    self.setTextColor(self.ink)
                return
        if ch in SHORTCUTS and not cursor.hasSelection():
            self._pending = (ch, cursor.position())
        else:
            self._pending = None
        self._insert(ch)

    def _swap_prefix(self, trigger, prefix):
        cursor = self.textCursor()
        block = cursor.block()
        offset = cursor.position() - block.position()
        if offset != len(trigger) or block.text()[:offset] != trigger:
            return False
        cursor.beginEditBlock()
        cursor.movePosition(
            QTextCursor.MoveOperation.Left, QTextCursor.MoveMode.KeepAnchor, len(trigger)
        )
        cursor.insertText(prefix, self._char_format(False))
        self.setTextCursor(cursor)
        cursor.endEditBlock()
        return True

    def _make_section(self):
        cursor = self.textCursor()
        cursor.beginEditBlock()
        cursor.movePosition(QTextCursor.MoveOperation.StartOfBlock)
        cursor.movePosition(QTextCursor.MoveOperation.EndOfBlock, QTextCursor.MoveMode.KeepAnchor)
        if cursor.hasSelection():
            cursor.mergeCharFormat(self._char_format(True))
        mark_block(cursor, True)
        cursor.movePosition(QTextCursor.MoveOperation.EndOfBlock)
        self.setTextCursor(cursor)
        cursor.endEditBlock()

    def _on_return(self):
        cursor = self.textCursor()
        if cursor.hasSelection():
            return False
        text = cursor.block().text()
        if text == "---":
            self._become_rule()
            return True
        if text in (BULLET_PREFIX, BULLET_PREFIX.strip()):
            self._clear_block()
            return True
        if is_section_block(cursor.block()):
            self._leave_section()
            return True
        return False

    def _become_rule(self):
        cursor = self.textCursor()
        cursor.beginEditBlock()
        cursor.movePosition(QTextCursor.MoveOperation.StartOfBlock)
        cursor.movePosition(QTextCursor.MoveOperation.EndOfBlock, QTextCursor.MoveMode.KeepAnchor)
        cursor.insertText(RULE_MARKER, self._char_format(False))
        mark_block(cursor, False)
        cursor.insertBlock()
        mark_block(cursor, False)
        cursor.setCharFormat(self._char_format(False))
        self.setTextCursor(cursor)
        cursor.endEditBlock()

    def _clear_block(self):
        cursor = self.textCursor()
        cursor.beginEditBlock()
        cursor.movePosition(QTextCursor.MoveOperation.StartOfBlock)
        cursor.movePosition(QTextCursor.MoveOperation.EndOfBlock, QTextCursor.MoveMode.KeepAnchor)
        cursor.removeSelectedText()
        mark_block(cursor, False)
        self.setTextCursor(cursor)
        cursor.endEditBlock()

    def _leave_section(self):
        cursor = self.textCursor()
        cursor.beginEditBlock()
        cursor.insertBlock()
        mark_block(cursor, False)
        cursor.setCharFormat(self._char_format(False))
        self.setTextCursor(cursor)
        cursor.endEditBlock()


class NoteWindow(QWidget):
    def __init__(self, origin=None, path=None):
        super().__init__()
        _open.append(self)
        flags = Qt.WindowType.FramelessWindowHint | Qt.WindowType.Window
        if sys.platform == "win32":
            flags |= Qt.WindowType.Tool
        self.setWindowFlags(flags)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.resize(320, 380)
        self.setMinimumSize(220, 180)
        if origin is not None:
            self.move(origin)
        self._drag_from = None
        self._window_from = None
        self._resize_mask = None
        self._resize_from = None
        self._geom_from = None
        self.path = None
        self.note = {}
        self.block = None
        self._loading = False
        self._save_timer = QTimer(self)
        self._save_timer.setSingleShot(True)
        self._save_timer.timeout.connect(self.save)

        self.edit = NoteEdit(self)
        self.edit.setFrameStyle(0)
        self.edit.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.edit.viewport().setAutoFillBackground(False)
        self.edit.setStyleSheet(
            "QTextEdit { background-color: rgba(0,0,0,0); color: rgba(255,255,255,247);"
            " border: none; font-size: 15pt;"
            " selection-background-color: rgba(92,133,235,102); }"
        )
        self.edit.viewport().setStyleSheet("background-color: transparent;")
        pal = self.edit.palette()
        pal.setColor(QPalette.ColorRole.Base, QColor(0, 0, 0, 0))
        pal.setColor(QPalette.ColorRole.Text, QColor(255, 255, 255))
        self.edit.setPalette(pal)
        self.edit.viewport().setPalette(pal)
        self.edit.document().setDocumentMargin(0)
        self._apply_font_size(15)

        self.plus = QPushButton("+", self)
        self.closer = QPushButton("x", self)
        for button in (self.plus, self.closer):
            button.setFixedSize(28, 28)
            button.setCursor(Qt.CursorShape.PointingHandCursor)
            button.setStyleSheet(
                "QPushButton { color: white; background: transparent; border: none; font-size: 16px; }"
                "QPushButton:hover { background: rgba(255,255,255,30); border-radius: 8px; }"
            )
        self.plus.clicked.connect(self.spawn)
        self.closer.clicked.connect(self.close)
        self._place_buttons()
        self._place_editor()
        self.plus.raise_()
        self.closer.raise_()
        self.edit.textChanged.connect(self._schedule_save)
        if path:
            self.load(path)

    def _schedule_save(self):
        if self._loading or not self.path:
            return
        self._save_timer.start(SAVE_MS)

    def _apply_font_size(self, size):
        font = self.edit.font()
        font.setPointSize(int(round(float(size))))
        self.edit.document().setDefaultFont(font)
        self.edit.setFont(font)

    def _place_buttons(self):
        self.plus.move(12, 10)
        self.closer.move(self.width() - 40, 10)

    def _place_editor(self):
        self.edit.setGeometry(14, 30, max(0, self.width() - 28), max(0, self.height() - 44))

    def resizeEvent(self, event):
        self._place_buttons()
        self._place_editor()
        self.plus.raise_()
        self.closer.raise_()
        super().resizeEvent(event)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        path = QPainterPath()
        path.addRoundedRect(self.rect().adjusted(0, 0, -1, -1), RADIUS, RADIUS)
        painter.fillPath(path, FILL)

    def load(self, path):
        self._loading = True
        self._save_timer.stop()
        try:
            file = Path(path)
            try:
                self.note = json.loads(file.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                print(f"load failed: {exc}", file=sys.stderr)
                self.note = {}
                self.path = None
                return
            if not isinstance(self.note, dict):
                print("load failed: note is not an object", file=sys.stderr)
                self.note = {}
                self.path = None
                return
            self.path = str(file)
            frame = self.note.get("frame") or []
            if isinstance(frame, list) and len(frame) == 4:
                self.setGeometry(int(frame[0]), int(frame[1]), int(frame[2]), int(frame[3]))
            try:
                size = float(self.note.get("fontSize") or 15)
            except (TypeError, ValueError):
                size = 15
            self._apply_font_size(size)
            blocks = source_blocks(self.note)
            if any(isinstance(b, dict) and b.get("kind") == "section" for b in blocks):
                self.block = next(
                    (b for b in blocks if isinstance(b, dict) and b.get("kind", "text") == "text"),
                    None,
                )
                self._load_structured(blocks, size)
                self._place_editor()
                return
            self.block = None
            for block in blocks:
                if isinstance(block, dict) and block.get("kind", "text") == "text":
                    self.block = block
                    break
            rtf_b64 = self.block.get("rtf") if isinstance(self.block, dict) else None
            plain = ""
            if isinstance(self.block, dict) and isinstance(self.block.get("text"), str):
                plain = self.block.get("text") or ""
            elif isinstance(self.note.get("text"), str):
                plain = self.note.get("text") or ""
            if not rtf_b64 and self.note.get("rtf"):
                rtf_b64 = self.note.get("rtf")
            if rtf_b64:
                try:
                    set_document_rtf(self.edit.document(), base64.b64decode(rtf_b64), size)
                except (ValueError, TypeError) as exc:
                    print(f"rtf failed: {exc}", file=sys.stderr)
                    self.edit.setPlainText(plain)
            else:
                self.edit.setPlainText(plain)
            self._place_editor()
        finally:
            self._loading = False
            self._save_timer.stop()

    def _insert_stored(self, cursor, rtf_b64, plain, size):
        if rtf_b64:
            try:
                runs = parse_rtf(base64.b64decode(rtf_b64), size)
            except (ValueError, TypeError) as exc:
                print(f"rtf failed: {exc}", file=sys.stderr)
                runs = None
            if runs is not None:
                for text, color, sz in runs:
                    fmt = QTextCharFormat()
                    fmt.setFontPointSize(sz or float(size))
                    fmt.setFontWeight(QFont.Weight.Normal)
                    if color is not None:
                        fmt.setForeground(QColor(color[0], color[1], color[2]))
                    else:
                        fmt.setForeground(QColor(INK_WHITE))
                    cursor.insertText(text, fmt)
                return
        if plain:
            fmt = QTextCharFormat()
            fmt.setFontPointSize(float(size))
            fmt.setFontWeight(QFont.Weight.Normal)
            fmt.setForeground(QColor(INK_WHITE))
            cursor.insertText(plain, fmt)

    def _load_structured(self, blocks, size):
        cursor = QTextCursor(self.edit.document())
        cursor.beginEditBlock()
        cursor.select(QTextCursor.SelectionType.Document)
        cursor.removeSelectedText()
        first = True
        for block in blocks:
            if not isinstance(block, dict):
                continue
            kind = block.get("kind") or "text"
            if not first:
                cursor.insertBlock()
                mark_block(cursor, False)
            first = False
            if kind == "section":
                try:
                    title_size = float(block.get("titleSize") or size)
                except (TypeError, ValueError):
                    title_size = float(size)
                fmt = QTextCharFormat()
                fmt.setFontPointSize(title_size)
                fmt.setFontWeight(QFont.Weight.Bold)
                fmt.setForeground(ink_from_name(block.get("titleInk")))
                cursor.insertText(block.get("title") or "", fmt)
                mark_block(cursor, True)
                if block.get("text") or block.get("rtf"):
                    cursor.insertBlock()
                    mark_block(cursor, False)
                    self._insert_stored(cursor, block.get("rtf"), block.get("text") or "", size)
            else:
                self._insert_stored(cursor, block.get("rtf"), block.get("text") or "", size)
        cursor.endEditBlock()

    def _has_section(self):
        block = self.edit.document().begin()
        while block.isValid():
            if is_section_block(block):
                return True
            block = block.next()
        return False

    def _section_blocks(self, size):
        segments = []
        block = self.edit.document().begin()
        while block.isValid():
            if is_section_block(block):
                segments.append({"kind": "section", "title": block.text(), "parts": []})
            elif not segments or segments[-1]["kind"] != "text":
                if segments and segments[-1]["kind"] == "section":
                    segments[-1]["parts"].append(block)
                else:
                    segments.append({"kind": "text", "title": "", "parts": [block]})
            else:
                segments[-1]["parts"].append(block)
            block = block.next()
        out = []
        for seg in segments:
            plain, rtf = block_plain_and_rtf(seg["parts"], size)
            if seg["kind"] == "section":
                item = {
                    "kind": "section",
                    "title": seg["title"],
                    "text": plain,
                    "collapsed": False,
                }
            else:
                item = {
                    "kind": "text",
                    "text": plain,
                    "title": "",
                    "collapsed": False,
                }
            if rtf:
                item["rtf"] = rtf
            out.append(item)
        return out

    def save(self):
        if not self.path:
            return
        plain = self.edit.toPlainText()
        try:
            size = float(self.note.get("fontSize") or 15)
        except (TypeError, ValueError):
            size = 15
        if not self.note.get("id"):
            self.note["id"] = str(uuid.uuid4())
        self.note["text"] = plain
        if "fontSize" not in self.note:
            self.note["fontSize"] = size
        geom = self.geometry()
        self.note["frame"] = [geom.x(), geom.y(), geom.width(), geom.height()]
        if self._has_section():
            self.note["blocks"] = self._section_blocks(size)
            self.block = next(
                (b for b in self.note["blocks"] if b.get("kind") == "text"),
                self.note["blocks"][0] if self.note["blocks"] else None,
            )
            if "rtf" in self.note and self.block and self.block.get("rtf"):
                self.note["rtf"] = self.block["rtf"]
            atomic_write(self.path, self.note)
            return
        rtf_b64 = base64.b64encode(document_to_rtf(self.edit.document(), size)).decode("ascii")
        if not isinstance(self.block, dict):
            self.block = {"kind": "text", "title": "", "collapsed": False}
            if not (isinstance(self.note.get("columns"), list) and self.note["columns"]):
                self.note["blocks"] = [self.block]
            else:
                self.note["columns"][0].insert(0, self.block)
        self.block["kind"] = self.block.get("kind") or "text"
        self.block["rtf"] = rtf_b64
        self.block["text"] = plain
        if "title" not in self.block:
            self.block["title"] = ""
        if "collapsed" not in self.block:
            self.block["collapsed"] = False
        if "rtf" in self.note:
            self.note["rtf"] = rtf_b64
        atomic_write(self.path, self.note)

    def spawn(self):
        return open_new_note(self.pos() + QPoint(26, 26))

    def mousePressEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton:
            return
        child = self.childAt(event.position().toPoint())
        if isinstance(child, QPushButton):
            return
        local = event.position().toPoint()
        mask = edge_at(local, self.size())
        if mask:
            self._resize_mask = mask
            self._resize_from = event.globalPosition().toPoint()
            self._geom_from = self.geometry()
            return
        self._drag_from = event.globalPosition().toPoint()
        self._window_from = self.pos()

    def mouseMoveEvent(self, event):
        if self._resize_mask and self._resize_from is not None and self._geom_from is not None:
            delta = event.globalPosition().toPoint() - self._resize_from
            self.apply_resize(self._resize_mask, self._geom_from, delta)
            return
        if self._drag_from is not None and self._window_from is not None:
            delta = event.globalPosition().toPoint() - self._drag_from
            self.move(self._window_from + delta)

    def mouseReleaseEvent(self, event):
        self._drag_from = None
        self._window_from = None
        self._resize_mask = None
        self._resize_from = None
        self._geom_from = None

    def apply_resize(self, mask, geom, delta):
        rect = QRect(geom)
        if mask & 1:
            rect.setLeft(geom.left() + delta.x())
        if mask & 2:
            rect.setRight(geom.right() + delta.x())
        if mask & 4:
            rect.setTop(geom.top() + delta.y())
        if mask & 8:
            rect.setBottom(geom.bottom() + delta.y())
        if rect.width() < self.minimumWidth():
            if mask & 1:
                rect.setLeft(rect.right() - self.minimumWidth() + 1)
            else:
                rect.setRight(rect.left() + self.minimumWidth() - 1)
        if rect.height() < self.minimumHeight():
            if mask & 4:
                rect.setTop(rect.bottom() - self.minimumHeight() + 1)
            else:
                rect.setBottom(rect.top() + self.minimumHeight() - 1)
        self.setGeometry(rect)

    def closeEvent(self, event):
        self._save_timer.stop()
        self.save()
        super().closeEvent(event)


def open_new_note(origin=None):
    folder = ensure_notes_dir()
    note_id = str(uuid.uuid4())
    path = folder / f"{note_id}.json"
    note = {
        "id": note_id,
        "text": "",
        "fontSize": 15,
        "frame": [],
        "blocks": [{"kind": "text", "text": "", "title": "", "collapsed": False}],
    }
    atomic_write(path, note)
    if origin is None:
        for win in reversed(_open):
            if win.isVisible():
                origin = win.pos() + QPoint(26, 26)
                break
    window = NoteWindow(origin=origin, path=str(path))
    window.show()
    return window


def open_path(path):
    path = str(Path(path))
    for win in _open:
        if getattr(win, "path", None) == path and win.isVisible():
            win.raise_()
            win.activateWindow()
            return win
    window = NoteWindow(path=path)
    window.show()
    return window


def open_restored():
    path = newest_note()
    if path is None:
        return open_new_note()
    window = NoteWindow(path=str(path))
    window.show()
    return window


def flush_window(win):
    timer = getattr(win, "_save_timer", None)
    if timer is not None:
        timer.stop()
    if win.isVisible():
        win.close()
    else:
        win.save()


def quit_app():
    for win in list(_open):
        flush_window(win)
    app = QApplication.instance()
    if app is not None:
        app.quit()


def tray_icon():
    pix = QPixmap(22, 22)
    pix.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pix)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    pen = QColor(255, 255, 255)
    painter.setPen(pen)
    painter.setBrush(Qt.BrushStyle.NoBrush)
    painter.drawRoundedRect(3, 4, 16, 14, 3, 3)
    painter.drawLine(6, 8, 16, 8)
    painter.drawLine(6, 11, 13, 11)
    painter.drawLine(6, 14, 16, 14)
    painter.end()
    icon = QIcon(pix)
    icon.setIsMask(True)
    return icon


class Tray:
    def __init__(self):
        self.icon = QSystemTrayIcon()
        self.icon.setIcon(tray_icon())
        self.icon.setToolTip("Postit")
        self.menu = QMenu()
        self.menu.aboutToShow.connect(self.rebuild)
        self.icon.setContextMenu(self.menu)
        self.rebuild()
        self.icon.show()

    def rebuild(self):
        self.menu.clear()
        for kind, title, path in iter_tray_actions():
            if kind == "new" and self.menu.actions():
                self.menu.addSeparator()
            action = self.menu.addAction(title)
            if kind == "note":
                action.triggered.connect(lambda checked=False, p=path: open_path(p))
            elif kind == "new":
                action.triggered.connect(lambda checked=False: open_new_note())
            else:
                action.triggered.connect(lambda checked=False: quit_app())


def hide_dock_icon():
    """Menu-bar mode on macOS. No-op if the call cannot be made."""
    if sys.platform != "darwin":
        return
    try:
        ctypes.cdll.LoadLibrary("/System/Library/Frameworks/AppKit.framework/AppKit")
        objc = ctypes.cdll.LoadLibrary("/usr/lib/libobjc.A.dylib")
        objc.objc_getClass.argtypes = [ctypes.c_char_p]
        objc.objc_getClass.restype = ctypes.c_void_p
        objc.sel_registerName.argtypes = [ctypes.c_char_p]
        objc.sel_registerName.restype = ctypes.c_void_p
        send = objc.objc_msgSend
        send.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        send.restype = ctypes.c_void_p
        nsapp = send(
            objc.objc_getClass(b"NSApplication"),
            objc.sel_registerName(b"sharedApplication"),
        )
        if not nsapp:
            return
        send.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long]
        send.restype = ctypes.c_bool
        # NSApplicationActivationPolicyAccessory: tray only, no Dock icon.
        send(nsapp, objc.sel_registerName(b"setActivationPolicy:"), 1)
    except (OSError, AttributeError):
        return


def press_key(widget, text):
    keys = {
        "\n": Qt.Key.Key_Return,
        " ": Qt.Key.Key_Space,
        "#": Qt.Key.Key_NumberSign,
        "-": Qt.Key.Key_Minus,
        "[": Qt.Key.Key_BracketLeft,
        "]": Qt.Key.Key_BracketRight,
    }
    if text in keys:
        key = keys[text]
    elif len(text) == 1 and text.isascii() and text.isalpha():
        key = Qt.Key(ord(text.upper()))
    else:
        key = Qt.Key.Key_unknown
    QApplication.sendEvent(
        widget, QKeyEvent(QEvent.Type.KeyPress, key, Qt.KeyboardModifier.NoModifier, text)
    )


def type_chars(widget, text):
    for ch in text:
        press_key(widget, ch)


def copy_fixture(folder, name, pristine):
    path = Path(folder) / name
    path.write_bytes(pristine)
    note = NoteWindow(path=str(path))
    note.show()
    return note, path


def fragment_runs(doc):
    runs = []
    block = doc.begin()
    while block.isValid():
        it = block.begin()
        while not it.atEnd():
            frag = it.fragment()
            text = frag.text().replace("\u2029", "")
            color = frag.charFormat().foreground().color()
            if text:
                runs.append((text, color, frag.charFormat().fontWeight(), is_section_block(block)))
            it += 1
        block = block.next()
    return runs


def check_dir_rules(errors):
    saved_dir = os.environ.get("POSTIT_NOTES_DIR")
    saved_platform = os.environ.get("POSTIT_PLATFORM_NOTES")
    saved_appdata = os.environ.get("APPDATA")
    try:
        os.environ.pop("POSTIT_NOTES_DIR", None)
        os.environ.pop("POSTIT_PLATFORM_NOTES", None)
        if sys.platform == "darwin":
            got = notes_directory().resolve()
            live = (Path.home() / "Library" / "Application Support" / "Postit" / "notes").resolve()
            if got != DEV_NOTES.resolve():
                errors.append(f"mac default notes dir {got}")
            if got == live:
                errors.append("mac default is the live notes folder")
            os.environ["POSTIT_PLATFORM_NOTES"] = "1"
            platform_path = notes_directory().resolve()
            if platform_path != live:
                errors.append(f"mac platform notes dir {platform_path}")
            os.environ.pop("POSTIT_PLATFORM_NOTES", None)
        os.environ["APPDATA"] = "C:/Users/me/AppData/Roaming"
        win = notes_directory(platform="win32")
        if win != Path("C:/Users/me/AppData/Roaming") / "Postit" / "notes":
            errors.append(f"windows notes dir {win}")
        linux = notes_directory(platform="linux")
        if linux != Path.home() / ".local" / "share" / "Postit" / "notes":
            errors.append(f"linux notes dir {linux}")
        os.environ["POSTIT_NOTES_DIR"] = "/tmp/postit-notes-override"
        if notes_directory() != Path("/tmp/postit-notes-override"):
            errors.append(f"override notes dir {notes_directory()}")
        os.environ["POSTIT_PLATFORM_NOTES"] = "1"
        if notes_directory() != Path("/tmp/postit-notes-override"):
            errors.append("override lost to the platform switch")
    finally:
        if saved_dir is None:
            os.environ.pop("POSTIT_NOTES_DIR", None)
        else:
            os.environ["POSTIT_NOTES_DIR"] = saved_dir
        if saved_platform is None:
            os.environ.pop("POSTIT_PLATFORM_NOTES", None)
        else:
            os.environ["POSTIT_PLATFORM_NOTES"] = saved_platform
        if saved_appdata is None:
            os.environ.pop("APPDATA", None)
        else:
            os.environ["APPDATA"] = saved_appdata


def check_tray(errors):
    tray_dir = Path(tempfile.mkdtemp(prefix="postit-tray-"))
    saved = os.environ.get("POSTIT_NOTES_DIR")
    os.environ["POSTIT_NOTES_DIR"] = str(tray_dir)
    opened = []
    try:
        if notes_directory().resolve() != tray_dir.resolve():
            errors.append(f"tray notes dir {notes_directory()}")
        live = (Path.home() / "Library" / "Application Support" / "Postit" / "notes").resolve()
        if notes_directory().resolve() == live:
            errors.append("tray check is using the live notes folder")
        first = open_new_note()
        opened.append(first)
        first.edit.setPlainText("First fixture")
        first.save()
        second = open_new_note()
        opened.append(second)
        second.edit.setPlainText("Second fixture")
        second.save()
        rows = list(iter_tray_actions())
        note_titles = [title for kind, title, _path in rows if kind == "note"]
        if sorted(note_titles) != ["First fixture", "Second fixture"]:
            errors.append(f"tray titles {note_titles!r}")
        kinds = [kind for kind, _title, _path in rows]
        if kinds[-2:] != ["new", "quit"] or kinds.count("note") != 2:
            errors.append(f"tray menu {kinds}")
        for win in opened:
            flush_window(win)
        opened.clear()
        restored = open_restored()
        opened.append(restored)
        text = restored.edit.toPlainText()
        if text != "Second fixture":
            errors.append(f"relaunch text {text!r}")
        flush_window(restored)
        opened.clear()
    except Exception:
        errors.append(traceback.format_exc())
    finally:
        for win in opened:
            flush_window(win)
        if saved is None:
            os.environ.pop("POSTIT_NOTES_DIR", None)
        else:
            os.environ["POSTIT_NOTES_DIR"] = saved
        shutil.rmtree(tray_dir, ignore_errors=True)


def run_check(app):
    live_before = live_notes_names()
    reason = rtf_self_test()
    if reason:
        print(reason)
        print("CHECK FAIL")
        return 1
    if not FIXTURE.is_file():
        print(f"missing {FIXTURE}")
        print("CHECK FAIL")
        return 1
    pristine = FIXTURE.read_bytes()
    tmp = Path(tempfile.mkdtemp(prefix="postit-check-"))
    spawn_dir = tmp / "spawn-notes"
    spawn_dir.mkdir()
    saved_notes_dir = os.environ.get("POSTIT_NOTES_DIR")
    os.environ["POSTIT_NOTES_DIR"] = str(spawn_dir)
    round_path = tmp / "round-trip.json"
    round_path.write_bytes(pristine)
    note = NoteWindow(path=str(round_path))
    note.show()
    errors = []

    def restore():
        for win in list(_open):
            timer = getattr(win, "_save_timer", None)
            if timer is not None:
                timer.stop()
        for win in list(_open):
            if win.isVisible():
                win.close()
        try:
            if not FIXTURE.is_file() or FIXTURE.read_bytes() != pristine:
                FIXTURE.write_bytes(pristine)
        except OSError as exc:
            errors.append(f"restore failed: {exc}")
        shutil.rmtree(tmp, ignore_errors=True)

    def finish():
        restore()
        if saved_notes_dir is None:
            os.environ.pop("POSTIT_NOTES_DIR", None)
        else:
            os.environ["POSTIT_NOTES_DIR"] = saved_notes_dir
        live_after = live_notes_names()
        if live_before is None and live_after is None:
            print("live notes folder does not exist; skipped name compare")
        elif live_before != live_after:
            added = sorted((live_after or set()) - (live_before or set()))
            removed = sorted((live_before or set()) - (live_after or set()))
            errors.append(f"live notes folder changed, added {added} removed {removed}")
        try:
            if FIXTURE.read_bytes() != pristine:
                errors.append("fixture bytes changed")
        except OSError as exc:
            errors.append(f"fixture read failed: {exc}")
        if errors:
            print("\n".join(errors))
            print("CHECK FAIL")
            app.exit(1)
        else:
            print("CHECK OK")
            app.exit(0)

    def step():
        auto = {}
        try:
            text = note.edit.toPlainText()
            if "round trip" not in text:
                errors.append(f"load text {text!r}")
            if "trip" not in red_text(note.edit.document()):
                errors.append(f"load color {red_text(note.edit.document())!r}")
            flags = note.windowFlags()
            if not (flags & Qt.WindowType.FramelessWindowHint):
                errors.append("not frameless")
            if not isinstance(note.edit, QTextEdit):
                errors.append("no editor")
            if edge_at(QPoint(2, 40), note.size()) != 1:
                errors.append("left edge")
            if edge_at(QPoint(40, 40), note.size()) is not None:
                errors.append("center should not resize")
            geom = QRect(note.geometry())
            start = note.pos()
            note._drag_from = QPoint(0, 0)
            note._window_from = start
            note.move(note._window_from + QPoint(30, 12))
            if note.pos() != start + QPoint(30, 12):
                errors.append(f"drag {note.pos()} from {start}")
            before = note.geometry()
            note.apply_resize(2, before, QPoint(40, 0))
            if note.width() <= before.width():
                errors.append("resize width")
            note.setGeometry(geom)
            other = note.spawn()
            if not other.isVisible():
                errors.append("plus did not show")
            other.close()
            note.edit.moveCursor(QTextCursor.MoveOperation.End)
            note.edit.insertPlainText("x")
            if not note.edit.toPlainText().endswith("x") or "round trip" not in note.edit.toPlainText():
                errors.append(f"edit {note.edit.toPlainText()!r}")
            note.close()
            on_disk = json.loads(round_path.read_text(encoding="utf-8"))
            raw = base64.b64decode(on_disk["blocks"][0]["rtf"])
            if "round trip" not in rtf_plain(raw):
                errors.append("saved rtf missing the words")
            if not rtf_has_near_red(raw):
                errors.append("saved rtf missing red")
            if "round trip" not in (on_disk.get("text") or ""):
                errors.append("saved summary missing the words")
            again = NoteWindow(path=str(round_path))
            again_text = again.edit.toPlainText()
            if "round trip" not in again_text:
                errors.append(f"reload text {again_text!r}")
            if "trip" not in red_text(again.edit.document()):
                errors.append(f"reload color {red_text(again.edit.document())!r}")
            if not again_text.endswith("x"):
                errors.append(f"reload lost the edit {again_text!r}")
            else:
                cursor = again.edit.textCursor()
                cursor.movePosition(QTextCursor.MoveOperation.End)
                cursor.deletePreviousChar()
                again.edit.setTextCursor(cursor)
            again.setGeometry(geom)
            again.save()
            final = json.loads(round_path.read_text(encoding="utf-8"))
            final_raw = base64.b64decode(final["blocks"][0]["rtf"])
            final_doc = QTextDocument()
            set_document_rtf(final_doc, final_raw, final.get("fontSize") or 15)
            if final_doc.toPlainText() != "round trip":
                errors.append(f"final text {final_doc.toPlainText()!r}")
            if "trip" not in red_text(final_doc):
                errors.append(f"final color {red_text(final_doc)!r}")
            if "round trip" not in rtf_plain(final_raw) or not rtf_has_near_red(final_raw):
                errors.append("final rtf lost the words or the red run")
            again.close()
            if not errors:
                check_typing(tmp, pristine, errors, auto)
            check_dir_rules(errors)
            check_tray(errors)
        except Exception:
            errors.append(traceback.format_exc())
        if errors or "note" not in auto:
            finish()
            return

        def later():
            try:
                after = auto["path"].read_bytes()
                if after == auto["before"]:
                    errors.append("autosave did not write")
                else:
                    saved = json.loads(after)
                    if "Q" not in (saved.get("text") or ""):
                        errors.append(f"autosave text {saved.get('text')!r}")
            except Exception:
                errors.append(traceback.format_exc())
            finish()

        QTimer.singleShot(500, later)

    QTimer.singleShot(150, step)
    return app.exec()


def check_typing(folder, pristine, errors, auto):
    ink, _ink_path = copy_fixture(folder, "ink.json", pristine)
    ink.edit.moveCursor(QTextCursor.MoveOperation.End)
    type_chars(ink.edit, "\nRRredGGgrnBBbluWWwht")
    plain = ink.edit.toPlainText()
    if plain != "round trip\nredgrnbluwht":
        errors.append(f"ink text {plain!r}")
    for gone in ("RR", "GG", "BB", "WW"):
        if gone in plain:
            errors.append(f"ink left {gone}")
    expect = {
        "red": (214, 56, 44),
        "grn": (97, 222, 128),
        "blu": (88, 176, 236),
        "wht": (255, 255, 255),
    }
    runs = fragment_runs(ink.edit.document())
    for word, rgb in expect.items():
        found = [
            (color.red(), color.green(), color.blue())
            for text, color, _weight, _section in runs
            if word in text and color.isValid()
        ]
        if rgb not in found:
            errors.append(f"{word} color {found}")
    if (ink.edit.ink.red(), ink.edit.ink.green(), ink.edit.ink.blue()) != expect["wht"]:
        errors.append(f"ink stayed {ink.edit.ink.name()}")
    ink.close()

    section, section_path = copy_fixture(folder, "section.json", pristine)
    section.edit.moveCursor(QTextCursor.MoveOperation.End)
    type_chars(section.edit, "\n##Title\nbody")
    plain = section.edit.toPlainText()
    if "##" in plain or plain != "round trip\nTitle\nbody":
        errors.append(f"section text {plain!r}")
    titled = [
        (text, weight, flag)
        for text, _color, weight, flag in fragment_runs(section.edit.document())
        if "Title" in text
    ]
    if not titled or titled[0][1] < int(QFont.Weight.Bold) or not titled[0][2]:
        errors.append(f"section title format {titled}")
    section.close()
    saved = json.loads(section_path.read_text(encoding="utf-8"))
    blocks = saved.get("blocks") or []
    kinds = [b.get("kind") for b in blocks if isinstance(b, dict)]
    if kinds[:2] != ["text", "section"]:
        errors.append(f"section blocks {kinds}")
    else:
        sec = blocks[1]
        if sec.get("title") != "Title" or sec.get("text") != "body":
            errors.append(f"section payload {sec.get('title')!r} {sec.get('text')!r}")
        if "##" in (sec.get("title") or ""):
            errors.append("section title kept the hashes")
    again = NoteWindow(path=str(section_path))
    again_plain = again.edit.toPlainText()
    if again_plain != "round trip\nTitle\nbody":
        errors.append(f"section reload {again_plain!r}")
    titled = [
        (text, weight, flag)
        for text, _color, weight, flag in fragment_runs(again.edit.document())
        if "Title" in text
    ]
    if not titled or titled[0][1] < int(QFont.Weight.Bold) or not titled[0][2]:
        errors.append(f"section reload format {titled}")
    again.close()

    bullet, _bullet_path = copy_fixture(folder, "bullet.json", pristine)
    bullet.edit.moveCursor(QTextCursor.MoveOperation.End)
    type_chars(bullet.edit, "\n- ")
    if not bullet.edit.toPlainText().endswith(BULLET_PREFIX):
        errors.append(f"bullet text {bullet.edit.toPlainText()!r}")
    press_key(bullet.edit, "\n")
    if BULLET_PREFIX.strip() in bullet.edit.toPlainText() or bullet.edit.toPlainText().rstrip(
        "\n"
    ).endswith("-"):
        errors.append(f"empty bullet stayed {bullet.edit.toPlainText()!r}")
    bullet.close()

    box, _box_path = copy_fixture(folder, "check.json", pristine)
    box.edit.moveCursor(QTextCursor.MoveOperation.End)
    type_chars(box.edit, "\n[] ")
    box_plain = box.edit.toPlainText()
    if not box_plain.endswith(CHECK_PREFIX) or "[]" in box_plain:
        errors.append(f"checkbox text {box_plain!r}")
    box.close()

    rule, rule_path = copy_fixture(folder, "rule.json", pristine)
    rule.edit.moveCursor(QTextCursor.MoveOperation.End)
    type_chars(rule.edit, "\n---\n")
    rule_plain = rule.edit.toPlainText()
    if "---" in rule_plain or RULE_MARKER not in rule_plain:
        errors.append(f"rule text {rule_plain!r}")
    rule.close()
    rule_saved = json.loads(rule_path.read_text(encoding="utf-8"))
    stored = "\n".join(b.get("text") or "" for b in rule_saved.get("blocks") or [])
    if "---" in stored or RULE_MARKER not in stored:
        errors.append(f"rule stored {stored!r}")
    rule_again = NoteWindow(path=str(rule_path))
    rule_loaded = rule_again.edit.toPlainText()
    if "---" in rule_loaded or RULE_MARKER not in rule_loaded:
        errors.append(f"rule reload {rule_loaded!r}")
    rule_again.close()

    flush, flush_path = copy_fixture(folder, "flush.json", pristine)
    flush.edit.moveCursor(QTextCursor.MoveOperation.End)
    flush.edit.insertPlainText("Z")
    flush.close()
    flushed = json.loads(flush_path.read_text(encoding="utf-8"))
    if not (flushed.get("text") or "").endswith("Z"):
        errors.append(f"close flush {flushed.get('text')!r}")

    auto_note, auto_path = copy_fixture(folder, "autosave.json", pristine)
    auto["before"] = auto_path.read_bytes()
    auto_note.edit.moveCursor(QTextCursor.MoveOperation.End)
    press_key(auto_note.edit, "Q")
    auto["path"] = auto_path
    auto["note"] = auto_note


def main():
    app = QApplication(sys.argv)
    if "--check" in sys.argv:
        app.setQuitOnLastWindowClosed(False)
        return run_check(app)
    hide_dock_icon()
    app.setQuitOnLastWindowClosed(False)
    app.tray = Tray()
    if "--fixture" in sys.argv:
        index = sys.argv.index("--fixture")
        if index + 1 >= len(sys.argv):
            print("usage: main.py --fixture PATH", file=sys.stderr)
            return 2
        NoteWindow(path=sys.argv[index + 1]).show()
    else:
        open_restored()
    hide_dock_icon()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
