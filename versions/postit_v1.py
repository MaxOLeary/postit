#!/usr/bin/env python3
"""
Postit Todo — a tiny sticky-note to-do widget for your desktop.

Type a to-do, hit Enter to add it. Click the circle to check it off.
Everything auto-saves, so it's all still here next time you open it.

Run:  python3 postit.py
"""

import json
import tkinter as tk
import tkinter.font as tkfont
from pathlib import Path

# Where the to-dos live (next to this script).
SAVE_FILE = Path(__file__).resolve().parent / "todos.json"

# Sticky-note look
BG       = "#FFF6B0"   # paper yellow
HEADER   = "#FFE45C"   # darker yellow strip up top
TEXT     = "#4A4030"   # warm dark ink
DONE     = "#A89F86"   # faded ink for finished items
ACCENT   = "#E5C04A"   # divider lines


class Postit:
    def __init__(self, root):
        self.root = root
        self.todos = self.load()

        root.title("Postit")
        root.configure(bg=BG)
        root.geometry("260x340+80+80")   # width x height + x + y on screen
        root.minsize(200, 220)
        root.attributes("-topmost", True)  # float above other windows

        self.font     = tkfont.Font(family="Helvetica", size=13)
        self.font_str = tkfont.Font(family="Helvetica", size=13, overstrike=1)
        self.title_f  = tkfont.Font(family="Helvetica", size=12, weight="bold")

        # --- header strip (also used to drag the window around) ---
        header = tk.Frame(root, bg=HEADER, height=30)
        header.pack(fill="x", side="top")
        header.pack_propagate(False)
        tk.Label(header, text="  To-Do", bg=HEADER, fg=TEXT,
                 font=self.title_f).pack(side="left")
        tk.Button(header, text="clear done", bg=HEADER, fg=TEXT, bd=0,
                  activebackground=ACCENT, font=("Helvetica", 10),
                  command=self.clear_done, cursor="hand2").pack(side="right", padx=4)
        for w in (header, ) + header.winfo_children():
            w.bind("<ButtonPress-1>", self.start_drag)
            w.bind("<B1-Motion>", self.on_drag)

        # --- entry box ---
        entry_wrap = tk.Frame(root, bg=BG)
        entry_wrap.pack(fill="x", padx=10, pady=(10, 4))
        self.entry = tk.Entry(entry_wrap, bg="#FFFCE0", fg=TEXT, bd=0,
                              insertbackground=TEXT, font=self.font,
                              relief="flat", highlightthickness=1,
                              highlightbackground=ACCENT, highlightcolor=ACCENT)
        self.entry.pack(fill="x", ipady=5, ipadx=4)
        self.entry.insert(0, "")
        self.entry.bind("<Return>", self.add_todo)
        self.entry.focus_set()

        # --- scrollable list of todos ---
        self.list_frame = tk.Frame(root, bg=BG)
        self.list_frame.pack(fill="both", expand=True, padx=6, pady=(4, 8))

        self.render()

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
            pass  # don't crash the widget over a failed write

    # ---------- actions ----------
    def add_todo(self, event=None):
        text = self.entry.get().strip()
        if text:
            self.todos.append({"text": text, "done": False})
            self.entry.delete(0, "end")
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
        for w in self.list_frame.winfo_children():
            w.destroy()

        if not self.todos:
            tk.Label(self.list_frame, text="nothing yet — type above ↑",
                     bg=BG, fg=DONE, font=("Helvetica", 11, "italic")).pack(pady=20)
            return

        for i, todo in enumerate(self.todos):
            row = tk.Frame(self.list_frame, bg=BG)
            row.pack(fill="x", pady=1)

            box = "●" if todo["done"] else "○"
            tk.Button(row, text=box, bg=BG, fg=TEXT, bd=0, font=self.font,
                      activebackground=BG, cursor="hand2",
                      command=lambda i=i: self.toggle(i)).pack(side="left")

            lbl = tk.Label(row, text=todo["text"], bg=BG, anchor="w",
                           justify="left", wraplength=180,
                           fg=DONE if todo["done"] else TEXT,
                           font=self.font_str if todo["done"] else self.font)
            lbl.pack(side="left", fill="x", expand=True)
            lbl.bind("<Button-1>", lambda e, i=i: self.toggle(i))

            tk.Button(row, text="✕", bg=BG, fg=DONE, bd=0,
                      font=("Helvetica", 10), activebackground=BG,
                      cursor="hand2",
                      command=lambda i=i: self.delete(i)).pack(side="right")

    # ---------- window dragging ----------
    def start_drag(self, event):
        self._dx, self._dy = event.x, event.y

    def on_drag(self, event):
        x = self.root.winfo_x() + event.x - self._dx
        y = self.root.winfo_y() + event.y - self._dy
        self.root.geometry(f"+{x}+{y}")


if __name__ == "__main__":
    root = tk.Tk()
    Postit(root)
    root.mainloop()
