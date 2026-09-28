"""
ISG-NIS-Helper -- failsafe.

The two halves of ISG-NIS-Helper fail very differently, and the design follows
from that asymmetry:

  * If the LOGGER breaks, records are lost. Annoying, recoverable.
  * If the ENFORCER breaks, it may close NIS-Elements when it should not
    -- possibly overnight, possibly mid-acquisition. Unrecoverable.

So the watcher's power to terminate a process is treated as a privilege it
must continuously earn. Before it may close anything, it has to positively
demonstrate that it is healthy. If it cannot -- for any reason, including
reasons nobody anticipated -- it drops enforcement and keeps logging.
Losing a deterrent for a day is cheap; losing an experiment is not.

Four mechanisms:

  1. PRECONDITIONS. Every termination is gated on live checks: the process
     list is trustworthy, ISG-NIS-Helper's own state directory reads and writes,
     the configured NIS executable still exists, and the sign-in agent is
     alive (if nobody can sign in, closing NIS only makes the scope
     unusable).

  2. CONFIRMATION. Nothing acts on a single observation. A state has to
     hold for several consecutive polls, so one bad reading changes
     nothing.

  3. POST-UPDATE PAUSE. The Windows build number is recorded. When it
     changes, enforcement pauses for a grace period while logging
     continues, because the hours after an update are when odd behaviour
     shows up.

  4. CIRCUIT BREAKER. Repeated terminations or a burst of internal errors
     trip safe mode: enforcement off, logging on, a marker file written
     and a human told. Three kills in an hour is far more likely to be
     ISG-NIS-Helper malfunctioning than three people abusing the scope.

Safe mode is not the manual kill switch we deliberately left out. It
cannot stop the recording, only the closing. A human clears it.
"""

import os
import platform
import time

from isg_common import (
    agent_beacon_age, ensure_dir, iso_local, log_event, now_local,
    parse_local, read_json, write_json,
)
import isg_proc as proc


# --------------------------------------------------------------------------
# state files
# --------------------------------------------------------------------------

def health_path(cfg):
    return os.path.join(cfg.local_root, "health.json")


def safemode_path(cfg):
    return os.path.join(cfg.local_root, "SAFEMODE.json")


def read_health(cfg):
    return read_json(health_path(cfg), {}) or {}


def write_health(cfg, data):
    try:
        write_json(health_path(cfg), data)
    except Exception:
        pass


# --------------------------------------------------------------------------
# safe mode
# --------------------------------------------------------------------------

def in_safe_mode(cfg):
    return os.path.isfile(safemode_path(cfg))


def safe_mode_info(cfg):
    return read_json(safemode_path(cfg), {}) or {}


def enter_safe_mode(cfg, reason, detail=""):
    """Stop enforcing. Keep logging. Say so, loudly and permanently."""
    if in_safe_mode(cfg):
        return False
    payload = {
        "reason": reason,
        "detail": detail,
        "since_local": iso_local(),
        "computer": cfg.computer_id,
        "note": ("ISG-NIS-Helper is still recording every session. It will not close "
                 "NIS-Elements until someone deletes this file."),
    }
    try:
        write_json(safemode_path(cfg), payload)
    except Exception:
        pass
    log_event(cfg, "safe_mode_entered", reason=reason, detail=detail)
    return True


def clear_safe_mode(cfg):
    try:
        if os.path.isfile(safemode_path(cfg)):
            os.remove(safemode_path(cfg))
            log_event(cfg, "safe_mode_cleared")
            return True
    except Exception:
        pass
    return False


# --------------------------------------------------------------------------
# preconditions
# --------------------------------------------------------------------------

def check_state_store(cfg):
    """Can ISG-NIS-Helper read and write its own state directory?"""
    try:
        ensure_dir(cfg.local_root)
        probe = os.path.join(cfg.local_root, ".healthprobe")
        with open(probe, "w", encoding="utf-8") as fh:
            fh.write(iso_local())
        with open(probe, "r", encoding="utf-8") as fh:
            fh.read()
        os.remove(probe)
        return True, ""
    except Exception as exc:
        return False, str(exc)


def check_nis_executable(cfg):
    """If the configured program has vanished, something large changed."""
    path = cfg.nis_executable
    if not path:
        return False, "nis_executable is not set"
    if not os.path.isfile(path):
        return False, "not found: %s" % path
    return True, ""


def check_agent_alive(cfg, max_silence_seconds):
    """
    Is the sign-in program running? Enforcing with a dead agent means
    nobody can sign in and NIS gets closed regardless -- a locked
    instrument, which is worse than an unlogged one.
    """
    # Primary: the agent's own beacon file. Independent of what the
    # executable is called, so renaming it cannot disable the failsafe.
    age = agent_beacon_age(cfg)
    if age is not None and age <= max_silence_seconds:
        return True, ""

    # Secondary: a session heartbeat.
    session = read_json(cfg.session_file)
    if session and session.get("session_id"):
        seen = parse_local(session.get("last_seen_local", ""))
        if seen and (now_local() - seen).total_seconds() <= max_silence_seconds:
            return True, ""

    # Last resort: is a process by that name running at all?
    running = proc.is_running(["isg-nis-helper-agent.exe"])
    if running:
        return True, ""
    if running is None and age is None:
        return False, "could not read the process list and no agent beacon"
    if age is None:
        return False, "the sign-in program has never checked in"
    return False, "the sign-in program last checked in %d seconds ago" % int(age)


def check_processes(cfg):
    procs = proc.list_processes()
    if procs is None:
        return False, "process list unreadable or implausible"
    return True, ""


def run_checks(cfg):
    """All preconditions. Returns (ok, {name: 'ok' | reason})."""
    results = {}
    ok_all = True
    for name, fn in (
        ("process_enumeration", lambda: check_processes(cfg)),
        ("state_store",         lambda: check_state_store(cfg)),
        ("nis_executable",      lambda: check_nis_executable(cfg)),
    ):
        ok, why = fn()
        results[name] = "ok" if ok else why
        ok_all = ok_all and ok

    if cfg.require_agent:
        ok, why = check_agent_alive(cfg, cfg.agent_silence_seconds)
        results["agent_alive"] = "ok" if ok else why
        ok_all = ok_all and ok
    else:
        results["agent_alive"] = "not required"

    return ok_all, results


# --------------------------------------------------------------------------
# Windows build tracking
# --------------------------------------------------------------------------

def current_os_build():
    try:
        return "%s|%s" % (platform.system(), platform.version())
    except Exception:
        return "unknown"


def note_os_build(cfg, health):
    """
    Detect an OS update and pause enforcement for a grace period. Logging
    is untouched. This is the direct answer to "a Windows update broke it":
    the window in which that shows up is exactly the window in which we
    decline to close anything.
    """
    build = current_os_build()
    previous = health.get("os_build")
    health["os_build"] = build

    if previous and previous != build:
        hours = max(0, cfg.post_update_grace_hours)
        until = time.time() + hours * 3600.0
        health["os_build_changed_at"] = iso_local()
        health["enforcement_paused_until_epoch"] = until if hours else None
        log_event(cfg, "os_build_changed", previous=previous, current=build,
                  enforcement_paused_hours=hours)
        ok, results = run_checks(cfg)
        log_event(cfg, "post_update_self_check", passed=ok, checks=results)
        if not ok:
            enter_safe_mode(cfg, "self-check failed after an OS update",
                            "; ".join("%s: %s" % (k, v)
                                      for k, v in results.items() if v != "ok"))
    return health


def enforcement_paused(cfg, health):
    until = health.get("enforcement_paused_until_epoch")
    if not until:
        return False, 0
    remaining = float(until) - time.time()
    if remaining <= 0:
        return False, 0
    return True, int(remaining)


# --------------------------------------------------------------------------
# circuit breaker
# --------------------------------------------------------------------------

def _prune(stamps, window_seconds):
    cutoff = time.time() - window_seconds
    return [t for t in stamps if t >= cutoff]


def record_termination(cfg, health):
    stamps = _prune(health.get("terminations", []), 3600)
    stamps.append(time.time())
    health["terminations"] = stamps
    if len(stamps) >= cfg.max_terminations_per_hour:
        enter_safe_mode(
            cfg, "too many terminations",
            "%d in the last hour; the limit is %d. Three closures in an hour is "
            "more likely to be ISG-NIS-Helper misbehaving than three people abusing "
            "the instrument." % (len(stamps), cfg.max_terminations_per_hour))
    return health


def record_error(cfg, health, detail=""):
    stamps = _prune(health.get("errors", []), 600)
    stamps.append(time.time())
    health["errors"] = stamps
    if len(stamps) >= cfg.max_errors_per_10min:
        enter_safe_mode(cfg, "repeated internal errors",
                        "%d errors in ten minutes. Last: %s" % (len(stamps), detail))
    return health


# --------------------------------------------------------------------------
# the one question the watcher asks
# --------------------------------------------------------------------------

def may_enforce(cfg, health):
    """
    May the watcher close NIS-Elements right now?
    Returns (allowed, reason_if_not, checks).
    """
    if in_safe_mode(cfg):
        info = safe_mode_info(cfg)
        return False, "safe mode: %s" % info.get("reason", "unknown"), {}

    paused, remaining = enforcement_paused(cfg, health)
    if paused:
        return False, ("paused after an OS update, %d minutes remaining"
                       % (remaining // 60)), {}

    ok, results = run_checks(cfg)
    if not ok:
        failed = "; ".join("%s: %s" % (k, v) for k, v in results.items() if v != "ok")
        return False, "health check failed -- %s" % failed, results

    return True, "", results


def summarise(cfg, health, checks=None, extra=None):
    """Write health.json: the file a human reads when something looks odd."""
    paused, remaining = enforcement_paused(cfg, health)
    data = dict(health)
    data.update({
        "updated_local": iso_local(),
        "computer": cfg.computer_id,
        "computer_label": cfg.computer_label,
        "safe_mode": in_safe_mode(cfg),
        "safe_mode_reason": safe_mode_info(cfg).get("reason", ""),
        "enforcement_paused": paused,
        "enforcement_pause_minutes_left": remaining // 60 if paused else 0,
        "terminations_last_hour": len(_prune(health.get("terminations", []), 3600)),
        "errors_last_10min": len(_prune(health.get("errors", []), 600)),
    })
    if checks:
        data["last_checks"] = checks
    if extra:
        data.update(extra)
    write_health(cfg, data)
    return data
