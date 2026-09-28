"""
ISG-NIS-Helper -- process enumeration.

Uses psutil when it is installed, otherwise shells out to the built-in
Windows `tasklist`.

The important thing this module does is refuse to guess. An earlier
version returned an empty list when enumeration failed, which is
indistinguishable from "nothing is running" -- so a momentary failure
would make the agent conclude NIS-Elements had closed, end the session,
and leave the watcher looking at a running NIS with no session open,
which it would then terminate. A broken process list could therefore
kill a live overnight acquisition.

Now a failed or implausible enumeration returns None, meaning "unknown",
and every caller is required to treat unknown as "do nothing".
"""

import subprocess
import sys

try:
    import psutil
    HAVE_PSUTIL = True
except Exception:
    psutil = None
    HAVE_PSUTIL = False

_NO_WINDOW = 0x08000000 if sys.platform == "win32" else 0


# Processes that exist on any running Windows session. If none of these
# come back, we are not looking at a real process list, however many rows
# the call returned.
SENTINELS_WINDOWS = frozenset([
    "csrss.exe", "winlogon.exe", "services.exe", "lsass.exe",
    "svchost.exe", "wininit.exe", "smss.exe", "explorer.exe",
])
SENTINELS_POSIX = frozenset(["systemd", "init", "bash", "sh", "python3", "pwsh"])
MIN_PLAUSIBLE_PROCESSES = 10


def _sentinels():
    return SENTINELS_WINDOWS if sys.platform == "win32" else SENTINELS_POSIX


def enumeration_is_plausible(procs):
    """Does this look like a real process list, or like a broken call?"""
    if procs is None:
        return False
    if len(procs) < MIN_PLAUSIBLE_PROCESSES:
        return False
    names = set(nm for _, nm in procs)
    return len(names & _sentinels()) > 0


def list_processes():
    """
    Return [(pid, lowercase_exe_name), ...], or None if the process list
    could not be read or does not look real. Never raises.
    """
    out = None
    if HAVE_PSUTIL:
        try:
            out = []
            for p in psutil.process_iter(["pid", "name"]):
                try:
                    nm = (p.info.get("name") or "").lower()
                    if nm:
                        out.append((p.info["pid"], nm))
                except Exception:
                    continue
        except Exception:
            out = None
        return out if enumeration_is_plausible(out) else None

    try:
        raw = subprocess.check_output(
            ["tasklist", "/FO", "CSV", "/NH"],
            creationflags=_NO_WINDOW, stderr=subprocess.DEVNULL)
        text = raw.decode("utf-8", "replace")
    except Exception:
        return None

    out = []
    for line in text.splitlines():
        parts = [c.strip('"') for c in line.split('","')]
        if len(parts) < 2:
            continue
        name = parts[0].lstrip('"').lower()
        try:
            pid = int(parts[1])
        except Exception:
            continue
        out.append((pid, name))
    return out if enumeration_is_plausible(out) else None


def find_matching(process_names):
    """
    Return [(pid, name), ...] for any running process in process_names,
    or None if the process list could not be trusted.
    """
    procs = list_processes()
    if procs is None:
        return None
    wanted = set(n.lower() for n in process_names)
    return [(pid, nm) for pid, nm in procs if nm in wanted]


def is_running(process_names):
    """True, False, or None for 'could not tell'. Callers must handle None."""
    found = find_matching(process_names)
    if found is None:
        return None
    return len(found) > 0


def terminate(pid, force_after=10):
    """
    Ask a process to close, then force it only if it refuses.

    This is used in exactly one situation: NIS was launched directly and
    nobody signed in within the grace period. It is never called against
    a process belonging to an open session.
    """
    if HAVE_PSUTIL:
        try:
            p = psutil.Process(pid)
            p.terminate()
            try:
                p.wait(timeout=force_after)
                return True
            except Exception:
                p.kill()
                return True
        except Exception:
            return False
    try:
        subprocess.call(["taskkill", "/PID", str(pid), "/T", "/F"],
                        creationflags=_NO_WINDOW,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False
