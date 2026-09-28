"""
ISG-NIS-Helper -- session lifecycle and log writing.

One session == one continuous period of NIS-Elements use by one signed-in
person. A session opens when someone signs in and ends when NIS-Elements
closes (or the user hands over via "switch user"). There is no timeout and
no concept of a stale session: if NIS is open, the session is open.

Every session produces three files, named so they sort usefully and can
never overwrite one another:

    2026-09-21_1432_Bazley-Andrew_074m_a1b2c3d4.csv          one row: the session
    2026-09-21_1432_Bazley-Andrew_074m_a1b2c3d4_events.jsonl detailed forensics
    2026-09-21_1432_Bazley-Andrew_074m_a1b2c3d4_files.csv    files changed

They are written to the local disk first -- always -- then mirrored to the
network share. If the share is unreachable the copies queue and flush later.
"""

import csv
import os
import shutil
import threading
import time

from isg_common import (
    VERSION, atomic_write_text, ensure_dir, iso_local, iso_utc, log_event,
    name_for_filename, now_local, parse_local, read_json, sanitize, short_id,
    write_json,
)
import isg_scan as scan


SESSION_COLUMNS = [
    "session_id", "computer", "computer_label",
    "user_name", "user_email",
    "start_local", "start_utc", "end_local", "end_utc", "duration_min",
    "end_reason", "launch_mode", "nis_exe",
    "master_pin_used", "declared_operator",
    "files_at_start", "files_at_end",
    "files_new", "files_modified", "files_deleted", "bytes_added",
    "detail_truncated", "detail_file",
    "user_list_source", "app_version", "notes",
]


# --------------------------------------------------------------------------
# start
# --------------------------------------------------------------------------

def start_session(cfg, user, launch_mode="helper", master_pin_used=False,
                  declared_operator="", user_list_source="", nis_exe=""):
    """Open a session, persist it, and kick off the baseline snapshot."""
    sid = short_id()
    started = now_local()

    session = {
        "session_id": sid,
        "computer": cfg.computer_id,
        "computer_label": cfg.computer_label,
        "user_name": user.get("name", ""),
        "user_email": user.get("email", ""),
        "start_local": iso_local(started),
        "start_utc": iso_utc(),
        "launch_mode": launch_mode,
        "nis_exe": nis_exe,
        "master_pin_used": bool(master_pin_used),
        "declared_operator": declared_operator or "",
        "user_list_source": user_list_source,
        "manifest_start": os.path.join(cfg.manifest_dir, sid + "_start.csv.gz"),
        "manifest_ready": False,
        "files_at_start": 0,
        "last_seen_local": iso_local(started),
        "handoff_pending_until": None,
        "app_version": VERSION,
    }
    write_json(cfg.session_file, session)

    log_event(cfg, "session_start",
              session_id=sid,
              user_name=session["user_name"],
              user_email=session["user_email"],
              launch_mode=launch_mode,
              master_pin_used=bool(master_pin_used),
              declared_operator=declared_operator or "",
              user_list_source=user_list_source)

    # Baseline snapshot runs in the background so nobody waits on it -- but
    # it must be stoppable. Walking three data drives can take a while, and a
    # session that ends quickly used to leave that walk running, writing to a
    # session that no longer exists.
    _BASELINE["stop"] = threading.Event()
    _BASELINE["sid"] = sid
    _BASELINE["thread"] = threading.Thread(
        target=_baseline_worker, args=(cfg, sid, _BASELINE["stop"]), daemon=True)
    _BASELINE["thread"].start()
    return session


_BASELINE = {"sid": None, "stop": None, "thread": None}


def stop_baseline(timeout=5.0):
    """Ask the background snapshot to stop, and wait briefly for it."""
    ev = _BASELINE.get("stop")
    th = _BASELINE.get("thread")
    if ev is not None:
        ev.set()
    if th is not None and th.is_alive():
        th.join(timeout)
    _BASELINE["sid"] = None


def _baseline_worker(cfg, sid, stop_flag=None):
    try:
        session = read_json(cfg.session_file) or {}
        if session.get("session_id") != sid:
            return
        path = session["manifest_start"]
        count = scan.snapshot(cfg, path, stop_flag=stop_flag)
        if stop_flag is not None and stop_flag.is_set():
            log_event(cfg, "baseline_snapshot_stopped", session_id=sid)
            return
        session = read_json(cfg.session_file) or {}
        if session.get("session_id") == sid:
            session["manifest_ready"] = True
            session["files_at_start"] = count
            write_json(cfg.session_file, session)
        log_event(cfg, "baseline_snapshot", session_id=sid, files=count,
                  roots=cfg.data_roots)
    except Exception as exc:
        log_event(cfg, "baseline_snapshot_failed", session_id=sid, error=str(exc))


def heartbeat(cfg, session):
    try:
        session["last_seen_local"] = iso_local()
        write_json(cfg.session_file, session)
    except Exception:
        pass


# --------------------------------------------------------------------------
# end
# --------------------------------------------------------------------------

def end_session(cfg, session, end_reason="nis_closed", end_dt=None, notes=""):
    """
    Close a session: final snapshot, diff, write the three log files locally,
    mirror to the network, clear session.json.

    Returns the path of the session CSV, or None on total failure.
    """
    stop_baseline()

    sid = session.get("session_id") or short_id()
    ended = end_dt or now_local()
    started = parse_local(session.get("start_local", "")) or ended
    duration_min = max(0, int(round((ended - started).total_seconds() / 60.0)))

    log_event(cfg, "session_end", session_id=sid, end_reason=end_reason,
              duration_min=duration_min)

    # ---- final snapshot + diff -----------------------------------------
    summary = {"files_at_start": session.get("files_at_start", 0),
               "files_at_end": 0, "files_new": 0, "files_modified": 0,
               "files_deleted": 0, "bytes_added": 0}
    changes = []
    truncated = False
    scan_note = ""

    start_manifest = session.get("manifest_start", "")
    if session.get("manifest_ready") and os.path.isfile(start_manifest):
        try:
            end_manifest = os.path.join(cfg.manifest_dir, sid + "_end.csv.gz")
            scan.snapshot(cfg, end_manifest)
            changes, summary = scan.diff(start_manifest, end_manifest)
        except Exception as exc:
            scan_note = "file diff failed: %s" % exc
            log_event(cfg, "diff_failed", session_id=sid, error=str(exc))
    else:
        scan_note = "baseline snapshot did not complete; file changes not recorded"
        log_event(cfg, "diff_skipped", session_id=sid, reason=scan_note)

    # ---- filenames ------------------------------------------------------
    stem = "%s_%s_%03dm_%s" % (
        started.strftime("%Y-%m-%d_%H%M"),
        name_for_filename(session.get("user_name") or session.get("user_email") or "unknown"),
        duration_min, sid)

    local_dir = cfg.local_log_dir(started)
    csv_path = os.path.join(local_dir, stem + ".csv")
    events_path = os.path.join(local_dir, stem + "_events.jsonl")
    detail_path = os.path.join(local_dir, stem + "_files.csv")

    # ---- file-change detail --------------------------------------------
    try:
        _, truncated = scan.write_detail_csv(detail_path, changes, cfg.max_detail_rows)
    except Exception as exc:
        scan_note = (scan_note + "; " if scan_note else "") + "detail write failed: %s" % exc
        detail_path = ""

    # ---- session row ----------------------------------------------------
    row = {
        "session_id": sid,
        "computer": session.get("computer", cfg.computer_id),
        "computer_label": session.get("computer_label", cfg.computer_label),
        "user_name": session.get("user_name", ""),
        "user_email": session.get("user_email", ""),
        "start_local": session.get("start_local", ""),
        "start_utc": session.get("start_utc", ""),
        "end_local": iso_local(ended),
        "end_utc": iso_utc(),
        "duration_min": duration_min,
        "end_reason": end_reason,
        "launch_mode": session.get("launch_mode", ""),
        "nis_exe": session.get("nis_exe", ""),
        "master_pin_used": session.get("master_pin_used", False),
        "declared_operator": session.get("declared_operator", ""),
        "files_at_start": summary.get("files_at_start", 0),
        "files_at_end": summary.get("files_at_end", 0),
        "files_new": summary.get("files_new", 0),
        "files_modified": summary.get("files_modified", 0),
        "files_deleted": summary.get("files_deleted", 0),
        "bytes_added": summary.get("bytes_added", 0),
        "detail_truncated": truncated,
        "detail_file": os.path.basename(detail_path) if detail_path else "",
        "user_list_source": session.get("user_list_source", ""),
        "app_version": session.get("app_version", VERSION),
        "notes": "; ".join(x for x in (notes, scan_note) if x),
    }

    try:
        with open(csv_path, "w", encoding="utf-8", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=SESSION_COLUMNS)
            w.writeheader()
            w.writerow(row)
    except Exception as exc:
        log_event(cfg, "session_csv_failed", session_id=sid, error=str(exc))
        csv_path = None

    # ---- per-session events --------------------------------------------
    buf = os.path.join(cfg.local_root, "buffers", sid + ".jsonl")
    try:
        if os.path.isfile(buf):
            shutil.move(buf, events_path)
        else:
            atomic_write_text(events_path, "")
    except Exception:
        events_path = ""

    # ---- optional rolling index ----------------------------------------
    if cfg.write_master_index:
        _append_index(cfg, row)

    # ---- clear the session ----------------------------------------------
    # Retried, and verified. On Windows a delete can fail transiently while
    # another thread or a virus scanner still holds the handle. Swallowing
    # that silently leaves session.json behind, so the next start sees a
    # stale open session and writes a duplicate record for it.
    cleared = False
    for _ in range(5):
        try:
            if os.path.isfile(cfg.session_file):
                os.remove(cfg.session_file)
            if not os.path.isfile(cfg.session_file):
                cleared = True
                break
        except Exception:
            pass
        time.sleep(0.2)
    if not cleared:
        log_event(cfg, "session_file_not_cleared", session_id=sid,
                  path=cfg.session_file)

    for leftover in (session.get("manifest_start"),
                     os.path.join(cfg.manifest_dir, sid + "_end.csv.gz")):
        try:
            if leftover and os.path.isfile(leftover):
                os.remove(leftover)
        except Exception:
            pass

    # ---- mirror to the network ------------------------------------------
    for path in (csv_path, events_path, detail_path):
        if path and os.path.isfile(path):
            queue_for_sync(cfg, path, started)
    flush_sync(cfg)

    return csv_path


def _append_index(cfg, row):
    """One skimmable rolling index per computer. Per-session files remain
    the record of truth; this is convenience only and is safe to delete."""
    try:
        idx = os.path.join(cfg.local_root, "logs", sanitize(cfg.computer_id),
                           "index.csv")
        ensure_dir(os.path.dirname(idx))
        new = not os.path.isfile(idx)
        with open(idx, "a", encoding="utf-8", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=SESSION_COLUMNS)
            if new:
                w.writeheader()
            w.writerow(row)
    except Exception:
        pass


# --------------------------------------------------------------------------
# network mirroring
# --------------------------------------------------------------------------

def queue_for_sync(cfg, local_path, dt=None):
    dest_dir = cfg.network_log_dir(dt)
    if not dest_dir:
        return
    marker = os.path.join(cfg.pending_sync_dir,
                          sanitize(os.path.basename(local_path)) + ".json")
    try:
        write_json(marker, {"src": local_path, "dest_dir": dest_dir})
    except Exception:
        pass


def flush_sync(cfg):
    """Best-effort copy of anything queued. Local originals are never removed."""
    try:
        markers = [os.path.join(cfg.pending_sync_dir, f)
                   for f in os.listdir(cfg.pending_sync_dir) if f.endswith(".json")]
    except Exception:
        return 0

    done = 0
    for marker in markers:
        item = read_json(marker)
        if not item:
            try:
                os.remove(marker)
            except Exception:
                pass
            continue
        src, dest_dir = item.get("src"), item.get("dest_dir")
        if not src or not os.path.isfile(src):
            try:
                os.remove(marker)
            except Exception:
                pass
            continue
        try:
            ensure_dir(dest_dir)
            shutil.copy2(src, os.path.join(dest_dir, os.path.basename(src)))
            os.remove(marker)
            done += 1
        except Exception:
            continue  # share is down; try again next time
    if done:
        log_event(cfg, "sync_flushed", files=done)
    return done


# --------------------------------------------------------------------------
# crash recovery
# --------------------------------------------------------------------------

def recover_if_needed(cfg, nis_running):
    """
    Called when the agent starts. If session.json shows an open session:
      * NIS still running -> the session is genuinely still live, resume it.
      * NIS not running   -> the agent died or the PC restarted. Close the
                             session using the last heartbeat as the end time.
    Returns the session dict to resume, or None.
    """
    session = read_json(cfg.session_file)
    if not session or not session.get("session_id"):
        return None
    if nis_running:
        log_event(cfg, "session_resumed", session_id=session["session_id"])
        return session
    end_dt = parse_local(session.get("last_seen_local", "")) or now_local()
    end_session(cfg, session, end_reason="recovered_agent_stopped", end_dt=end_dt,
                notes="end time estimated from last heartbeat")
    return None
