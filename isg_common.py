"""
ISG-NIS-Helper -- shared configuration, paths, user list and event logging.

Design rules this module exists to enforce:
  * Local disk is the source of truth. The network is a mirror.
  * ISG-NIS-Helper only ever READS the data roots (scandir + stat).
    It never opens, moves, copies, renames or deletes microscope data.
  * If the network is unreachable, everything keeps working from cache.
"""

import configparser
import csv
import json
import os
import re
import socket
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone

APP_NAME = "ISG-NIS-Helper"
VERSION = "3.0.4"
PLACEHOLDER_TOKEN = "<<<SET_ME"


# --------------------------------------------------------------------------
# paths
# --------------------------------------------------------------------------

def app_dir():
    """Folder holding the executable (frozen) or this source file."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def ensure_dir(path):
    if path and not os.path.isdir(path):
        os.makedirs(path, exist_ok=True)
    return path


# --------------------------------------------------------------------------
# time
# --------------------------------------------------------------------------

def now_local():
    return datetime.now()


def now_utc():
    return datetime.now(timezone.utc)


def iso_local(dt=None):
    return (dt or now_local()).strftime("%Y-%m-%dT%H:%M:%S")


def iso_utc(dt=None):
    return (dt or now_utc()).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_local(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S")
    except Exception:
        return None


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------

_SAFE = re.compile(r"[^A-Za-z0-9._-]+")


def sanitize(text, fallback="unknown"):
    out = _SAFE.sub("-", (text or "").strip()).strip("-")
    return out or fallback


def name_for_filename(full_name):
    """'Andrew Bazley' -> 'Bazley-Andrew' so files sort by surname."""
    parts = [p for p in (full_name or "").split() if p]
    if len(parts) >= 2:
        return sanitize(parts[-1] + "-" + " ".join(parts[:-1]).replace(" ", "-"))
    return sanitize(full_name)


def short_id():
    return uuid.uuid4().hex[:8]


def atomic_write_text(path, text):
    """Write via temp file + replace so a crash can never leave a half file."""
    ensure_dir(os.path.dirname(path))
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise


def write_json(path, obj):
    atomic_write_text(path, json.dumps(obj, indent=2, ensure_ascii=False))


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return default


# --------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------

class ConfigError(Exception):
    pass


def _split_list(raw, seps=";,"):
    if not raw:
        return []
    text = raw
    for s in seps[1:]:
        text = text.replace(s, seps[0])
    return [p.strip() for p in text.split(seps[0]) if p.strip()]


class Config(object):
    """Every per-computer string lives here, loaded from config.ini."""

    def __init__(self, path=None):
        self.path = path or os.path.join(app_dir(), "config.ini")
        # NOTE: inline comments are deliberately NOT enabled. ";" is the list
        # separator for data_roots, so treating it as a comment marker would
        # silently truncate "D:\A; D:\B" to "D:\A". Comments go on their own line.
        cp = configparser.ConfigParser()
        cp.optionxform = str
        if not os.path.isfile(self.path):
            raise ConfigError("config.ini not found next to the program: %s" % self.path)
        cp.read(self.path, encoding="utf-8-sig")
        self._cp = cp

        g = self._get
        self.computer_label = g("instrument", "computer_label", "")
        # Everything a user can see is titled with this, never "ISG-NIS-Helper".
        self.display_name = g("instrument", "display_name", "") or "Microscope Access Log"
        self.computer_id = g("instrument", "computer_id", "") or socket.gethostname()

        self.nis_executable = g("paths", "nis_executable", "")
        # The approved user list lives with the program, one per machine.
        # Blank means "users.csv next to the executable".
        self.users_file = g("paths", "users_file", "") or os.path.join(app_dir(), "users.csv")
        self.data_roots = _split_list(g("paths", "data_roots", ""), ";")
        self.network_root = g("paths", "network_root", "")
        self.local_root = g("paths", "local_root", r"C:\ProgramData\ISG-NIS-Helper")

        self.nis_process_names = [p.lower() for p in _split_list(g("processes", "nis_process_names", ""))]
        self.gate_viewer = self._bool("processes", "gate_viewer", False)
        self.viewer_process_names = [p.lower() for p in _split_list(g("processes", "viewer_process_names", ""))]

        self.launch_grace_seconds = self._int("behavior", "launch_grace_seconds", 120)
        self.poll_seconds = self._int("behavior", "poll_seconds", 3)
        self.heartbeat_seconds = self._int("behavior", "heartbeat_seconds", 15)
        self.launcher_wait_seconds = self._int("behavior", "launcher_wait_seconds", 30)
        self.handoff_grace_seconds = self._int("behavior", "handoff_grace_seconds", 300)
        self.write_master_index = self._bool("behavior", "write_master_index", True)
        self.max_detail_rows = self._int("behavior", "max_detail_rows", 50000)
        self.fullscreen_signin = self._bool("behavior", "fullscreen_signin", False)
        self.badge_corner = (g("behavior", "badge_corner", "br") or "br").lower()

        self.exclude_dirs = set(d.lower() for d in _split_list(g("scan", "exclude_dirs", ""), ";"))
        self.include_extensions = set(
            ("." + e.lstrip(".").lower()) for e in _split_list(g("scan", "include_extensions", ""), ";")
        )
        self.follow_symlinks = self._bool("scan", "follow_symlinks", False)

        self.confirm_polls = self._int("failsafe", "confirm_polls", 3)
        self.post_update_grace_hours = self._int("failsafe", "post_update_grace_hours", 24)
        self.max_terminations_per_hour = self._int("failsafe", "max_terminations_per_hour", 3)
        self.max_errors_per_10min = self._int("failsafe", "max_errors_per_10min", 10)
        self.require_agent = self._bool("failsafe", "require_agent", True)
        self.agent_silence_seconds = self._int("failsafe", "agent_silence_seconds", 120)

        self.admin1_name = g("contacts", "admin1_name", "")
        self.admin1_email = g("contacts", "admin1_email", "")
        self.admin2_name = g("contacts", "admin2_name", "")
        self.admin2_email = g("contacts", "admin2_email", "")

        self.master_pin = g("access", "master_pin", "")

    # -- raw accessors ----------------------------------------------------
    def _get(self, section, key, default=""):
        try:
            return self._cp.get(section, key).strip()
        except Exception:
            return default

    def _int(self, section, key, default):
        try:
            return int(self._get(section, key, str(default)))
        except Exception:
            return default

    def _bool(self, section, key, default):
        v = self._get(section, key, "").lower()
        if v in ("true", "yes", "1", "on"):
            return True
        if v in ("false", "no", "0", "off"):
            return False
        return default

    # -- placeholder check ------------------------------------------------
    def unset_placeholders(self):
        """Return the list of config keys still holding <<<SET_ME ...>>>."""
        bad = []
        # network_root is deliberately NOT here: it is an optional mirror for
        # logs, not something ISG-NIS-Helper needs in order to run.
        checks = [
            ("instrument", "computer_label", self.computer_label),
            ("paths", "nis_executable", self.nis_executable),
            ("paths", "data_roots", "; ".join(self.data_roots)),
            ("access", "master_pin", self.master_pin),
        ]
        for section, key, value in checks:
            if value and PLACEHOLDER_TOKEN in value:
                bad.append("[%s] %s" % (section, key))
        return bad

    # -- derived local paths ---------------------------------------------
    @property
    def session_file(self):
        return os.path.join(self.local_root, "session.json")

    @property
    def manifest_dir(self):
        return ensure_dir(os.path.join(self.local_root, "manifests"))

    @property
    def pending_sync_dir(self):
        return ensure_dir(os.path.join(self.local_root, "pending_sync"))

    def local_log_dir(self, dt=None):
        dt = dt or now_local()
        return ensure_dir(os.path.join(
            self.local_root, "logs", sanitize(self.computer_id),
            "%04d" % dt.year, "%02d" % dt.month))

    def network_log_dir(self, dt=None):
        if not self.network_root or PLACEHOLDER_TOKEN in self.network_root:
            return None
        dt = dt or now_local()
        return os.path.join(self.network_root, "logs", sanitize(self.computer_id),
                            "%04d" % dt.year, "%02d" % dt.month)

    @property
    def rolling_events_dir(self):
        return ensure_dir(os.path.join(self.local_root, "logs",
                                       sanitize(self.computer_id), "events_rolling"))

    @property
    def gated_process_names(self):
        names = list(self.nis_process_names)
        if self.gate_viewer:
            names.extend(self.viewer_process_names)
        return names


# --------------------------------------------------------------------------
# events
# --------------------------------------------------------------------------

def log_event(cfg, kind, **fields):
    """
    Append one event to today's rolling file, and -- if a session is open --
    to that session's buffer, which is flushed into the session's own
    events file when the session closes.

    Never raises. Logging must not be able to interrupt microscope work.
    """
    record = {
        "ts_local": iso_local(),
        "ts_utc": iso_utc(),
        "computer": cfg.computer_id,
        "label": cfg.computer_label,
        "kind": kind,
        "app_version": VERSION,
    }
    record.update(fields)
    line = json.dumps(record, ensure_ascii=False) + "\n"

    try:
        day = now_local().strftime("%Y-%m-%d")
        with open(os.path.join(cfg.rolling_events_dir, day + ".jsonl"), "a",
                  encoding="utf-8") as fh:
            fh.write(line)
    except Exception:
        pass

    try:
        sess = read_json(cfg.session_file)
        if sess and sess.get("session_id"):
            buf = os.path.join(cfg.local_root, "buffers",
                               sess["session_id"] + ".jsonl")
            ensure_dir(os.path.dirname(buf))
            with open(buf, "a", encoding="utf-8") as fh:
                fh.write(line)
    except Exception:
        pass

    return record


# --------------------------------------------------------------------------
# user list
# --------------------------------------------------------------------------

USER_COLUMNS = ["name", "email", "pin", "active", "notes"]


def _read_users_csv(path):
    users = []
    with open(path, "r", encoding="utf-8-sig", newline="") as fh:
        for row in csv.DictReader(fh):
            low = dict((k.strip().lower(), (v or "").strip())
                       for k, v in row.items() if k)
            name = low.get("name", "")
            email = low.get("email", "")
            if not name and not email:
                continue
            active = low.get("active", "yes").lower()
            users.append({
                "name": name,
                "email": email,
                "pin": low.get("pin", ""),
                "active": active not in ("no", "false", "0", "inactive"),
                "notes": low.get("notes", ""),
            })
    return users


def load_users(cfg):
    """
    Read the approved user list from this machine's own users.csv.

    Each instrument keeps its own list, in the program folder. There is no
    network dependency and therefore no stale-cache failure mode: either the
    file is there and readable, or it is not and ISG-NIS-Helper says so.

    Returns (users, source) where source is 'local' or 'none'.
    """
    try:
        return _apply_pin_overrides(cfg, _read_users_csv(cfg.users_file)), "local"
    except Exception:
        return [], "none"


def _pin_override_paths(cfg, email):
    """
    Where a user's self-chosen PIN lives.

    Under local_root rather than beside users.csv, because the program folder
    may be read-only (C:\\Program Files) while local_root is granted Modify
    to the Users group at install time. It also keeps users.csv purely yours
    to edit -- ISG-NIS-Helper never writes to it.
    """
    stem = sanitize(email.lower(), "user") + ".txt"
    return os.path.join(cfg.local_root, "pins", stem)


def _apply_pin_overrides(cfg, users):
    """A user may replace the PIN you assigned. ISG-NIS-Helper never rewrites
    users.csv to do it -- the override is a separate small file."""
    for u in users:
        if not u["email"]:
            continue
        try:
            with open(_pin_override_paths(cfg, u["email"]), "r", encoding="utf-8") as fh:
                pin = fh.read().strip()
            if pin:
                u["pin"] = pin
                u["pin_changed"] = True
        except Exception:
            continue
    return users


def save_pin_override(cfg, email, pin):
    path = _pin_override_paths(cfg, email)
    try:
        ensure_dir(os.path.dirname(path))
        atomic_write_text(path, pin)
        return True, False
    except Exception:
        return False, False


# --------------------------------------------------------------------------
# small shared state files (read by both the agent and the watcher)
# --------------------------------------------------------------------------

def handoff_path(cfg):
    return os.path.join(cfg.local_root, "handoff.json")


def set_handoff(cfg, seconds):
    """Mark a deliberate hand-over so NIS staying open between two sessions
    is not mistaken for an unauthorized launch."""
    try:
        write_json(handoff_path(cfg), {
            "until_epoch": time.time() + max(0, int(seconds)),
            "until_local": iso_local(),
        })
    except Exception:
        pass


def handoff_active(cfg):
    data = read_json(handoff_path(cfg))
    if not data:
        return False
    try:
        return time.time() < float(data.get("until_epoch", 0))
    except Exception:
        return False


def clear_handoff(cfg):
    try:
        p = handoff_path(cfg)
        if os.path.isfile(p):
            os.remove(p)
    except Exception:
        pass


def unauth_path(cfg):
    return os.path.join(cfg.local_root, "unauth.json")


# --------------------------------------------------------------------------
# agent beacon
# --------------------------------------------------------------------------

def agent_beacon_path(cfg):
    return os.path.join(cfg.local_root, "agent.json")


def touch_agent_beacon(cfg):
    """The agent says 'I am alive' here, in or out of a session.

    The watcher used to look for a process called isg-nis-helper-agent.exe. A
    file beacon is both more robust and independent of what the executable
    is named, so renaming it cannot silently disable the failsafe."""
    try:
        write_json(agent_beacon_path(cfg), {
            "pid": os.getpid(),
            "at_local": iso_local(),
            "at_epoch": time.time(),
        })
    except Exception:
        pass


def agent_beacon_age(cfg):
    """Seconds since the agent last checked in, or None if it never has."""
    data = read_json(agent_beacon_path(cfg))
    if not data:
        return None
    try:
        return max(0.0, time.time() - float(data.get("at_epoch", 0)))
    except Exception:
        return None


def agent_beacon_pid(cfg):
    """PID recorded in the beacon, or None."""
    data = read_json(agent_beacon_path(cfg))
    if not data:
        return None
    try:
        return int(data.get("pid") or 0) or None
    except Exception:
        return None


def pid_running(pid):
    """True if a process with this PID currently exists.

    Used only to avoid running two resident agents at once. Best effort:
    on any doubt it returns False, because the cost of a false 'no' is one
    extra agent that its own single-instance check will retire, while a
    false 'yes' could leave the instrument with no sign-in window."""
    if not pid:
        return False
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    try:
        if os.name == "nt":
            import ctypes
            PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
            k = ctypes.windll.kernel32
            h = k.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
            if h:
                k.CloseHandle(h)
                return True
            # 5 == ERROR_ACCESS_DENIED: the process exists, we just can't open it.
            return k.GetLastError() == 5
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def agent_is_alive(cfg, fresh_seconds=None):
    """True if a resident agent has checked in recently and its PID is live."""
    age = agent_beacon_age(cfg)
    if age is None:
        return False
    if fresh_seconds is not None and age > fresh_seconds:
        return False
    pid = agent_beacon_pid(cfg)
    if pid is None:
        # No PID recorded but a fresh beacon: trust the beacon.
        return True
    if pid == os.getpid():
        return False
    return pid_running(pid)


# --------------------------------------------------------------------------
# launch request  (the desktop shortcut asks the resident agent to open the
# sign-in window; the agent, not the shortcut, launches NIS after sign-in)
# --------------------------------------------------------------------------

def launch_request_path(cfg):
    return os.path.join(cfg.local_root, "launch_request.json")


def write_launch_request(cfg, requested_by=""):
    try:
        write_json(launch_request_path(cfg), {
            "requested_by": requested_by,
            "at_local": iso_local(),
            "at_epoch": time.time(),
        })
        return True
    except Exception:
        return False


def read_launch_request(cfg, max_age_seconds=120):
    """Return the pending request if it is fresh, else None."""
    data = read_json(launch_request_path(cfg))
    if not data:
        return None
    try:
        if time.time() - float(data.get("at_epoch", 0)) > max_age_seconds:
            return None
    except Exception:
        return None
    return data


def clear_launch_request(cfg):
    try:
        p = launch_request_path(cfg)
        if os.path.isfile(p):
            os.remove(p)
    except Exception:
        pass
