#!/usr/bin/env python3
"""Atomic settings write via temp-file + os.replace.

Usage: settingsWriter.py <path> <base64-data>
- argv[1]: destination path (len <= 4096)
- argv[2]: base64-encoded payload ("" allowed for idle initial state),
  decoded bytes must be <= 65536, contain no NUL, be valid UTF-8
- Parent dirs created as needed; temp file created with 0600 in the
  destination directory, fsynced, then atomically os.replace()d.
- Exits 0 on success, 1 on write refusal/failure, 2 on bad usage.
"""
import base64
import binascii
import os
import sys
import tempfile

MAX_BYTES = 65536


def eprint(*a, **k):
    print(*a, file=sys.stderr, **k)


def main():
    if len(sys.argv) != 3:
        eprint(f"usage: {sys.argv[0]} <path> <base64-data>")
        sys.exit(2)
    path = sys.argv[1]
    raw_b64 = sys.argv[2]

    if not path or len(path) > 4096:
        sys.exit(1)
    if "\x00" in path:
        sys.exit(1)

    try:
        data = base64.b64decode(raw_b64, validate=True)
    except (binascii.Error, ValueError):
        sys.exit(1)

    if len(data) > MAX_BYTES:
        eprint("payload exceeds size limit")
        sys.exit(1)
    if b"\x00" in data:
        sys.exit(1)
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        sys.exit(1)

    parent = os.path.dirname(path) or "."
    try:
        os.makedirs(parent, exist_ok=True)
    except OSError:
        sys.exit(1)

    fd = None
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=parent, prefix=".settings-")
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as f:
            fd = None  # fdopen owns the fd now
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        tmp = None
    except OSError as e:
        eprint(f"write failed: {e}")
        sys.exit(1)
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


if __name__ == "__main__":
    main()
