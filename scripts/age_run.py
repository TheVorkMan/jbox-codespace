#!/usr/bin/env python3
"""age_run.py - run `age` non-interactively: passphrase via pty, data via pipes.

age refuses to read the passphrase from stdin or an env var - it insists on
/dev/tty. This wrapper forks age with a pty as its controlling terminal and
writes the passphrase into the pty input buffer right away (it waits there
until age's passphrase prompt reads it). Data stays on REAL pipes: piping the
decrypted payload through a pty would corrupt it (ONLCR on binary output).

A copy of the pty slave is kept on fd 9 in the child, otherwise replacing
stdio with the pipes would close the last slave fd and hang the pty up -
age would then block forever on open("/dev/tty").

Usage:
    cat part00 part01 | AGE_PASS='secret' python3 age_run.py -d | zstd -dc | tar -xf -
"""
import os
import pty
import select
import sys
import termios


def main() -> int:
    args = sys.argv[1:]
    pw = os.environ.get("AGE_PASS", "")
    if not pw:
        sys.stderr.write("age_run: AGE_PASS is not set\n")
        return 2

    # Real stdio preserved across pty.fork().
    r0, w1, w2 = os.dup(0), os.dup(1), os.dup(2)
    pid, master = pty.fork()
    if pid == 0:
        # Keep a slave reference (fd 9) so the pty does not hang up when
        # stdio is replaced by the pipes below.
        os.dup2(0, 9)
        os.dup2(r0, 0)
        os.dup2(w1, 1)
        os.dup2(w2, 2)
        os.execvp("age", ["age"] + args)
        os._exit(127)

    os.close(r0)
    os.close(w1)
    os.close(w2)

    # No echo on the pty line discipline, so the passphrase never surfaces
    # in the relayed output.
    try:
        attrs = termios.tcgetattr(master)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(master, termios.TCSANOW, attrs)
    except termios.error:
        pass

    # Passphrase sits in the pty buffer until age's prompt reads it.
    os.write(master, pw.encode() + b"\n")

    status = None
    while True:
        try:
            r, _, _ = select.select([master], [], [], 1.0)
        except InterruptedError:
            continue
        if r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break  # EIO: slave side closed (age exited)
            if not chunk:
                break
            # Whatever age printed to /dev/tty (prompts, errors) -> stderr.
            os.write(2, chunk)
        else:
            done, st = os.waitpid(pid, os.WNOHANG)
            if done:
                status = st
                break

    if status is None:
        try:
            _, status = os.waitpid(pid, 0)
        except ChildProcessError:
            status = 1
    try:
        os.close(master)
    except OSError:
        pass
    code = os.waitstatus_to_exitcode(status) if status is not None else 1
    if code != 0:
        sys.stderr.write(f"age_run: age exited with code {code}\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
