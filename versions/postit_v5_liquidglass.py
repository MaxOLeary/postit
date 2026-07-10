#!/usr/bin/env python3
"""
Postit — a clean, liquid-glass desktop post-it.

A freeform text area with real macOS background blur (frosted "liquid glass")
and a blue tint. Type whatever you want; it auto-saves as you go. Drag the top
strip to move it, grab the bottom-right corner to resize. Floats on top.

Run:  python3 postit.py
"""

import sys
from pathlib import Path

from PySide6.QtCore import Qt, QRectF, QTimer
from PySide6.QtGui import QFont, QPainter, QColor, QBrush
from PySide6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QHBoxLayout, QTextEdit,
    QPushButton, QSizeGrip,
)

# Where the note lives (next to this script).
SAVE_FILE = Path(__file__).resolve().parent / "note.txt"

# Blue liquid-glass palette. The real blur comes from macOS; this is the tint
# painted on top, so keep the alpha low enough to let the blur show through.
TINT   = QColor(46, 96, 168, 92)    # translucent blue glass
TEXT   = "#F2F6FF"                  # bright cool-white ink
DIM     = "#9FB4D0"                 # muted blue-gray for the X
RADIUS = 26                         # corner roundness


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
        return True
    except Exception as e:  # noqa: BLE001 — non-fatal, just skip the blur
        print(f"[postit] native blur unavailable: {e}", file=sys.stderr)
        return False


class Postit(QWidget):
    def __init__(self):
        super().__init__()
        self._drag = None

        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setWindowTitle("Postit")
        self.resize(300, 320)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        # ---- top strip: drag handle + close button ----
        strip = QHBoxLayout()
        strip.setContentsMargins(14, 10, 10, 2)
        strip.addStretch()
        close = QPushButton("✕")
        close.setCursor(Qt.PointingHandCursor)
        close.setFont(QFont("Helvetica Neue", 12))
        close.setFixedSize(20, 20)
        close.setStyleSheet(
            f"QPushButton{{background:transparent;color:{DIM};border:none;}}"
            f"QPushButton:hover{{color:{TEXT};}}")
        close.clicked.connect(self.close)
        strip.addWidget(close)
        outer.addLayout(strip)

        # ---- the freeform text area ----
        self.text = QTextEdit()
        self.text.setFont(QFont("Helvetica Neue", 15))
        self.text.setStyleSheet(
            f"QTextEdit{{background:transparent;color:{TEXT};border:none;"
            f"padding:4px 16px 8px 16px;selection-background-color:#3E7BD0;}}")
        self.text.setText(self.load())
        self.text.textChanged.connect(self.schedule_save)
        outer.addWidget(self.text)

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

        self.text.setFocus()

    # ---------- blue glass tint painted over the native blur ----------
    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setPen(Qt.NoPen)
        p.setBrush(QBrush(TINT))
        p.drawRoundedRect(QRectF(self.rect()), RADIUS, RADIUS)

    # ---------- persistence ----------
    def load(self):
        if SAVE_FILE.exists():
            try:
                return SAVE_FILE.read_text()
            except OSError:
                return ""
        return ""

    def schedule_save(self):
        self._save_timer.start()

    def save(self):
        try:
            SAVE_FILE.write_text(self.text.toPlainText())
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
