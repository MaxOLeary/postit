#!/usr/bin/env python3
"""
Postit — a clean, frosted desktop post-it.

Just a freeform text area. Type whatever you want; it auto-saves as you go,
so it's all still here next time. Drag the top strip to move it, grab the
bottom-right corner to resize. Floats above other windows.

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

# Frosted-dark palette (matches the macOS widget look)
PAPER  = QColor(38, 46, 46, 232)   # translucent dark teal-gray
TEXT   = "#E9ECEA"                 # soft off-white ink
DIM    = "#7E8A88"                 # muted gray for the X
RADIUS = 26                        # corner roundness


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
            f"padding:4px 16px 8px 16px;selection-background-color:#3A6B63;}}")
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

    # ---------- rounded frosted background ----------
    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setPen(Qt.NoPen)
        p.setBrush(QBrush(PAPER))
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
    w.raise_()
    w.activateWindow()
    sys.exit(app.exec())
