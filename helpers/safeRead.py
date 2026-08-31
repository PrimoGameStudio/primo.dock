#!/usr/bin/env python3
"""Bounded nonblocking no-follow descriptor-validated read.

Usage: safeRead.py <path> <max_bytes>
- Opens with O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC
- fstat validates S_ISREG, size <= max_bytes
- Bounded read(limit+1) rejects oversize / NUL bytes
- Writes content to stdout, exits 0 on success, 1 on refusal.
"""
import os
import sys
import stat

def eprint(*a, **k):
    print(*a, file=sys.stderr, **k)

def main():
    if len(sys.argv) != 3:
        eprint(f"usage: {sys.argv[0]} <path> <max_bytes>")
        sys.exit(2)
    path = sys.argv[1]
    try:
        limit = int(sys.argv[2])
    except ValueError:
        eprint("max_bytes must be integer")
        sys.exit(2)
    if limit <= 0 or limit > 10 * 1024 * 1024:
        eprint("max_bytes out of sane range")
        sys.exit(2)
    # Refuse empty or overly long path
    if not path or len(path) > 4096:
        sys.exit(1)
    # Extra lstat check: reject symlink parent traversal is handled by O_NOFOLLOW,
    # but also refuse if the path itself is a symlink (lstat)
    try:
        lst = os.lstat(path)
        if stat.S_ISLNK(lst.st_mode):
            sys.exit(1)
    except FileNotFoundError:
        sys.exit(1)
    except OSError:
        sys.exit(1)

    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = None
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        sys.exit(1)
    except OSError:
        sys.exit(1)

    try:
        st = os.fstat(fd)
        # Must be regular file
        if not stat.S_ISREG(st.st_mode):
            sys.exit(1)
        # Size check via fstat (if size known)
        if st.st_size > limit:
            sys.exit(1)
        # Non-blocking FIFO would have been opened; check again
        # Bounded read: limit+1 to detect oversize
        data = b""
        remaining = limit + 1
        # Use single read; for pipes/files this is sufficient, loop for robustness
        while remaining > 0:
            chunk = os.read(fd, remaining)
            if not chunk:
                break
            data += chunk
            remaining -= len(chunk)
            if len(data) > limit:
                sys.exit(1)
            # If we got less than requested, EOF
            if len(chunk) < remaining + (len(data) - limit - 1):
                # continue until EOF or limit exceeded; break if short read and size known
                if len(chunk) == 0:
                    break
                # for regular files, one read suffices; avoid busy loop
                if stat.S_ISREG(st.st_mode):
                    break
        if len(data) > limit:
            sys.exit(1)
        if b"\x00" in data:
            sys.exit(1)
        # Validate UTF-8 (FileView text() is UTF-8), strip UTF-8 BOM if present
        try:
            text = data.decode("utf-8-sig")
            data = text.encode("utf-8")
        except UnicodeDecodeError:
            sys.exit(1)
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        sys.exit(0)
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass

if __name__ == "__main__":
    main()
