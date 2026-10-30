#!/usr/bin/env python3
"""Live view of every serial stream of the hypervisor running under QEMU, one tab per machine.

Starts with a `host` tab (COM1), and adds a `vm N` tab the first time guest N shows up on COM2.
On a `vm N` tab, what you type goes to guest N, as `[N][byte]` pairs into COM2's socket.
With --split-view every machine gets a pane side by side instead, and typing goes to the focused one.
With --launch it starts QEMU itself, and stops it on exit (see `zig build tui`).

keys:  ←/→         switch tab, or the focused pane (a `*` marks a tab with output you have not seen)
       ↑/↓         scroll back
       PgUp/PgDn   scroll back a page
       End         back to live output
       Ctrl+C      quit
"""

import argparse
import codecs
import curses
import queue
import socket
import subprocess
import threading
from pathlib import Path

from vmlog import OUT_DIR, follow, split_guests

HOST = "host"
MAX_LINES = 20000
POLL_MS = 50


class Stream:
    """the text one machine printed, with just enough of a terminal to replay a shell's output:
    `\\r` and `\\b` move the cursor back, erasing to the end of the line (`ESC[J`, `ESC[K`, a shell's
    backspace) cuts the line at the cursor, other escape sequences (colors and such) are dropped"""

    def __init__(self):
        self.clear()
        self.unseen = False

    def clear(self):
        # lines up from the bottom, 0 follows new output
        self.scroll = 0
        self.lines = [[]]
        self.col = 0
        self.esc = None  # None, "esc" or "csi"
        self.csi_params = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def feed(self, data: bytes):
        for ch in self.decoder.decode(data):
            if self.esc == "esc":
                self.esc = "csi" if ch == "[" else None
                self.csi_params = ""
            elif self.esc == "csi":
                if "\x40" <= ch <= "\x7e":
                    self.esc = None
                    if ch in "JK" and self.csi_params in ("", "0"):
                        del self.lines[-1][self.col :]
                else:
                    self.csi_params += ch
            elif ch == "\x1b":
                self.esc = "esc"
            elif ch == "\n":
                self.lines.append([])
                self.col = 0
                if self.scroll:
                    self.scroll += 1  # keep a scrolled back view still
            elif ch == "\r":
                self.col = 0
            elif ch == "\b":
                self.col = max(0, self.col - 1)
            elif ch == "\t":
                for _ in range(8 - self.col % 8):
                    self.put(" ")
            elif ch >= " ":
                self.put(ch)
        if len(self.lines) > MAX_LINES:
            del self.lines[: len(self.lines) - MAX_LINES]
            self.scroll = min(self.scroll, len(self.lines) - 1)

    def put(self, ch: str):
        line = self.lines[-1]
        if self.col < len(line):
            line[self.col] = ch
        else:
            line.append(ch)
        self.col += 1

    def rows(self, width: int, height: int) -> list[str]:
        """the last `height` screen rows of the view, long lines wrapped at `width`"""
        end = len(self.lines) - self.scroll
        rows = []
        for line in reversed(self.lines[:end]):
            text = "".join(line)
            wrapped = [text[i : i + width] for i in range(0, len(text), width)] or [""]
            rows[:0] = wrapped
            if len(rows) >= height:
                break
        return rows[-height:]


def discard_output(sock: socket.socket):
    """QEMU also sends COM2's output to the socket (the TUI reads it from the log file instead).
    left unread, the socket fills up after a few hundred bytes, and COM2 stops sending, so drain it."""
    try:
        while sock.recv(65536):
            pass
    except OSError:
        pass


class GuestInput:
    """COM2's socket, connected on the first key and again after QEMU restarts"""

    def __init__(self, path: Path):
        self.path = path
        self.sock = None

    def send(self, guest_id: int, data: bytes) -> bool:
        payload = bytes(b for byte in data for b in (guest_id, byte))
        for _ in range(2):
            try:
                if self.sock is None:
                    self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    self.sock.connect(str(self.path))
                    threading.Thread(target=discard_output, args=(self.sock,), daemon=True).start()
                self.sock.sendall(payload)
                return True
            except OSError:
                if self.sock is not None:
                    self.sock.close()
                self.sock = None
        return False


def key_bytes(key: int) -> bytes | None:
    """what a key sends to a guest, as a serial terminal would. None for the keys the TUI keeps"""
    if key in (curses.KEY_ENTER, ord("\n")):
        return b"\r"
    if key == curses.KEY_BACKSPACE:
        return b"\x7f"
    if 0 <= key < 256:
        return bytes([key])
    return None


def forward(events: queue.Queue, source: str, items):
    """runs in its own thread, so waiting on a file never stalls the screen"""
    for item in items:
        events.put((source, item))


class App:
    def __init__(self, scr, out_dir: Path, split: bool = False, qemu: subprocess.Popen | None = None):
        self.scr = scr
        self.split = split
        self.qemu = qemu
        self.streams = {HOST: Stream()}
        self.order = [HOST]
        self.selected = HOST
        self.input = GuestInput(out_dir / "guests.sock")
        self.input_failed = False

        self.events = queue.Queue()
        host = follow(out_dir / "host.serial", True)
        guests = split_guests(follow(out_dir / "guests.serial", True))
        for source, items in ((HOST, host), ("guests", guests)):
            threading.Thread(target=forward, args=(self.events, source, items), daemon=True).start()

        curses.curs_set(0)
        # no mousemask: catching the mouse would stop the terminal from selecting text
        scr.timeout(POLL_MS)
        self.colors = {"bar": curses.A_REVERSE, "selected": curses.A_BOLD, "unseen": curses.A_REVERSE | curses.A_BOLD}
        if curses.has_colors():
            curses.start_color()
            curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)
            curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_CYAN)
            curses.init_pair(3, curses.COLOR_YELLOW, curses.COLOR_BLUE)
            self.colors = {
                "bar": curses.color_pair(1),
                "selected": curses.color_pair(2) | curses.A_BOLD,
                "unseen": curses.color_pair(3) | curses.A_BOLD,
            }

    def stream(self, name: str) -> Stream:
        if name not in self.streams:
            self.streams[name] = Stream()
            self.order = [HOST] + sorted(self.streams.keys() - {HOST}, key=lambda n: int(n.split()[1]))
        return self.streams[name]

    def drain_events(self):
        while not self.events.empty():
            source, payload = self.events.get()
            if payload is None:
                # a new QEMU run, the tabs stay but start over
                for name, stream in self.streams.items():
                    if (name == HOST) == (source == HOST):
                        stream.clear()
                continue
            per_stream = {HOST: payload} if source == HOST else {f"vm {g}": data for g, data in payload.items()}
            for name, data in per_stream.items():
                stream = self.stream(name)
                stream.feed(data)
                if name != self.selected and not self.split:
                    stream.unseen = True

    def select(self, name: str):
        self.selected = name
        self.streams[name].unseen = False

    def handle_key(self, key: int):
        stream = self.streams[self.selected]
        # rows of output, without the bar and a pane's title
        height = self.scr.getmaxyx()[0] - (2 if self.split else 1)
        index = self.order.index(self.selected)
        if key == curses.KEY_RIGHT:
            self.select(self.order[(index + 1) % len(self.order)])
        elif key == curses.KEY_LEFT:
            self.select(self.order[(index - 1) % len(self.order)])
        elif key == curses.KEY_UP:
            stream.scroll += 1
        elif key == curses.KEY_DOWN:
            stream.scroll -= 1
        elif key == curses.KEY_PPAGE:
            stream.scroll += height - 1
        elif key == curses.KEY_NPAGE:
            stream.scroll -= height - 1
        elif key == curses.KEY_END:
            stream.scroll = 0
        elif self.selected != HOST and (data := key_bytes(key)) is not None:
            self.input_failed = not self.input.send(int(self.selected.split()[1]), data)
            # the guest echoes it, show that
            stream.scroll = 0
        stream.scroll = max(0, min(stream.scroll, len(stream.lines) - 1))

    def draw(self):
        scr = self.scr
        height, width = scr.getmaxyx()
        scr.erase()
        if height < 2 or width < 10:
            scr.refresh()
            return

        stream = self.streams[self.selected]
        if self.split:
            self.draw_panes(width, height - 1)
        else:
            for y, row in enumerate(stream.rows(width, height - 1)):
                scr.addstr(y, 0, row)

        bar_y = height - 1
        # insstr, addstr fails on the bottom right cell
        scr.insstr(bar_y, 0, " " * width, self.colors["bar"])

        x = 0
        for i, name in enumerate(self.order):
            s = self.streams[name]
            label = f" {i + 1}:{name}{'*' if s.unseen else ' '}"
            if x + len(label) >= width:
                break
            style = self.colors["selected"] if name == self.selected else self.colors["unseen"] if s.unseen else self.colors["bar"]
            scr.addstr(bar_y, x, label, style)
            x += len(label) + 1

        if self.qemu is not None and self.qemu.poll() is not None:
            hint = f"QEMU exited ({self.qemu.returncode}), see qemu.log "
        elif self.input_failed:
            hint = f"cannot reach {self.input.path.name}, is QEMU running? "
        elif stream.scroll:
            hint = f"[scrolled {stream.scroll}] End: live "
        else:
            hint = f"←/→ {'focus' if self.split else 'switch'}  PgUp/PgDn scroll  Ctrl+C quit "
        if x + len(hint) < width:
            scr.addstr(bar_y, width - len(hint) - 1, hint, self.colors["bar"])
        scr.refresh()

    def draw_panes(self, width: int, height: int):
        """a column per machine, its name on top, split by vertical lines"""
        scr = self.scr
        count = len(self.order)
        pane_width = (width - (count - 1)) // count
        x = 0
        for i, name in enumerate(self.order):
            # the last pane takes what the division left over
            w = width - x if i == count - 1 else pane_width
            if w < 1:
                break
            stream = self.streams[name]
            title = f" {name}" + (f" [scrolled {stream.scroll}]" if stream.scroll else "")
            style = self.colors["selected"] if name == self.selected else self.colors["bar"]
            scr.addstr(0, x, title.ljust(w)[:w], style)
            for y, row in enumerate(stream.rows(w, height - 1)):
                scr.addstr(1 + y, x, row)
            x += w
            if i != count - 1:
                scr.vline(0, x, curses.ACS_VLINE, height)
                x += 1

    def run(self):
        # redrawn every tick, curses only sends the terminal what changed
        while True:
            self.drain_events()
            self.draw()
            key = self.scr.getch()
            if key not in (-1, curses.KEY_RESIZE):
                self.handle_key(key)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", type=Path, default=OUT_DIR, help="where QEMU writes the serial files (default: %(default)s)")
    parser.add_argument("--split-view", action="store_true", help="show every machine at once, a pane each, side by side")
    parser.add_argument(
        "--launch",
        nargs=argparse.REMAINDER,
        metavar="QEMU",
        help="start this QEMU command (everything after --launch) after removing the old serial files, "
        "and stop it on exit. its own output goes to qemu.log, next to the serial files",
    )
    args = parser.parse_args()

    qemu = None
    if args.launch:
        # otherwise the last run's output shows until QEMU truncates them
        for name in ("host.serial", "guests.serial"):
            (args.dir / name).unlink(missing_ok=True)
        with open(args.dir / "qemu.log", "wb") as log:
            # its own session, so Ctrl+C reaches only the TUI, which stops it below
            qemu = subprocess.Popen(args.launch, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        curses.wrapper(lambda scr: App(scr, args.dir, args.split_view, qemu).run())
    except KeyboardInterrupt:
        pass
    finally:
        if qemu is not None:
            qemu.terminate()
            try:
                qemu.wait(timeout=5)
            except subprocess.TimeoutExpired:
                qemu.kill()


if __name__ == "__main__":
    main()
