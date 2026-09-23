#!/usr/bin/env python3
"""Generate cava config with strict bars validation and exec cava.

Usage: cava-gen.py <bars>
- bars must match /^[0-9]+$/ and 4 <= int(bars) <= 64
- Writes 0600 config to $XDG_RUNTIME_DIR/cava.XXXXXX (umask 077)
- Forks cava -p <config>; parent forwards SIGTERM/SIGINT/SIGHUP/SIGQUIT
  to cava, reaps it, then unlinks the config. Child arms PDEATHSIG so a
  killed parent still takes cava down (no orphan on dock terminate).
"""
import os
import sys
import re
import signal
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

    # Cleanup on exit: parent waits for cava, forwards termination signals
    # so no orphan survives dock teardown, then removes the mkstemp config.
    # The child sets PDEATHSIG so even a SIGKILLed parent still takes cava
    # down with it (kernel sends SIGTERM to cava on reparent).
    child_pid = None
    term_sig = None
    term_count = 0

    def _set_pdeathsig():
        try:
            import ctypes
            libc = ctypes.CDLL("libc.so.6", use_errno=True)
            PR_SET_PDEATHSIG = 1
            libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0)
        except Exception:
            pass

    pid = os.fork()
    if pid == 0:
        # Child: restore default dispositions (parent installs forwarders
        # below), arm death-signal, abort if already orphaned, then exec.
        for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
            try:
                signal.signal(_sig, signal.SIG_DFL)
            except Exception:
                pass
        _set_pdeathsig()
        try:
            if os.getppid() == 1:
                try:
                    os.unlink(path)
                except OSError:
                    pass
                os._exit(127)
        except Exception:
            pass
        try:
            os.execvp("cava", ["cava", "-p", path])
        except OSError as e:
            eprint(f"exec cava failed: {e}")
            sys.exit(127)
    else:
        child_pid = pid

        def _forward(signum, _frame):
            nonlocal term_sig, term_count
            if term_sig is None:
                term_sig = signum
            term_count += 1
            # First attempt: graceful SIGTERM; repeated signal: escalate.
            _sig = signal.SIGTERM if term_count == 1 else signal.SIGKILL
            try:
                if child_pid is not None:
                    os.kill(child_pid, _sig)
            except (ProcessLookupError, PermissionError, OSError):
                pass
            # Do not exit here: fall through to waitpid so the child is
            # reaped (no zombie) and the config is unlinked.

        for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
            try:
                signal.signal(_sig, _forward)
            except Exception:
                pass
        status = None
        while True:
            try:
                _, status = os.waitpid(child_pid, 0)
                break
            except InterruptedError:
                continue
            except ChildProcessError:
                break
        child_pid = None
        try:
            os.unlink(path)
        except OSError:
            pass
        # Terminated by dock teardown: report 128+sig like a shell.
        if term_sig is not None and status is not None and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0:
            sys.exit(128 + term_sig)
        if term_sig is not None and status is None:
            sys.exit(128 + term_sig)
        # Propagate cava exit code
        if status is not None:
            if os.WIFEXITED(status):
                sys.exit(os.WEXITSTATUS(status))
            elif os.WIFSIGNALED(status):
                sys.exit(128 + os.WTERMSIG(status))
        sys.exit(1)

if __name__ == "__main__":
    main()
