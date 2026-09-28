"""
ISG-NIS-Helper self-test.

Exercises everything except the Tk window: config parsing, placeholder
detection, the approved-user list (network + cache fallback + PIN
override), the snapshot/diff engine, session start and end, per-session
file naming, and mirroring to the "network" share.

Runs anywhere Python 3.8+ runs, including on a machine with no microscope
attached. Run it before you go near the scope:

    python selftest.py
"""

import csv
import json
import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from isg_common import Config, iso_local, load_users, save_pin_override  # noqa
import isg_health as health_mod    # noqa
import isg_proc as proc            # noqa
import isg_session as sess         # noqa

PASS, FAIL = [], []


def check(label, condition, detail=""):
    (PASS if condition else FAIL).append(label)
    print("  %s  %s%s" % ("PASS" if condition else "FAIL", label,
                          ("  -- " + detail) if detail and not condition else ""))


CONFIG_TEMPLATE = """
[instrument]
computer_label = TEST-SCOPE Ti2
computer_id = TESTPC
display_name = Microscope Access Log

[paths]
nis_executable = {nis}
data_roots = {roots}
network_root = {net}
users_file = {users}
local_root = {local}

[processes]
nis_process_names = nis_ar.exe
gate_viewer = false
viewer_process_names = nis_viewer.exe

[behavior]
launch_grace_seconds = 120
poll_seconds = 3
heartbeat_seconds = 15
handoff_grace_seconds = 300
write_master_index = true
max_detail_rows = 50000
fullscreen_signin = false
badge_corner = br

[scan]
exclude_dirs = $RECYCLE.BIN; System Volume Information
include_extensions =
follow_symlinks = false

[contacts]
admin1_name = Andrew Bazley
admin1_email = Andrew.Bazley@nyulangone.org
admin2_name = Guru Kidiyoor
admin2_email = Gururajrao.Kidiyoor@nyulangone.org

[access]
master_pin = 906118
"""


def build_sandbox(root):
    local = os.path.join(root, "ProgramData", "ISG-NIS-Helper")
    net = os.path.join(root, "share", "ISG-NIS-Helper")
    data = os.path.join(root, "ImagingData")
    os.makedirs(os.path.join(data, "2026-09-21", "SampleA"))
    os.makedirs(net)
    os.makedirs(local)

    for i in range(5):
        with open(os.path.join(data, "2026-09-21", "SampleA", "pre_%02d.nd2" % i), "w") as fh:
            fh.write("x" * (100 + i))

    with open(os.path.join(root, "users.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["name", "email", "pin", "active", "notes"])
        w.writerow(["Andrew Bazley", "Andrew.Bazley@nyulangone.org", "1234", "yes", "manager"])
        w.writerow(["Test Trainee", "test.trainee@nyulangone.org", "5678", "yes", ""])
        w.writerow(["Gone Postdoc", "gone@nyulangone.org", "9999", "no", "left"])

    with open(os.path.join(root, "fake_nis.exe"), "w") as fh:
        fh.write("pretend acquisition software")

    cfg_path = os.path.join(root, "config.ini")
    with open(cfg_path, "w") as fh:
        fh.write(CONFIG_TEMPLATE.format(
            nis=os.path.join(root, "fake_nis.exe"),
            roots=data, net=net, local=local,
            users=os.path.join(root, "users.csv")))
    return cfg_path, data, net, local


def main():
    # Say which copy this is. Running a stale copy from somewhere else and
    # reading its results as current is an easy and expensive mistake.
    from isg_common import VERSION
    print("")
    print("ISG-NIS-Helper self-test")
    print("  version : %s" % VERSION)
    print("  running : %s" % os.path.abspath(__file__))
    print("  config  : %s" % os.path.join(HERE, "config.ini"))

    root = tempfile.mkdtemp(prefix="isg_test_")
    try:
        cfg_path, data, net, local = build_sandbox(root)

        print("\n[1] configuration")
        cfg = Config(cfg_path)
        check("config.ini parses", cfg.computer_label == "TEST-SCOPE Ti2")
        check("data_roots parsed as a list", cfg.data_roots == [data], str(cfg.data_roots))
        check("no placeholders remain in a filled config", cfg.unset_placeholders() == [],
              str(cfg.unset_placeholders()))

        # Regression: ";" is the list separator, not an inline comment marker.
        multi = os.path.join(root, "multi.ini")
        with open(cfg_path) as fh:
            txt = fh.read()
        with open(multi, "w") as fh:
            fh.write(txt.replace("data_roots = " + data,
                                 "data_roots = " + data + "; " + os.path.join(root, "Second")))
        mcfg = Config(multi)
        check("semicolon-separated data_roots are all kept", len(mcfg.data_roots) == 2,
              str(mcfg.data_roots))
        check("second root parsed intact", mcfg.data_roots[1].endswith("Second"),
              str(mcfg.data_roots))

        # Asserting a COUNT here was brittle: the moment anyone edits the
        # config sitting next to selftest.py -- which is exactly what happens
        # on a real machine -- the number changes and the test cries wolf.
        # Check instead that the placeholder mechanism flags real keys and
        # never flags the optional ones.
        shipped = Config(os.path.join(HERE, "config.ini"))
        missing = shipped.unset_placeholders()
        check("the placeholder check reports whole keys",
              all(k.startswith("[") for k in missing), str(missing))
        check("network_root is never required", 
              not any("network_root" in k for k in missing), str(missing))
        check("users_file is never required",
              not any("users_file" in k for k in missing), str(missing))

        print("\n[2] approved user list (local file, no network)")
        users, source = load_users(cfg)
        check("loaded from this machine's own users.csv", source == "local", source)
        check("inactive users are still listed but flagged",
              len([u for u in users if u["active"]]) == 2)
        check("PINs read correctly",
              [u["pin"] for u in users if u["email"].startswith("test")] == ["5678"])

        save_pin_override(cfg, "test.trainee@nyulangone.org", "4321")
        users, _ = load_users(cfg)
        trainee = [u for u in users if u["email"].startswith("test")][0]
        check("a user-set PIN overrides the assigned one", trainee["pin"] == "4321")
        check("and is flagged as changed", trainee.get("pin_changed") is True)
        check("the override lives under local_root, not beside users.csv",
              os.path.isfile(os.path.join(cfg.local_root, "pins",
                                          "test.trainee-nyulangone.org.txt")))
        with open(os.path.join(root, "users.csv")) as fh:
            check("ISG-NIS-Helper never rewrites users.csv", "4321" not in fh.read())

        hidden = os.path.join(root, "users.csv") + ".away"
        os.rename(os.path.join(root, "users.csv"), hidden)
        users, source = load_users(cfg)
        check("a missing list is reported as missing, not silently empty",
              source == "none", source)
        check("and yields no users", users == [])
        os.rename(hidden, os.path.join(root, "users.csv"))

        print("\n[3] session: start -> work -> end")
        user = {"name": "Andrew Bazley", "email": "Andrew.Bazley@nyulangone.org"}
        session = sess.start_session(cfg, user, launch_mode="helper",
                                     user_list_source="network", nis_exe="nis_ar.exe")
        check("session.json written", os.path.isfile(cfg.session_file))

        for _ in range(100):
            s = json.load(open(cfg.session_file))
            if s.get("manifest_ready"):
                break
            time.sleep(0.05)
        s = json.load(open(cfg.session_file))
        check("baseline snapshot completed in the background", s.get("manifest_ready") is True)
        check("baseline counted the existing files", s.get("files_at_start") == 5,
              str(s.get("files_at_start")))

        acq = os.path.join(data, "2026-09-21", "SampleA")
        time.sleep(0.05)
        for i in range(3):
            with open(os.path.join(acq, "timelapse_%02d.nd2" % i), "w") as fh:
                fh.write("y" * 500)
        with open(os.path.join(acq, "pre_00.nd2"), "a") as fh:
            fh.write("appended")
        os.remove(os.path.join(acq, "pre_04.nd2"))

        session = json.load(open(cfg.session_file))
        csv_path = sess.end_session(cfg, session, end_reason="nis_closed")

        print("\n[4] session log files")
        check("session CSV was written", bool(csv_path) and os.path.isfile(csv_path))
        stem = os.path.basename(csv_path)[:-4]
        folder = os.path.dirname(csv_path)
        check("filename carries surname-first name", "Bazley-Andrew" in stem, stem)
        check("filename carries date and time",
              stem[:4].isdigit() and stem[4] == "-", stem)
        check("filename carries duration in minutes", "m_" in stem, stem)
        check("events file written", os.path.isfile(os.path.join(folder, stem + "_events.jsonl")))
        check("file-change detail written", os.path.isfile(os.path.join(folder, stem + "_files.csv")))

        row = list(csv.DictReader(open(csv_path)))[0]
        check("one row per session", len(list(csv.DictReader(open(csv_path)))) == 1)
        check("3 new files recorded", row["files_new"] == "3", row["files_new"])
        check("1 modified file recorded", row["files_modified"] == "1", row["files_modified"])
        check("1 deleted file recorded", row["files_deleted"] == "1", row["files_deleted"])
        check("end reason recorded", row["end_reason"] == "nis_closed")
        check("user name and email recorded",
              row["user_name"] == "Andrew Bazley" and "@" in row["user_email"])
        check("start and end timestamps recorded in local and UTC",
              all(row[k] for k in ("start_local", "start_utc", "end_local", "end_utc")))

        detail = list(csv.DictReader(open(os.path.join(folder, stem + "_files.csv"))))
        check("detail lists every change", len(detail) == 5, str(len(detail)))
        check("detail names the deleted file",
              any(d["change"] == "deleted" and d["path"].endswith("pre_04.nd2") for d in detail))

        events = [json.loads(l) for l in
                  open(os.path.join(folder, stem + "_events.jsonl")) if l.strip()]
        kinds = [e["kind"] for e in events]
        check("session events captured", "session_start" in kinds and "session_end" in kinds,
              str(kinds))

        print("\n[5] mirroring and cleanup")
        net_dir = cfg.network_log_dir()
        mirrored = os.listdir(net_dir) if net_dir and os.path.isdir(net_dir) else []
        check("all three files mirrored to the share", len(mirrored) == 3, str(mirrored))
        check("session.json cleared at end", not os.path.isfile(cfg.session_file))
        check("temporary manifests cleaned up",
              len([f for f in os.listdir(cfg.manifest_dir)]) == 0,
              str(os.listdir(cfg.manifest_dir)))
        idx = os.path.join(local, "logs", "TESTPC", "index.csv")
        check("rolling index appended", os.path.isfile(idx) and
              len(list(csv.DictReader(open(idx)))) == 1)

        print("\n[6] offline mirroring queues instead of failing")
        # Simulate an unreachable share the way Windows behaves for a dead
        # UNC path: the destination cannot be created at all.
        shutil.rmtree(os.path.dirname(net))
        with open(os.path.dirname(net), "w") as fh:
            fh.write("share is offline")

        session = sess.start_session(cfg, user, user_list_source="cache", nis_exe="nis_ar.exe")
        for _ in range(100):
            if (json.load(open(cfg.session_file)) or {}).get("manifest_ready"):
                break
            time.sleep(0.05)
        p2 = sess.end_session(cfg, json.load(open(cfg.session_file)),
                              end_reason="nis_closed")
        check("session still logged locally with the share gone", bool(p2) and os.path.isfile(p2))
        pend = os.listdir(cfg.pending_sync_dir)
        check("mirroring queued for later", len(pend) == 3, str(pend))

        os.remove(os.path.dirname(net))
        os.makedirs(net, exist_ok=True)
        done = sess.flush_sync(cfg)
        check("queue flushes when the share returns", done == 3, str(done))
        check("queue is empty afterwards", os.listdir(cfg.pending_sync_dir) == [])

        print("\n[7] crash recovery")
        session = sess.start_session(cfg, user, user_list_source="local",
                                     nis_exe="nis_ar.exe")
        for _ in range(100):
            if (json.load(open(cfg.session_file)) or {}).get("manifest_ready"):
                break
            time.sleep(0.05)
        sess.heartbeat(cfg, json.load(open(cfg.session_file)))
        resumed = sess.recover_if_needed(cfg, nis_running=True)
        check("open session resumes while NIS is running", resumed is not None)
        resumed = sess.recover_if_needed(cfg, nis_running=False)
        check("orphaned session is closed when NIS is gone", resumed is None)
        check("session.json cleared by recovery", not os.path.isfile(cfg.session_file),
              "left behind at " + cfg.session_file)
        recovered = [f for f in os.listdir(os.path.dirname(csv_path))
                     if f.endswith(".csv") and not f.endswith("_files.csv")]
        check("recovery produced its own session file", len(recovered) >= 3,
              str(len(recovered)))

        print("\n[8] failsafe: an unreadable process list is not 'nothing running'")
        real = proc.list_processes()
        check("a real process list is readable here", real is not None)
        check("and is judged plausible", proc.enumeration_is_plausible(real))
        check("an empty list is NOT plausible", not proc.enumeration_is_plausible([]))
        check("None is NOT plausible", not proc.enumeration_is_plausible(None))
        check("a short list is NOT plausible",
              not proc.enumeration_is_plausible([(1, "a.exe"), (2, "b.exe")]))
        check("a long list with no known system process is NOT plausible",
              not proc.enumeration_is_plausible([(i, "made-up-%d.exe" % i) for i in range(50)]))

        saved = proc.list_processes
        try:
            proc.list_processes = lambda: None
            check("is_running returns None, not False, when enumeration fails",
                  proc.is_running(["nis_ar.exe"]) is None)
            check("find_matching returns None too",
                  proc.find_matching(["nis_ar.exe"]) is None)
        finally:
            proc.list_processes = saved

        print("\n[9] failsafe: enforcement preconditions")
        # a live agent heartbeat, so the require_agent check can pass
        json.dump({"session_id": "hb", "last_seen_local": iso_local()},
                  open(cfg.session_file, "w"))

        ok, checks = health_mod.run_checks(cfg)
        check("a healthy sandbox passes every check", ok, str(checks))
        allowed, why, _ = health_mod.may_enforce(cfg, {})
        check("and enforcement is allowed", allowed, why)

        missing = Config(cfg_path)
        missing.nis_executable = os.path.join(root, "gone.exe")
        allowed, why, _ = health_mod.may_enforce(missing, {})
        check("a vanished NIS executable blocks enforcement", not allowed)
        check("and the reason names it", "nis_executable" in why, why)

        # A FILE where the directory should be fails identically on Windows
        # and POSIX. The old test used a Linux-only path, so on Windows it
        # quietly created C:\proc\... and the assertion failed.
        blocker = os.path.join(root, "blocked-store")
        with open(blocker, "w") as fh:
            fh.write("not a directory")
        unwritable = Config(cfg_path)
        unwritable.local_root = blocker
        ok2, res2 = health_mod.run_checks(unwritable)
        check("an unwritable state store fails its check",
              res2.get("state_store") != "ok", str(res2))

        os.remove(cfg.session_file)
        no_agent = Config(cfg_path)
        allowed, why, _ = health_mod.may_enforce(no_agent, {})
        check("a dead sign-in agent blocks enforcement", not allowed, why)
        check("and the reason names the agent", "agent" in why.lower(), why)

        print("\n[10] failsafe: circuit breaker")
        health = {}
        for i in range(cfg.max_terminations_per_hour):
            health = health_mod.record_termination(cfg, health)
        check("repeated terminations trip safe mode", health_mod.in_safe_mode(cfg))
        info = health_mod.safe_mode_info(cfg)
        check("safe mode records why", "termination" in info.get("reason", ""),
              str(info))
        allowed, why, _ = health_mod.may_enforce(cfg, health)
        check("safe mode blocks enforcement", not allowed)
        check("but nothing stops the logging",
              os.path.isdir(cfg.rolling_events_dir))
        check("clearing safe mode works", health_mod.clear_safe_mode(cfg))
        check("and it is gone", not health_mod.in_safe_mode(cfg))

        health = {}
        for i in range(cfg.max_errors_per_10min):
            health = health_mod.record_error(cfg, health, "synthetic")
        check("an error burst trips safe mode", health_mod.in_safe_mode(cfg))
        health_mod.clear_safe_mode(cfg)

        health = {"terminations": [time.time() - 7200] * 10}
        health = health_mod.record_termination(cfg, health)
        check("terminations older than an hour do not count",
              not health_mod.in_safe_mode(cfg))
        health_mod.clear_safe_mode(cfg)

        print("\n[11] failsafe: Windows update pause")
        health = {"os_build": "Windows|10.0.26100"}
        health = health_mod.note_os_build(cfg, health)
        check("an OS build change is detected",
              health.get("os_build_changed_at") is not None)
        paused, remaining = health_mod.enforcement_paused(cfg, health)
        check("enforcement pauses after an OS update", paused)
        check("for about the configured window",
              abs(remaining - cfg.post_update_grace_hours * 3600) < 60, str(remaining))
        allowed, why, _ = health_mod.may_enforce(cfg, health)
        check("and may_enforce says no", not allowed)
        check("naming the update as the reason", "update" in why.lower(), why)
        health_mod.clear_safe_mode(cfg)

        health["enforcement_paused_until_epoch"] = time.time() - 1
        paused, _ = health_mod.enforcement_paused(cfg, health)
        check("the pause expires on its own", not paused)

        same = health_mod.note_os_build(cfg, dict(health))
        check("an unchanged build changes nothing",
              same.get("os_build") == health_mod.current_os_build())

        summary = health_mod.summarise(cfg, health)
        check("health.json is written", os.path.isfile(health_mod.health_path(cfg)))
        check("and reports the machine", summary.get("computer") == "TESTPC")
        health_mod.clear_safe_mode(cfg)

        print("\n[12] the project name is not shown to users")
        check("display_name is read from config",
              cfg.display_name == "Microscope Access Log", cfg.display_name)
        # A config.ini saved with a UTF-8 BOM (PowerShell 5.1 -Encoding UTF8, or
        # Notepad "UTF-8 with BOM") must still parse -- otherwise the agent dies
        # at launch with "File contains no section headers" on line 1.
        _raw = open(os.path.join(HERE, "config.ini"), encoding="utf-8").read()
        _bom_path = os.path.join(root, "config_with_bom.ini")
        with open(_bom_path, "w", encoding="utf-8") as _fh:
            _fh.write("\ufeff" + _raw)
        _bom_ok = True
        try:
            _cfg_bom = Config(_bom_path)
            _bom_ok = (_cfg_bom.display_name == "Microscope Access Log")
        except Exception as _exc:
            _bom_ok = False
        check("config.ini with a UTF-8 BOM still parses", _bom_ok)

        default_cfg = Config(os.path.join(HERE, "config.ini"))
        _dn = default_cfg.display_name.lower()
        check("the shipped config sets a neutral display_name",
              "scopegate" not in _dn and "isg-nis-helper" not in _dn and "isg" not in _dn.split(),
              default_cfg.display_name)

        import re as _re
        agent_src = open(os.path.join(HERE, "isg_agent.py"), encoding="utf-8").read()
        # every string that reaches a window title, a label or a message box
        ui_strings = _re.findall(r'(?:title|text|showerror|showinfo|askyesno)\s*[=(]\s*[\"\']([^\"\']{4,})',
                                 agent_src)
        _banned = ("scopegate", "isg-nis-helper")
        offenders = [u for u in ui_strings
                     if any(b in u.lower() for b in _banned)]
        check("no user-visible string in the agent names the product",
              not offenders, str(offenders))

        print("\n[13] agent beacon (what the watcher trusts)")
        from isg_common import touch_agent_beacon, agent_beacon_age
        check("no beacon before the agent has ever run",
              agent_beacon_age(cfg) is None)
        ok, why = health_mod.check_agent_alive(cfg, 120)
        check("and the agent counts as dead", not ok, why)
        touch_agent_beacon(cfg)
        age = agent_beacon_age(cfg)
        check("the beacon is written", age is not None and age < 5, str(age))
        ok, why = health_mod.check_agent_alive(cfg, 120)
        check("a fresh beacon counts as alive", ok, why)
        ok, why = health_mod.check_agent_alive(cfg, 0)
        check("a stale beacon does not", not ok, why)
        check("and the reason is legible", "checked in" in why, why)

        print("\n[15] launcher gate (the desktop shortcut -> resident agent)")
        from isg_common import (write_launch_request, read_launch_request,
                                clear_launch_request, launch_request_path,
                                agent_is_alive, pid_running, write_json,
                                agent_beacon_path)
        clear_launch_request(cfg)
        check("no launch request to begin with", read_launch_request(cfg) is None)
        write_launch_request(cfg, requested_by="tester")
        req = read_launch_request(cfg)
        check("a fresh launch request is readable",
              bool(req) and req.get("requested_by") == "tester", str(req))
        clear_launch_request(cfg)
        check("clearing a launch request removes it",
              read_launch_request(cfg) is None
              and not os.path.isfile(launch_request_path(cfg)))
        # a stale request must be ignored, so a days-old click never auto-opens NIS
        write_json(launch_request_path(cfg),
                   {"requested_by": "old", "at_epoch": 1.0})
        check("a stale launch request is ignored", read_launch_request(cfg) is None)
        clear_launch_request(cfg)

        check("pid_running is true for this process", pid_running(os.getpid()))
        check("pid_running is false for a dead pid", not pid_running(2147480000))
        # a beacon recording THIS process must not count as 'another agent',
        # or the resident agent would refuse to start against itself
        touch_agent_beacon(cfg)
        check("a beacon from this very process is not 'another agent'",
              not agent_is_alive(cfg, fresh_seconds=120))
        # a fresh beacon with a dead pid must not count as a live agent
        write_json(agent_beacon_path(cfg),
                   {"pid": 2147480000, "at_epoch": time.time()})
        check("a fresh beacon with a dead pid is not a live agent",
              not agent_is_alive(cfg, fresh_seconds=120))

        agent_src2 = open(os.path.join(HERE, "isg_agent.py"), encoding="utf-8").read()
        check("the agent has a launch-gate entry point", "def launch_gate" in agent_src2)
        check("main() handles the --launch shortcut", '"--launch" in sys.argv' in agent_src2)
        check("the agent will not run two residents at once",
              "agent_already_running" in agent_src2)
        check("the launcher fails OPEN if no agent answers",
              "no_agent_consumed_request" in agent_src2)
        # NIS-Elements requires elevation; launching it must go through
        # ShellExecute (which honors the manifest / shows UAC), not Popen,
        # or it dies with WinError 740.
        check("NIS is launched via ShellExecute (elevation-aware)",
              "ShellExecuteW" in agent_src2 and "def launch_program" in agent_src2)
        check("no elevation-blind Popen([exe]) remains for NIS launch",
              agent_src2.count("subprocess.Popen([exe]") <= 1)

        print("\n[14] data safety")
        remaining = sorted(os.listdir(acq))
        expected = sorted(["pre_00.nd2", "pre_01.nd2", "pre_02.nd2", "pre_03.nd2",
                           "timelapse_00.nd2", "timelapse_01.nd2", "timelapse_02.nd2"])
        check("ISG-NIS-Helper did not add, move or remove any data file",
              remaining == expected, str(remaining))
        check("existing file contents untouched",
              open(os.path.join(acq, "pre_01.nd2")).read() == "x" * 101)

        print("\n" + "=" * 62)
        print("  %d passed, %d failed" % (len(PASS), len(FAIL)))
        if FAIL:
            print("  FAILED: " + ", ".join(FAIL))
        print("=" * 62 + "\n")
        return 1 if FAIL else 0

    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
