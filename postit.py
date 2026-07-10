#!/usr/bin/env python3
"""
Postit — a clean, liquid-glass desktop post-it.

A freeform note with real macOS background blur (frosted "liquid glass") and a
blue tint. Type whatever you want; it auto-saves as you go. Hit the ▸ icon up
top to drop a collapsible section wherever you're typing — it folds down to a
small right-facing triangle and expands to reveal its own text. Drag the top
strip to move it, grab the bottom-right corner to resize. Floats on top.

Run:  python3 postit.py
"""

import sys
import json
from pathlib import Path

from PySide6.QtCore import Qt, QRectF, QTimer
from PySide6.QtGui import QFont, QPainter, QColor, QBrush
from PySide6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QHBoxLayout, QTextEdit, QLineEdit,
    QPushButton, QToolButton, QSizeGrip, QScrollArea,
)

# Where the note lives (next to this script). New block-based format is JSON;
# the old plain-text note is read once for migration and then left alone.
BASE       = Path(__file__).resolve().parent
SAVE_FILE  = BASE / "note.json"
LEGACY_TXT = BASE / "note.txt"

# Blue liquid-glass palette. The real blur comes from macOS; this is the tint
# painted on top, so keep the alpha low enough to let the blur show through.
TINT   = QColor(46, 96, 168, 92)    # translucent blue glass
TEXT   = "#F2F6FF"                  # bright cool-white ink
DIM    = "#9FB4D0"                  # muted blue-gray for the chrome
SELECT = "#3E7BD0"                  # text-selection highlight
RADIUS = 26                         # corner roundness

# Ink swatches — the three painter's primaries, sampled from a classic RYB
# color wheel. Clicking one colors the selection (or the ink you type with
# from the cursor on); clicking it again goes back to the default ink.
INKS = [
    ("#D6382C", "Red"),
    ("#F2E23A", "Yellow"),
    ("#2E4DA7", "Blue"),
]


def flat(selector, color, hover=None):
    """Stylesheet for a transparent, borderless control in the given ink color,
    with an optional hover color. Used for nearly every button and field so the
    chrome disappears into the glass."""
    css = f"{selector}{{background:transparent;color:{color};border:none;}}"
    if hover:
        css += f"{selector}:hover{{color:{hover};}}"
    return css


def apply_liquid_glass(widget, radius):
    """Put a native macOS NSVisualEffectView behind the Qt content so the
    desktop shows through, blurred. Fails quietly if the bridge isn't there."""
    try:
        import objc
        from AppKit import NSVisualEffectView

        NSViewWidthSizable, NSViewHeightSizable = 2, 16
        BLEND_BEHIND_WINDOW = 0
        STATE_ACTIVE = 1
        MATERIAL_HUD = 13  # dark, glassy base to tint blue

        view = objc.objc_object(c_void_p=int(widget.winId()))
        window = view.window()
        window.setOpaque_(False)

        content = window.contentView()
        content.retain()  # keep it alive across the contentView swap
        content.setWantsLayer_(True)
        content.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)

        glass = NSVisualEffectView.alloc().initWithFrame_(content.frame())
        glass.setMaterial_(MATERIAL_HUD)
        glass.setBlendingMode_(BLEND_BEHIND_WINDOW)
        glass.setState_(STATE_ACTIVE)
        glass.setWantsLayer_(True)
        glass.layer().setCornerRadius_(radius)
        glass.layer().setMasksToBounds_(True)
        glass.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)

        # reparent Qt's content view inside the glass so it draws on top of it
        window.setContentView_(glass)
        glass.addSubview_(content)
        content.setFrame_(glass.bounds())

        # the swap breaks the responder chain — restore it so keys reach Qt
        window.makeFirstResponder_(content)
        return True
    except Exception as e:  # noqa: BLE001 — non-fatal, just skip the blur
        print(f"[postit] native blur unavailable: {e}", file=sys.stderr)
        return False


class GrowingTextEdit(QTextEdit):
    """A borderless text area that grows to fit its content, so blocks can
    stack naturally inside the scroll column instead of scrolling internally."""

    def __init__(self, text="", padding_left=0, html=None):
        super().__init__()
        self.setFont(QFont("Helvetica Neue", 15))
        self.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        pad = f"padding-left:{padding_left}px;" if padding_left else ""
        self.setStyleSheet(
            f"QTextEdit{{background:transparent;color:{TEXT};border:none;"
            f"{pad}selection-background-color:{SELECT};}}")
        # html carries per-character ink colors; plain text is the fallback
        if html:
            self.setHtml(html)
        else:
            self.setText(text)
        self.document().contentsChanged.connect(self._fit)
        self._fit()

    def _fit(self):
        h = self.document().size().height()
        self.setFixedHeight(max(28, int(h) + 8))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._fit()

    def keyPressEvent(self, event):
        # The ink swatches, not the surrounding text, decide the typing
        # color: with no swatch active you always type in the default white,
        # even with the cursor parked inside colored text. Enforced here,
        # right before the character lands, so Qt's inherit-from-neighbor
        # format can't override it.
        win = self.window()
        if hasattr(win, "_ink") and not self.textCursor().hasSelection():
            want = QColor(win._ink or TEXT)
            if self.textColor() != want:
                self.setTextColor(want)
        super().keyPressEvent(event)


class TextBlock(QWidget):
    """A plain freeform paragraph — the default writing surface."""

    def __init__(self, text="", on_change=None, html=None):
        super().__init__()
        lay = QVBoxLayout(self)
        lay.setContentsMargins(16, 2, 16, 2)
        self.edit = GrowingTextEdit(text, html=html)
        if on_change:
            self.edit.textChanged.connect(on_change)
        lay.addWidget(self.edit)

    def to_dict(self):
        # keep the plain text alongside the html so old versions (and humans
        # reading note.json) still see something sensible
        return {"type": "text", "text": self.edit.toPlainText(),
                "html": self.edit.toHtml()}


class Dropdown(QWidget):
    """A collapsible section: a triangle + title that folds down to hide a
    text body. Click the triangle to expand (▾) or collapse (▸)."""

    def __init__(self, title="", body="", collapsed=False,
                 on_change=None, on_delete=None, body_html=None):
        super().__init__()
        self._on_change = on_change
        self._on_delete = on_delete

        # minimalist rounded outline so the section's position and size read
        # at a glance — the box grows with the body and shrinks when collapsed
        self.setObjectName("dropdownCard")
        self.setAttribute(Qt.WA_StyledBackground, True)
        self.setStyleSheet(
            "#dropdownCard{border:1px solid rgba(242,246,255,0.28);"
            "border-radius:12px;background:rgba(242,246,255,0.05);}")

        outer = QVBoxLayout(self)
        outer.setContentsMargins(10, 6, 10, 6)
        outer.setSpacing(2)

        # ---- header row: triangle toggle + title + delete ----
        header = QHBoxLayout()
        header.setContentsMargins(0, 0, 0, 0)
        header.setSpacing(6)

        self.toggle = QToolButton()
        self.toggle.setCursor(Qt.PointingHandCursor)
        self.toggle.setFont(QFont("Helvetica Neue", 13))
        self.toggle.setStyleSheet(flat("QToolButton", TEXT))
        self.toggle.clicked.connect(self.toggle_open)
        header.addWidget(self.toggle)

        self.title = QLineEdit(title)
        self.title.setFont(QFont("Helvetica Neue", 15, QFont.DemiBold))
        self.title.setStyleSheet(flat("QLineEdit", TEXT))
        if on_change:
            self.title.textChanged.connect(on_change)
        header.addWidget(self.title, 1)

        self.delete = QPushButton("✕")
        self.delete.setCursor(Qt.PointingHandCursor)
        self.delete.setFont(QFont("Helvetica Neue", 11))
        self.delete.setFixedSize(18, 18)
        self.delete.setStyleSheet(flat("QPushButton", DIM, hover=TEXT))
        self.delete.clicked.connect(self._delete)
        header.addWidget(self.delete)
        outer.addLayout(header)

        # ---- collapsible body (indented so it reads as "inside" the section) ----
        self.body = GrowingTextEdit(body, padding_left=20, html=body_html)
        if on_change:
            self.body.textChanged.connect(on_change)
        outer.addWidget(self.body)

        self._collapsed = collapsed
        self._apply_state()

    def _apply_state(self):
        self.toggle.setText("▸" if self._collapsed else "▾")
        self.body.setVisible(not self._collapsed)

    def toggle_open(self):
        self._collapsed = not self._collapsed
        self._apply_state()
        if self._on_change:
            self._on_change()

    def _delete(self):
        if self._on_delete:
            self._on_delete(self)

    def focus_title(self):
        self.title.setFocus()

    def to_dict(self):
        return {
            "type": "dropdown",
            "title": self.title.text(),
            "text": self.body.toPlainText(),
            "html": self.body.toHtml(),
            "collapsed": self._collapsed,
        }


class Postit(QWidget):
    def __init__(self):
        super().__init__()
        self._drag = None
        self._active_block = None
        self._active_edit = None   # last-focused text area, for the ink swatches
        self._ink = None           # current ink color, None = default white
        self._swatches = {}

        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setWindowTitle("Postit")
        self.resize(300, 320)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        # ---- top strip: add-dropdown icon + drag handle + close ----
        strip = QHBoxLayout()
        strip.setContentsMargins(12, 10, 10, 2)

        add = QToolButton()
        add.setText("＋▾")
        add.setToolTip("Add a dropdown at the cursor")
        add.setCursor(Qt.PointingHandCursor)
        add.setFont(QFont("Helvetica Neue", 13, QFont.DemiBold))
        add.setFixedHeight(22)
        add.setStyleSheet(
            f"QToolButton{{background:rgba(242,246,255,0.10);color:{TEXT};"
            f"border:1px solid rgba(242,246,255,0.22);border-radius:8px;"
            f"padding:0px 8px;}}"
            f"QToolButton:hover{{background:rgba(242,246,255,0.20);}}")
        add.clicked.connect(self.add_dropdown)
        strip.addWidget(add)

        # ---- ink swatches: three primaries; click to color, re-click to reset ----
        strip.addSpacing(10)
        for color, name in INKS:
            dot = QToolButton()
            dot.setFixedSize(16, 16)
            dot.setCursor(Qt.PointingHandCursor)
            # NoFocus keeps the click from stealing focus, so the text
            # selection in the note stays live while you pick a color
            dot.setFocusPolicy(Qt.NoFocus)
            dot.setToolTip(f"{name} ink — click again for default")
            dot.clicked.connect(lambda _=False, c=color: self.set_ink(c))
            self._swatches[color] = dot
            strip.addWidget(dot)
            strip.addSpacing(4)
        self._style_swatches()

        strip.addStretch()
        close = QPushButton("✕")
        close.setCursor(Qt.PointingHandCursor)
        close.setFont(QFont("Helvetica Neue", 12))
        close.setFixedSize(20, 20)
        close.setStyleSheet(flat("QPushButton", DIM, hover=TEXT))
        close.clicked.connect(self.close)
        strip.addWidget(close)
        outer.addLayout(strip)

        # ---- scrollable column of blocks ----
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QScrollArea.NoFrame)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.scroll.setStyleSheet("QScrollArea{background:transparent;border:none;}")
        self.scroll.viewport().setStyleSheet("background:transparent;")

        self.container = QWidget()
        self.container.setStyleSheet("background:transparent;")
        self.block_layout = QVBoxLayout(self.container)
        self.block_layout.setContentsMargins(6, 0, 6, 4)
        self.block_layout.setSpacing(4)
        self.block_layout.addStretch()  # keeps blocks pinned to the top
        self.scroll.setWidget(self.container)
        outer.addWidget(self.scroll, 1)

        # ---- resize grip in the bottom-right ----
        grip_row = QHBoxLayout()
        grip_row.setContentsMargins(0, 0, 4, 4)
        grip_row.addStretch()
        grip_row.addWidget(QSizeGrip(self))
        outer.addLayout(grip_row)

        # debounce saves so we're not hammering the disk on every keystroke
        self._save_timer = QTimer(self)
        self._save_timer.setSingleShot(True)
        self._save_timer.setInterval(400)
        self._save_timer.timeout.connect(self.save)

        # track which block the cursor is in, so new dropdowns land there
        QApplication.instance().focusChanged.connect(self._on_focus)

        self.load()

    # ---------- block helpers ----------
    def _blocks(self):
        """All block widgets in order (everything but the trailing stretch)."""
        out = []
        for i in range(self.block_layout.count()):
            w = self.block_layout.itemAt(i).widget()
            if isinstance(w, (TextBlock, Dropdown)):
                out.append(w)
        return out

    def _add_text(self, text="", html=None):
        block = TextBlock(text, on_change=self.schedule_save, html=html)
        self.block_layout.insertWidget(self.block_layout.count() - 1, block)
        return block

    def add_dropdown(self):
        d = Dropdown(collapsed=False,
                     on_change=self.schedule_save, on_delete=self.remove_block)
        # drop it right after whatever block the cursor was last in
        index = self.block_layout.count() - 1  # default: just before stretch
        if self._active_block is not None:
            idx = self.block_layout.indexOf(self._active_block)
            if idx != -1:
                index = idx + 1
        self.block_layout.insertWidget(index, d)
        d.focus_title()
        self.schedule_save()

    def remove_block(self, widget):
        self.block_layout.removeWidget(widget)
        widget.deleteLater()
        if self._active_block is widget:
            self._active_block = None
        if self._active_edit is not None and widget.isAncestorOf(self._active_edit):
            self._active_edit = None
        # never leave the note with nothing to type in (widget is already gone)
        if not self._blocks():
            self._add_text("")
        self.schedule_save()

    def _on_focus(self, old, now):
        """Walk up from the focused widget to find which block owns it."""
        if isinstance(now, GrowingTextEdit):
            self._active_edit = now
        w = now
        while w is not None:
            if isinstance(w, (TextBlock, Dropdown)):
                self._active_block = w
                return
            w = w.parentWidget()

    # ---------- ink swatches ----------
    def set_ink(self, color):
        """Color the selection in the active text area, or the ink you'll type
        with from the cursor on. Clicking the active swatch resets to default."""
        self._ink = None if self._ink == color else color
        self._style_swatches()
        edit = self._active_edit
        if edit is None:
            return
        edit.setTextColor(QColor(self._ink or TEXT))
        edit.setFocus()
        self.schedule_save()

    def _style_swatches(self):
        for color, dot in self._swatches.items():
            active = color == self._ink
            ring = "rgba(255,255,255,0.95)" if active else "rgba(242,246,255,0.30)"
            dot.setStyleSheet(
                f"QToolButton{{background:{color};border-radius:8px;"
                f"border:{'2' if active else '1'}px solid {ring};}}"
                f"QToolButton:hover{{border:2px solid rgba(255,255,255,0.85);}}")

    # ---------- blue glass tint painted over the native blur ----------
    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setPen(Qt.NoPen)
        p.setBrush(QBrush(TINT))
        p.drawRoundedRect(QRectF(self.rect()), RADIUS, RADIUS)

    # ---------- persistence ----------
    def load(self):
        blocks = self._read_blocks()
        for b in blocks:
            if b.get("type") == "dropdown":
                self.block_layout.insertWidget(
                    self.block_layout.count() - 1,
                    Dropdown(b.get("title", ""), b.get("text", ""),
                             b.get("collapsed", False),
                             on_change=self.schedule_save,
                             on_delete=self.remove_block,
                             body_html=b.get("html")))
            else:
                self._add_text(b.get("text", ""), html=b.get("html"))
        if not self._blocks():
            self._add_text("")
        self._blocks()[0].setFocus()

    def _read_blocks(self):
        """New JSON format if present; otherwise migrate the legacy note.txt."""
        if SAVE_FILE.exists():
            try:
                data = json.loads(SAVE_FILE.read_text())
                if isinstance(data, list):
                    return data
            except (OSError, ValueError):
                pass
        if LEGACY_TXT.exists():
            try:
                return [{"type": "text", "text": LEGACY_TXT.read_text()}]
            except OSError:
                pass
        return []

    def schedule_save(self):
        self._save_timer.start()

    def save(self):
        try:
            data = [b.to_dict() for b in self._blocks()]
            SAVE_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        except OSError:
            pass  # never crash the widget over a failed write

    def closeEvent(self, event):
        self.save()
        event.accept()

    # ---------- drag the window by the top strip ----------
    def mousePressEvent(self, event):
        if event.position().y() <= 40:
            self._drag = event.globalPosition().toPoint() - self.frameGeometry().topLeft()

    def mouseMoveEvent(self, event):
        if self._drag is not None:
            self.move(event.globalPosition().toPoint() - self._drag)

    def mouseReleaseEvent(self, event):
        self._drag = None


if __name__ == "__main__":
    app = QApplication(sys.argv)
    w = Postit()
    geo = app.primaryScreen().availableGeometry()
    w.move(geo.center().x() - w.width() // 2, geo.center().y() - w.height() // 2)
    w.show()
    apply_liquid_glass(w, RADIUS)   # after show(): winId() is valid now
    w.raise_()
    w.activateWindow()
    sys.exit(app.exec())
