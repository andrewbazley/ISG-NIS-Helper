"""
ISG-NIS-Helper watcher -- the enforcement half.

Runs as SYSTEM from Task Scheduler at boot, with "restart on failure"
enabled. It has no user interface (a SYSTEM process cannot draw on the
user's desktop), so its only jobs are:

  1. Notice when NIS-Elements is launched while no session is open.
  2. Give the person a generous grace period to sign in.
  3. If nobody signs in, close NIS-Elements and record that it happened.
  4. Record its own start, stop and heartbeat, so a gap in the record is
     itself visible.

What it never does:

  * It never touches NIS-Elements while a session is open. A signed-in
    session is untouchable, including an overnight acquisition that runs
    for three days.
  * It never reads, moves or modifies microscope data.
  * It never acts on a guess. If the process list cannot be trusted, if
    its own state directory will not read and write, if the configured
    NIS executable has vanished, if the sign-in program is dead, or if
    Windows has just updated, it declines to close anything and says so
    in the log. See isg_health.py.

If the agent is not running, this process still enforces and still logs;
the user simply gets no sign-in window, which is recorded as such.
"""

import os
import sys
import time

from isg_common import (
    VERSION, Config, ConfigError, ensure_dir, handoff_active,
    iso_local, log_event, parse_local, now_local, read_json, unauth_path,
    write_json,
)
import isg_health as health_mod
import isg_proc as proc

HEARTBEAT_EVERY = 600      # seconds between "still alive" log lines
AGENT_SILENCE_WARN = 300   # seconds of no agent heartbeat before we note it


def _clear_unauth(cfg):
    try:
        p = unauth_path(cfg)
        if os.path.isfile(p):
            os.remove(p)
    except Exception:
        pass


def main():
    try:
        cfg = Config()
    except ConfigError:
        return 2

    ensure_dir(cfg.local_root)
    log_event(cfg, "watch_started", version=VERSION, pid=os.getpid(),
              grace_seconds=cfg.launch_grace_seconds)

    health = health_mod.read_health(cfg)
    health = health_mod.note_os_build(cfg, health)
    ok, checks = health_mod.run_checks(cfg)
    log_event(cfg, "watch_self_check", passed=ok, checks=checks)
    health_mod.summarise(cfg, health, checks)
    if health_mod.in_safe_mode(cfg):
        log_event(cfg, "watch_started_in_safe_mode",
                  reason=health_mod.safe_mode_info(cfg).get("reason", ""))

    last_heartbeat = 0.0
    warned_agent_silent = False
    unknown_streak = 0
    unauth_streak = 0
    last_block_reason = None

    while True:
        try:
            now = time.time()
            if now - last_heartbeat >= HEARTBEAT_EVERY:
                last_heartbeat = now
                ok, checks = health_mod.run_checks(cfg)
                log_event(cfg, "watch_heartbeat", healthy=ok)
                health_mod.summarise(cfg, health, checks)

            running = proc.find_matching(cfg.gated_process_names)

            # None means the process list could not be trusted. Never act on
            # a guess: hold the previous state and wait for a clean reading.
            if running is None:
                unknown_streak += 1
                if unknown_streak == cfg.confirm_polls:
                    log_event(cfg, "process_list_unreadable",
                              consecutive_polls=unknown_streak)
                if unknown_streak >= cfg.confirm_polls * 20:
                    health = health_mod.record_error(
                        cfg, health, "process list unreadable for a long period")
                    unknown_streak = 0
                time.sleep(cfg.poll_seconds)
                continue
            unknown_streak = 0

            session = read_json(cfg.session_file)
            has_session = bool(session and session.get("session_id"))

            # ---------- a session is open: hands off, completely ----------
            if has_session:
                _clear_unauth(cfg)
                last_seen = parse_local(session.get("last_seen_local", ""))
                if running and last_seen:
                    silent = (now_local() - last_seen).total_seconds()
                    if silent > AGENT_SILENCE_WARN and not warned_agent_silent:
                        warned_agent_silent = True
                        log_event(cfg, "agent_not_heartbeating",
                                  session_id=session.get("session_id"),
                                  seconds_silent=int(silent))
                    elif silent <= AGENT_SILENCE_WARN:
                        warned_agent_silent = False
                time.sleep(cfg.poll_seconds)
                continue

            # ---------- no session, NIS closed: nothing to do ----------
            if not running:
                _clear_unauth(cfg)
                unauth_streak = 0
                time.sleep(cfg.poll_seconds)
                continue

            # ---------- deliberate hand-over in progress ----------
            if handoff_active(cfg):
                unauth_streak = 0
                time.sleep(cfg.poll_seconds)
                continue

            # ---------- NIS is open and nobody has signed in ----------
            # Require the same answer several polls running before starting
            # the clock, so a single odd reading starts nothing.
            unauth_streak += 1
            if unauth_streak < cfg.confirm_polls:
                time.sleep(cfg.poll_seconds)
                continue

            info = read_json(unauth_path(cfg))
            if not info:
                info = {
                    "since_local": iso_local(),
                    "since_epoch": now,
                    "deadline_epoch": now + cfg.launch_grace_seconds,
                    "processes": [n for _, n in running],
                }
                write_json(unauth_path(cfg), info)
                log_event(cfg, "unauthorized_launch_detected",
                          processes=[n for _, n in running],
                          pids=[p for p, _ in running],
                          grace_seconds=cfg.launch_grace_seconds)

            if now >= float(info.get("deadline_epoch", now + 1)):
                # The one place ISG-NIS-Helper closes somebody's program. Every
                # precondition has to pass, right now, or it does not happen.
                allowed, why, checks = health_mod.may_enforce(cfg, health)
                if not allowed:
                    if why != last_block_reason:
                        last_block_reason = why
                        log_event(cfg, "enforcement_withheld", reason=why,
                                  processes=[n for _, n in running])
                    health_mod.summarise(cfg, health, checks)
                    _clear_unauth(cfg)
                    unauth_streak = 0
                    time.sleep(cfg.poll_seconds)
                    continue

                last_block_reason = None
                closed = []
                for pid, name in running:
                    if proc.terminate(pid):
                        closed.append({"pid": pid, "name": name})
                log_event(cfg, "unauthorized_launch_closed",
                          closed=closed,
                          waited_seconds=int(now - float(info.get("since_epoch", now))))
                health = health_mod.record_termination(cfg, health)
                health_mod.summarise(cfg, health)
                _clear_unauth(cfg)
                unauth_streak = 0

        except Exception as exc:
            try:
                log_event(cfg, "watch_error", error=str(exc))
                health = health_mod.record_error(cfg, health, str(exc))
            except Exception:
                pass

        time.sleep(max(1, cfg.poll_seconds))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
