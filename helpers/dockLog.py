#!/usr/bin/env python3
"""Timestamped single-line append to the dock debug log.

Usage: dockLog.py <logpath> <tag> <message>
- Appends "<UTC-iso> [tag] message\\n" to <logpath> (parents created).
- tag/message are flattened to one line (CR/LF/TAB -> space), NUL
  rejected, each truncated to 2048 chars; must be valid UTF-8.
- Rotates once at 256 KiB: <logpath>.1 is replaced, <logpath> renamed.
- Log file created 0600 (may contain window titles / app names).
- Exits 0 on success, 1 on refusal/failure, 2 on bad usage.
"""
import datetime
import os
import sys

MAX_ARG = 2048
MAX_BYTES = 256 * 1024


def eprint(*a, **k):
    print(*a, file=sys.stderr, **k)


def clean(s):
    if "\x00" in s:
        return None
    s = s.replace("\r", " ").replace("\n", " ").replace("\t", " ")
    return s[:MAX_ARG]


def main():
    if len(sys.argv) != 4:
        eprint(f"usage: {sys.argv[0]} <logpath> <tag> <message>")
        sys.exit(2)
    logpath, raw_tag, raw_msg = sys.argv[1], sys.argv[2], sys.argv[3]

    if not logpath or len(logpath) > 4096 or "\x00" in logpath:
        sys.exit(1)
    tag = clean(raw_tag)
    msg = clean(raw_msg)
    if tag is None or msg is None:
        sys.exit(1)
    if not tag:
        tag = "dock"
    try:
        (tag + msg).encode("utf-8")
    except UnicodeEncodeError:
        sys.exit(1)

    parent = os.path.dirname(logpath) or "."
    try:
        os.makedirs(parent, exist_ok=True)
    except OSError:
        sys.exit(1)

    try:
        try:
            if os.path.getsize(logpath) >= MAX_BYTES:
                try:
                    os.replace(logpath, logpath + ".1")
                except FileNotFoundError:
                    pass
        except FileNotFoundError:
            pass
        except OSError:
            pass
        ts = datetime.datetime.now(datetime.timezone.utc).isoformat(
            timespec="seconds")
        line = f"{ts} [{tag}] {msg}\n".encode("utf-8")
        fd = os.open(logpath, os.O_WRONLY | os.O_CREAT | os.O_APPEND |
                     getattr(os, "O_CLOEXEC", 0), 0o600)
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, line)
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as e:
        eprint(f"append failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
