#!/usr/bin/env python3
"""Generate cava config with strict bars validation and exec cava.

Usage: cava-gen.py <bars>
- bars must match /^[0-9]+$/ and 4 <= int(bars) <= 64
- Writes 0600 config to $XDG_RUNTIME_DIR/cava.XXXXXX (umask 077)
- Execs cava -p <config> (replaces process, EXIT trap cleans up via parent wrapper).
  If called directly, this script does the mkstemp+exec.

The QML side should pass validatedVisualizerBars as argv[1] (data, not shell source).
"""
import os
import sys
import re
import tempfile
import stat

def eprint(*a, **k):
    print(*a, file=sys.stderr, **k)

BARS_RE = re.compile(r"^[0-9]+$")

def main():
    if len(sys.argv) != 2:
        eprint(f"usage: {sys.argv[0]} <bars>")
        sys.exit(2)
    raw = sys.argv[1]
    # Strict: fullmatch + no newline/space tricks ( $ matches before \n, so use fullmatch/isdigit )
    if BARS_RE.fullmatch(raw) is None:
        eprint("bars must be integer")
        sys.exit(2)
    if not raw.isdigit():
        eprint("bars must be integer")
        sys.exit(2)
    try:
        n = int(raw, 10)
    except ValueError:
        sys.exit(2)
    if n < 4 or n > 64:
        eprint("bars out of range 4..64")
        sys.exit(2)
    bars = str(n)

    # Secure temp dir: XDG_RUNTIME_DIR or TMPDIR with 0700
    runtime = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    # Validate runtime dir is not a symlink and is owned (best effort)
    try:
        lst = os.lstat(runtime)
        if stat.S_ISLNK(lst.st_mode):
            runtime = "/tmp"
        if not stat.S_ISDIR(lst.st_mode):
            runtime = "/tmp"
    except OSError:
        runtime = "/tmp"

    # Create config with umask 077, 0600
    old_umask = os.umask(0o077)
    fd = None
    path = None
    try:
        fd, path = tempfile.mkstemp(prefix="cava.", dir=runtime)
        os.fchmod(fd, 0o600)
        content = f"[general]\nbars = {bars}\n[output]\nmethod = raw\nraw_target = /dev/stdout\ndata_format = ascii\nascii_max_range = 100\n"
        # Encode and write bounded (config < 1KB)
        if len(content) > 2048:
            sys.exit(1)
        if "\x00" in content:
            sys.exit(1)
        os.write(fd, content.encode("utf-8"))
        os.fsync(fd)
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        os.umask(old_umask)

    if not path:
        sys.exit(1)

    # Cleanup on exit: register atexit via shell wrapper would be needed after exec.
    # Since we exec cava, we need to ensure cleanup after cava exits. Use try/finally around exec
    # by forking: parent waits and removes file. Simpler: exec via os.execvp and rely on
    # outer shell trap - but we are the wrapper, so fork.
    pid = os.fork()
    if pid == 0:
        # Child: exec cava
        try:
            os.execvp("cava", ["cava", "-p", path])
        except OSError as e:
            eprint(f"exec cava failed: {e}")
            sys.exit(127)
    else:
        # Parent: wait for cava, then remove config
        _, status = os.waitpid(pid, 0)
        try:
            os.unlink(path)
        except OSError:
            pass
        # Propagate cava exit code
        if os.WIFEXITED(status):
            sys.exit(os.WEXITSTATUS(status))
        elif os.WIFSIGNALED(status):
            sys.exit(128 + os.WTERMSIG(status))
        sys.exit(1)

if __name__ == "__main__":
    main()
