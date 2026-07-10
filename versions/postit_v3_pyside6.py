#!/usr/bin/env python3
"""
Postit Todo — a tiny sticky-note to-do widget for your desktop.

Type a to-do and hit Enter to add it. Click the circle to check it off,
the ✕ to delete. Everything auto-saves, so it's all still here next time.
Drag the yellow header to move it around; it floats above other windows.

Run:  python3 postit.py
"""

import json
import sys
from pathlib import Path

from PySide6.QtCore import Qt, QPoint
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QHBoxLayout, QLineEdit,
    QLabel, QPushButton, QScrollArea, QFrame,
)

# Where the to-dos live (next to this script).
SAVE_FILE = Path(__file__).resolve().parent / "todos.json"

# Sticky-note palette
BG     = "#FFF6B0"   # paper yellow
HEADER = "#FFE45C"   # darker yellow strip up top
TEXT   = "#4A4030"   # warm dark ink
DONE   = "#A89F86"   # faded ink for finished items
ACCENT = "#E5C04A"   # divider / outline


class Postit(QWidget):
    def __init__(self):
        super().__init__()
        self.todos = self.load()
        self._drag = None

        # Frameless, floats on top, tracked in the dock like a normal app.
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint)
        self.setWindowTitle("Postit")
        self.resize(260, 360)
        self.setStyleSheet(f"background:{BG};")

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        # ---- header (drag handle) ----
        header = QFrame()
        header.setStyleSheet(f"background:{HEADER};")
        header.setFixedHeight(34)
        hl = QHBoxLayout(header)
        hl.setContentsMargins(12, 0, 8, 0)
        title = QLabel("To-Do")
        title.setStyleSheet(f"color:{TEXT};")
        title.setFont(QFont("Helvetica Neue", 13, QFont.Bold))
        hl.addWidget(title)
        hl.addStretch()
        clear_btn = self.flat_button("clear done", DONE, 11)
        clear_btn.clicked.connect(self.clear_done)
        hl.addWidget(clear_btn)
        close_btn = self.flat_button("✕", TEXT, 13)
        close_btn.clicked.connect(self.close)
        hl.addWidget(close_btn)
        header.mousePressEvent = self._press
        header.mouseMoveEvent = self._move
        outer.addWidget(header)

        # ---- entry box ----
        self.entry = QLineEdit()
        self.entry.setPlaceholderText("type a to-do, hit Enter…")
        self.entry.setFont(QFont("Helvetica Neue", 13))
        self.entry.setStyleSheet(
            f"QLineEdit{{background:#FFFCE0;color:{TEXT};border:1px solid {ACCENT};"
            f"border-radius:6px;padding:7px;}}")
        self.entry.returnPressed.connect(self.add_todo)
        entry_wrap = QVBoxLayout()
        entry_wrap.setContentsMargins(12, 12, 12, 6)
        entry_wrap.addWidget(self.entry)
        outer.addLayout(entry_wrap)

        # ---- scrollable list ----
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.NoFrame)
        self.scroll.setStyleSheet("background:transparent;border:none;")
        self.list_host = QWidget()
        self.list_host.setStyleSheet(f"background:{BG};")
        self.list_layout = QVBoxLayout(self.list_host)
        self.list_layout.setContentsMargins(8, 0, 8, 8)
        self.list_layout.setSpacing(2)
        self.list_layout.addStretch()
        self.scroll.setWidget(self.list_host)
        outer.addWidget(self.scroll)

        self.render()
        self.entry.setFocus()

    # ---------- small helpers ----------
    def flat_button(self, text, color, size):
        b = QPushButton(text)
        b.setCursor(Qt.PointingHandCursor)
        b.setFont(QFont("Helvetica Neue", size))
        b.setStyleSheet(
            f"QPushButton{{background:transparent;color:{color};border:none;}}"
            f"QPushButton:hover{{color:{TEXT};}}")
        b.setFlat(True)
        return b

    # ---------- persistence ----------
    def load(self):
        if SAVE_FILE.exists():
            try:
                return json.loads(SAVE_FILE.read_text())
            except (json.JSONDecodeError, OSError):
                return []
        return []

    def save(self):
        try:
            SAVE_FILE.write_text(json.dumps(self.todos, indent=2))
        except OSError:
            pass  # never crash the widget over a failed write

    # ---------- actions ----------
    def add_todo(self):
        text = self.entry.text().strip()
        if text:
            self.todos.append({"text": text, "done": False})
            self.entry.clear()
            self.save()
            self.render()

    def toggle(self, i):
        self.todos[i]["done"] = not self.todos[i]["done"]
        self.save()
        self.render()

    def delete(self, i):
        del self.todos[i]
        self.save()
        self.render()

    def clear_done(self):
        self.todos = [t for t in self.todos if not t["done"]]
        self.save()
        self.render()

    # ---------- drawing ----------
    def render(self):
        # wipe everything except the trailing stretch
        while self.list_layout.count() > 1:
            item = self.list_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        if not self.todos:
            empty = QLabel("nothing yet — type above ↑")
            empty.setStyleSheet(f"color:{DONE};")
            empty.setFont(QFont("Helvetica Neue", 11, italic=True))
            empty.setAlignment(Qt.AlignCenter)
            self.list_layout.insertWidget(0, empty)
            return

        for i, todo in enumerate(self.todos):
            row = QFrame()
            row.setStyleSheet(f"background:{BG};")
            rl = QHBoxLayout(row)
            rl.setContentsMargins(0, 0, 0, 0)
            rl.setSpacing(4)

            check = self.flat_button("●" if todo["done"] else "○", TEXT, 14)
            check.setFixedWidth(22)
            check.clicked.connect(lambda _=False, i=i: self.toggle(i))
            rl.addWidget(check)

            lbl = QLabel(todo["text"])
            lbl.setWordWrap(True)
            f = QFont("Helvetica Neue", 13)
            f.setStrikeOut(todo["done"])
            lbl.setFont(f)
            lbl.setStyleSheet(f"color:{DONE if todo['done'] else TEXT};")
            rl.addWidget(lbl, 1)

            x = self.flat_button("✕", DONE, 11)
            x.setFixedWidth(20)
            x.clicked.connect(lambda _=False, i=i: self.delete(i))
            rl.addWidget(x)

            self.list_layout.insertWidget(self.list_layout.count() - 1, row)

    # ---------- window dragging ----------
    def _press(self, event):
        self._drag = event.globalPosition().toPoint() - self.frameGeometry().topLeft()

    def _move(self, event):
        if self._drag is not None:
            self.move(event.globalPosition().toPoint() - self._drag)


if __name__ == "__main__":
    app = QApplication(sys.argv)
    w = Postit()
    # center on the primary screen
    geo = app.primaryScreen().availableGeometry()
    w.move(geo.center().x() - w.width() // 2, geo.center().y() - w.height() // 2)
    w.show()
    w.raise_()
    w.activateWindow()
    sys.exit(app.exec())
