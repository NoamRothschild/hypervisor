#!/usr/bin/env python3
"""Live view of one serial stream of the hypervisor running under QEMU.

    vmlog.py host     the hypervisor's own log (COM1)
    vmlog.py 0        guest 0's console (COM2, see `debug.COM2`)

COM2 carries every guest's output as `[guest id][byte]` pairs, this splits out one guest.
The stream is followed from the start and survives QEMU restarts (QEMU truncates the files).
"""

import argparse
import os
import sys
import time
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent.parent / "zig-out"
POLL_SECONDS = 0.05


def follow(path: Path, keep_following: bool):
    """yields chunks appended to `path`, starting over when it gets truncated"""
    while not path.exists():
        if not keep_following:
            return
        time.sleep(POLL_SECONDS)

    with open(path, "rb") as f:
        while True:
            chunk = f.read(4096)
            if chunk:
                yield chunk
                continue
            if not keep_following:
                return
            if os.stat(path).st_size < f.tell():
                f.seek(0)
                yield None  # a new QEMU run
                continue
            time.sleep(POLL_SECONDS)


def split_guests(chunks):
    """yields `{guest id: bytes}` for each chunk of COM2, or None when the stream starts over"""
    pending = b""
    for chunk in chunks:
        if chunk is None:
            pending = b""
            yield None
            continue
        data = pending + chunk
        even = len(data) & ~1
        pending = data[even:]
        per_guest = {}
        for i in range(0, even, 2):
            per_guest.setdefault(data[i], bytearray()).append(data[i + 1])
        if per_guest:
            yield per_guest


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stream", help="`host`, or a guest index")
    parser.add_argument("-n", "--no-follow", action="store_true", help="print what is there and exit")
    parser.add_argument("--dir", type=Path, default=OUT_DIR, help="where QEMU writes the serial files (default: %(default)s)")
    args = parser.parse_args()

    follow_files = not args.no_follow
    if args.stream == "host":
        stream = (chunk for chunk in follow(args.dir / "host.serial", follow_files) if chunk)
    elif args.stream.isdigit() and int(args.stream) < 256:
        guest = int(args.stream)
        per_guest = split_guests(follow(args.dir / "guests.serial", follow_files))
        stream = (chunks[guest] for chunks in per_guest if chunks and guest in chunks)
    else:
        parser.error(f"unknown stream {args.stream!r}, expected `host` or a guest index (0-255)")

    out = sys.stdout.buffer
    try:
        for data in stream:
            out.write(data)
            out.flush()
    except (KeyboardInterrupt, BrokenPipeError):
        pass


if __name__ == "__main__":
    main()
