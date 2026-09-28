"""
ISG-NIS-Helper agent -- the part the user sees.

Nothing in this window carries the project name. Every visible string is
titled with [instrument] display_name, which defaults to "Microscope
Access Log". That is not a security measure -- anyone with Task Manager
can see the process, and everyone on these machines is an administrator.
It is about salience: a window branded with a product name invites
curiosity and searching, whereas something that reads as part of the
instrument is boring and gets left alone.

Runs in the logged-in user's desktop session (Task Scheduler, at logon).

Two states:
  SIGN-IN   no session is open. A large always-on-top window asks who is
            using the scope, and offers to launch NIS-Elements.
  ACTIVE    a session is open. The sign-in window disappears and a small
            badge sits in the corner showing who is signed in and for how
            long, with one button to end the session or hand over.

The session ends when NIS-Elements closes. There is no timeout, no idle
check and no automatic logout. A running acquisition is never touched.
"""

import os
import subprocess
import sys
import threading
import time
import tkinter as tk
import webbrowser
from tkinter import font as tkfont
from tkinter import messagebox, ttk

from isg_common import (
    VERSION, Config, ConfigError, clear_handoff, ensure_dir,
    handoff_active, load_users, log_event, now_local, parse_local,
    read_json, save_pin_override, set_handoff, touch_agent_beacon,
    unauth_path, agent_is_alive, write_launch_request, read_launch_request,
    clear_launch_request, launch_request_path,
)
import isg_health as health_mod
import isg_proc as proc
import isg_session as sess

BG = "#12161c"
CARD = "#1b222c"
FG = "#e8edf4"
MUTED = "#9aa7b8"
ACCENT = "#4da3ff"
WARN = "#ffcc55"
DANGER = "#ff6b6b"
OK = "#5ad18a"

MASTER_ENTRY = "--  Department manager (master PIN)  --"

CONSENT_TEXT = (
    "I confirm I am trained and authorized to use this instrument, and that I am "
    "responsible for it — and for anyone I allow to operate it — for the "
    "duration of this session."
)


class Agent(object):

    def __init__(self, cfg):
        self.cfg = cfg
        self.session = None
        self.users = []
        self.user_source = "none"
        self.display_map = {}
        self._last_heartbeat = 0.0
        self._gone_streak = 0
        self._unknown_streak = 0

        self.root = tk.Tk()
        # Titled with the neutral display name, never the project name.
        self.root.title("%s — %s" % (cfg.display_name,
                                     cfg.computer_label or cfg.computer_id))
        self.root.configure(bg=BG)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close_signin)

        self._make_fonts()
        self._build_signin()
        self._build_badge()

        touch_agent_beacon(self.cfg)
        sess.flush_sync(self.cfg)
        self.refresh_users()

        # None means the process list could not be read. Treat that as
        # "NIS is still running" so a bad reading can never close an open
        # session on startup.
        running = proc.is_running(self.cfg.gated_process_names)
        resumed = sess.recover_if_needed(self.cfg, running is not False)
        if resumed:
            self.session = resumed
            self.show_badge()
        else:
            # New model: the sign-in window is not shown at logon. It appears
            # only when someone clicks the NIS-Elements shortcut (which routes
            # here as a launch request) or when NIS is started directly and the
            # watcher/agent notices no one has signed in.
            self.root.withdraw()
            self.badge.withdraw()

        self.root.after(200, self.tick)

    # ------------------------------------------------------------------
    # fonts / chrome
    # ------------------------------------------------------------------

    def _make_fonts(self):
        self.f_title = tkfont.Font(family="Segoe UI", size=20, weight="bold")
        self.f_sub = tkfont.Font(family="Segoe UI", size=12)
        self.f_body = tkfont.Font(family="Segoe UI", size=10)
        self.f_small = tkfont.Font(family="Segoe UI", size=9)
        self.f_badge = tkfont.Font(family="Segoe UI", size=11, weight="bold")
        self.f_link = tkfont.Font(family="Segoe UI", size=10, underline=True)

    def _center(self, win, w=None, h=None):
        """Size to the content, then centre.

        Fixed pixel sizes clip: a dialog whose message runs longer than
        expected pushes its buttons off the bottom edge, which is exactly
        what the fixed 580x300 config-error window used to do. Ask Tk what
        the layout needs, then apply a floor and a screen-size ceiling."""
        win.update_idletasks()
        need_w = max(win.winfo_reqwidth(), w or 0)
        need_h = max(win.winfo_reqheight(), h or 0)
        sw = win.winfo_screenwidth()
        sh = win.winfo_screenheight()
        final_w = min(need_w, int(sw * 0.95))
        final_h = min(need_h, int(sh * 0.90))
        win.minsize(min(480, final_w), min(320, final_h))
        win.geometry("%dx%d+%d+%d" % (
            final_w, final_h,
            max(0, (sw - final_w) // 2), max(0, (sh - final_h) // 3)))

    # ------------------------------------------------------------------
    # sign-in window
    # ------------------------------------------------------------------

    def _build_signin(self):
        r = self.root
        wrap = tk.Frame(r, bg=BG, padx=34, pady=26)
        wrap.pack(fill="both", expand=True)

        tk.Label(wrap, text="This instrument logs all usage.",
                 bg=BG, fg=FG, font=self.f_title, anchor="w").pack(fill="x")
        tk.Label(wrap, text="Prior authorization and training are required to use it.",
                 bg=BG, fg=WARN, font=self.f_sub, anchor="w").pack(fill="x", pady=(4, 2))
        tk.Label(wrap, text=self.cfg.computer_label or self.cfg.computer_id,
                 bg=BG, fg=MUTED, font=self.f_small, anchor="w").pack(fill="x", pady=(0, 14))

        self.banner = tk.Label(wrap, text="", bg=BG, fg=DANGER,
                               font=self.f_body, anchor="w", justify="left",
                               wraplength=640)
        self.banner.pack(fill="x", pady=(0, 10))

        card = tk.Frame(wrap, bg=CARD, padx=22, pady=20)
        card.pack(fill="x")

        tk.Label(card, text="Name", bg=CARD, fg=MUTED, font=self.f_small,
                 anchor="w").pack(fill="x")
        self.var_user = tk.StringVar()
        self.cbo_user = ttk.Combobox(card, textvariable=self.var_user,
                                     state="readonly", font=self.f_body, height=18)
        self.cbo_user.pack(fill="x", pady=(2, 12))
        self.cbo_user.bind("<<ComboboxSelected>>", self._on_user_selected)

        self.frm_manager = tk.Frame(card, bg=CARD)
        tk.Label(self.frm_manager, text="Your name (typed)", bg=CARD, fg=MUTED,
                 font=self.f_small, anchor="w").pack(fill="x")
        self.var_manager = tk.StringVar()
        tk.Entry(self.frm_manager, textvariable=self.var_manager, font=self.f_body,
                 bg=BG, fg=FG, insertbackground=FG,
                 relief="flat").pack(fill="x", ipady=4, pady=(2, 12))

        tk.Label(card, text="PIN", bg=CARD, fg=MUTED, font=self.f_small,
                 anchor="w").pack(fill="x")
        self.var_pin = tk.StringVar()
        self.ent_pin = tk.Entry(card, textvariable=self.var_pin, show="•",
                                font=self.f_body, bg=BG, fg=FG,
                                insertbackground=FG, relief="flat")
        self.ent_pin.pack(fill="x", ipady=4, pady=(2, 14))
        self.ent_pin.bind("<Return>", lambda e: self.do_signin())

        self.var_consent = tk.IntVar(value=0)
        tk.Checkbutton(card, text=CONSENT_TEXT, variable=self.var_consent,
                       bg=CARD, fg=FG, selectcolor=BG, activebackground=CARD,
                       activeforeground=FG, font=self.f_small, anchor="w",
                       justify="left", wraplength=600,
                       highlightthickness=0, bd=0).pack(fill="x", pady=(0, 14))

        self.btn_go = tk.Button(card, text="Sign in and start NIS-Elements",
                                command=self.do_signin, font=self.f_sub,
                                bg=ACCENT, fg="#08111c", activebackground=ACCENT,
                                relief="flat", cursor="hand2", pady=8)
        self.btn_go.pack(fill="x")

        self.lbl_status = tk.Label(card, text="", bg=CARD, fg=MUTED,
                                   font=self.f_small, anchor="w", justify="left",
                                   wraplength=620)
        self.lbl_status.pack(fill="x", pady=(10, 0))

        self.lbl_health = tk.Label(card, text="", bg=CARD, fg=WARN,
                                   font=self.f_small, anchor="w", justify="left",
                                   wraplength=620)
        self.lbl_health.pack(fill="x", pady=(6, 0))

        foot = tk.Frame(wrap, bg=BG)
        foot.pack(fill="x", pady=(16, 0))

        c = self.cfg
        both = "%s and %s" % (c.admin1_name or "the instrument manager",
                              c.admin2_name or "the lab manager")
        tk.Button(foot, text="Contact %s to obtain training and approval" % both,
                  command=self._contact_both, font=self.f_body,
                  bg=CARD, fg=ACCENT, activebackground=CARD, activeforeground=ACCENT,
                  relief="flat", cursor="hand2", pady=7).pack(fill="x")

        links = tk.Frame(foot, bg=BG)
        links.pack(fill="x", pady=(8, 0))
        for nm, em in ((c.admin1_name, c.admin1_email), (c.admin2_name, c.admin2_email)):
            if not em:
                continue
            lab = tk.Label(links, text="%s  <%s>" % (nm, em), bg=BG, fg=ACCENT,
                           font=self.f_link, cursor="hand2", anchor="w")
            lab.pack(fill="x")
            lab.bind("<Button-1>", lambda e, a=em: self._mailto([a]))

        tk.Label(wrap, text="Sessions are recorded locally and on the lab server. "
                            "No image data is read, moved or modified.",
                 bg=BG, fg=MUTED, font=self.f_small, anchor="w",
                 wraplength=660, justify="left").pack(fill="x", pady=(14, 0))

        self._center(self.root, 760, 700)

    def _on_user_selected(self, _evt=None):
        if self.var_user.get() == MASTER_ENTRY:
            self.frm_manager.pack(fill="x", before=self.ent_pin)
        else:
            self.frm_manager.pack_forget()

    def _mailto(self, addresses, subject=None):
        subject = subject or "Microscope training / access request — %s" % (
            self.cfg.computer_label or self.cfg.computer_id)
        url = "mailto:%s?subject=%s" % (",".join(addresses), subject.replace(" ", "%20"))
        try:
            webbrowser.open(url)
        except Exception:
            messagebox.showinfo(self.cfg.display_name, "Please email: " + ", ".join(addresses))

    def _contact_both(self):
        addrs = [a for a in (self.cfg.admin1_email, self.cfg.admin2_email) if a]
        log_event(self.cfg, "training_request_clicked", contacts=addrs)
        self._mailto(addrs)

    def _on_close_signin(self):
        # The sign-in window is not a lock. Let it be dismissed; it comes
        # straight back if NIS-Elements is launched without a session.
        self.root.withdraw()

    # ------------------------------------------------------------------
    # badge
    # ------------------------------------------------------------------

    def _build_badge(self):
        self.badge = tk.Toplevel(self.root)
        self.badge.overrideredirect(True)
        self.badge.attributes("-topmost", True)
        self.badge.configure(bg=CARD)
        self.badge.withdraw()

        inner = tk.Frame(self.badge, bg=CARD, padx=12, pady=8)
        inner.pack()

        self.lbl_badge = tk.Label(inner, text="", bg=CARD, fg=OK,
                                  font=self.f_badge, anchor="w")
        self.lbl_badge.pack(side="left", padx=(0, 12))

        tk.Button(inner, text="End session / switch user",
                  command=self.do_switch_user, font=self.f_small,
                  bg=BG, fg=FG, activebackground=BG, activeforeground=FG,
                  relief="flat", cursor="hand2", padx=8, pady=3).pack(side="left")

    def _place_badge(self):
        self.badge.update_idletasks()
        w = self.badge.winfo_reqwidth()
        h = self.badge.winfo_reqheight()
        sw = self.badge.winfo_screenwidth()
        sh = self.badge.winfo_screenheight()
        m = 16
        corner = self.cfg.badge_corner
        x = m if corner in ("tl", "bl") else sw - w - m
        y = m if corner in ("tl", "tr") else sh - h - m - 48
        self.badge.geometry("+%d+%d" % (max(0, x), max(0, y)))

    # ------------------------------------------------------------------
    # state switching
    # ------------------------------------------------------------------

    def show_signin(self, banner=""):
        self.badge.withdraw()
        self.var_pin.set("")
        self.var_consent.set(0)
        self.banner.configure(text=banner)
        self.refresh_health_notice()
        self.root.deiconify()
        self.root.attributes("-topmost", True)
        if self.cfg.fullscreen_signin:
            try:
                self.root.attributes("-fullscreen", True)
            except Exception:
                pass
        self.root.lift()
        try:
            self.cbo_user.focus_set()
        except Exception:
            pass

    def show_badge(self):
        try:
            self.root.attributes("-fullscreen", False)
        except Exception:
            pass
        self.root.withdraw()
        self.badge.deiconify()
        self.badge.attributes("-topmost", True)
        self._place_badge()

    # ------------------------------------------------------------------
    # users
    # ------------------------------------------------------------------

    def refresh_health_notice(self):
        """Tell the person, on the sign-in window, when ISG-NIS-Helper is
        recording but not enforcing. Silence about that would be dishonest."""
        try:
            cfg = self.cfg
            if health_mod.in_safe_mode(cfg):
                info = health_mod.safe_mode_info(cfg)
                self.lbl_health.configure(
                    fg=DANGER,
                    text=("Reduced mode since %s. Sessions are still recorded, but "
                          "unauthorized use will not be blocked. Please tell %s."
                          % (info.get("since_local", "?"),
                             cfg.admin1_name or "the instrument manager")))
                return
            health = health_mod.read_health(cfg)
            paused, remaining = health_mod.enforcement_paused(cfg, health)
            if paused:
                self.lbl_health.configure(
                    fg=WARN,
                    text=("Windows was updated recently, so enforcement is paused "
                          "for another %d minutes. Sessions are still recorded."
                          % (remaining // 60)))
                return
            self.lbl_health.configure(text="")
        except Exception:
            pass

    def refresh_users(self):
        users, source = load_users(self.cfg)
        self.users = [u for u in users if u.get("active")]
        self.user_source = source
        self.display_map = {}
        values = []
        for u in sorted(self.users, key=lambda x: (x.get("name") or "").lower()):
            label = "%s  —  %s" % (u.get("name", ""), u.get("email", ""))
            self.display_map[label] = u
            values.append(label)
        if self.cfg.master_pin:
            values.append(MASTER_ENTRY)
        try:
            self.cbo_user["values"] = values
        except Exception:
            pass

        if source == "local" and self.users:
            msg = "Approved user list: %d trained users." % len(self.users)
            colour = MUTED
        else:
            msg = ("No approved user list was found on this instrument. "
                   "Please tell %s."
                   % (self.cfg.admin1_name or "the instrument manager"))
            colour = DANGER
        self.lbl_status.configure(text=msg, fg=colour)
        log_event(self.cfg, "user_list_loaded", source=source, count=len(self.users))

    # ------------------------------------------------------------------
    # sign in
    # ------------------------------------------------------------------

    def do_signin(self):
        label = self.var_user.get().strip()
        pin = self.var_pin.get().strip()

        if not label:
            self.banner.configure(text="Select your name.", fg=DANGER)
            return
        if not self.var_consent.get():
            self.banner.configure(
                text="You must tick the confirmation box before starting a session.",
                fg=DANGER)
            return

        master = bool(self.cfg.master_pin) and pin == self.cfg.master_pin
        declared = ""

        if label == MASTER_ENTRY:
            declared = self.var_manager.get().strip()
            if not master:
                self._fail("master", "Master PIN incorrect.")
                return
            if not declared:
                self.banner.configure(text="Type your name to use the master PIN.",
                                      fg=DANGER)
                return
            user = {"name": declared, "email": "(master PIN)"}
        else:
            user = self.display_map.get(label)
            if not user:
                self.banner.configure(text="Unknown user. Refreshing list.", fg=DANGER)
                self.refresh_users()
                return
            if not master:
                expected = (user.get("pin") or "").strip()
                if not expected:
                    self._fail(user.get("email", ""), "No PIN set for this user.")
                    self.banner.configure(
                        text="No PIN is set for you yet. Contact the instrument manager.",
                        fg=DANGER)
                    return
                if pin != expected:
                    self._fail(user.get("email", ""), "Incorrect PIN.")
                    self.banner.configure(text="Incorrect PIN.", fg=DANGER)
                    return

        self.banner.configure(text="")
        self._start_session(user, master_pin_used=master, declared_operator=declared)

        if (not master) and label != MASTER_ENTRY and not user.get("pin_changed"):
            self.root.after(400, lambda: self._offer_pin_change(user))

    def _fail(self, who, reason):
        log_event(self.cfg, "signin_failed", who=who, reason=reason)

    def _start_session(self, user, master_pin_used=False, declared_operator=""):
        cfg = self.cfg
        running = proc.find_matching(cfg.gated_process_names)
        if running is None:
            log_event(cfg, "process_list_unreadable", where="session start")
            running = []
        launch_mode = "direct" if running else "helper"
        nis_exe = running[0][1] if running else os.path.basename(cfg.nis_executable)

        if not running:
            try:
                exe = cfg.nis_executable
                if not os.path.isfile(exe):
                    messagebox.showerror(
                        cfg.display_name,
                        "NIS-Elements was not found at:\n\n%s\n\nFix "
                        "[paths] nis_executable in config.ini." % exe)
                    log_event(cfg, "nis_launch_failed", path=exe, error="not found")
                    return
                launch_program(exe)
                log_event(cfg, "nis_launched", path=exe)
            except Exception as exc:
                messagebox.showerror(cfg.display_name,
                                     "Could not start NIS-Elements:\n\n%s" % exc)
                log_event(cfg, "nis_launch_failed", error=str(exc))
                return

        clear_handoff(cfg)
        try:
            if os.path.isfile(unauth_path(cfg)):
                os.remove(unauth_path(cfg))
        except Exception:
            pass

        self.session = sess.start_session(
            cfg, user, launch_mode=launch_mode,
            master_pin_used=master_pin_used, declared_operator=declared_operator,
            user_list_source=self.user_source, nis_exe=nis_exe)
        self.show_badge()

    # ------------------------------------------------------------------
    # optional PIN change on first sign-in
    # ------------------------------------------------------------------

    def _offer_pin_change(self, user):
        win = tk.Toplevel(self.root)
        win.title("Set your own PIN")
        win.configure(bg=BG)
        win.attributes("-topmost", True)
        wrap = tk.Frame(win, bg=BG, padx=24, pady=20)
        wrap.pack(fill="both", expand=True)

        tk.Label(wrap, text="Set your own PIN (optional)", bg=BG, fg=FG,
                 font=self.f_sub, anchor="w").pack(fill="x")
        tk.Label(wrap, text="You are using the PIN you were assigned. You can replace "
                            "it with one only you know. You can skip this.",
                 bg=BG, fg=MUTED, font=self.f_small, anchor="w",
                 wraplength=380, justify="left").pack(fill="x", pady=(4, 12))

        v1, v2 = tk.StringVar(), tk.StringVar()
        for text, var in (("New PIN", v1), ("Confirm", v2)):
            tk.Label(wrap, text=text, bg=BG, fg=MUTED, font=self.f_small,
                     anchor="w").pack(fill="x")
            tk.Entry(wrap, textvariable=var, show="•", font=self.f_body,
                     bg=CARD, fg=FG, insertbackground=FG,
                     relief="flat").pack(fill="x", ipady=4, pady=(2, 10))

        msg = tk.Label(wrap, text="", bg=BG, fg=DANGER, font=self.f_small, anchor="w")
        msg.pack(fill="x")

        def save():
            a, b = v1.get().strip(), v2.get().strip()
            if len(a) < 4 or not a.isdigit():
                msg.configure(text="Use at least 4 digits.")
                return
            if a != b:
                msg.configure(text="The two entries do not match.")
                return
            ok_local, ok_net = save_pin_override(self.cfg, user.get("email", ""), a)
            log_event(self.cfg, "pin_changed", who=user.get("email", ""),
                      saved_local=ok_local, saved_network=ok_net)
            win.destroy()
            self.refresh_users()

        row = tk.Frame(wrap, bg=BG)
        row.pack(fill="x", pady=(8, 0))
        tk.Button(row, text="Save PIN", command=save, font=self.f_body, bg=ACCENT,
                  fg="#08111c", relief="flat", cursor="hand2",
                  padx=14, pady=6).pack(side="left")
        tk.Button(row, text="Skip", command=win.destroy, font=self.f_body, bg=CARD,
                  fg=FG, relief="flat", cursor="hand2",
                  padx=14, pady=6).pack(side="left", padx=8)

        self._center(win, 460, 360)

    # ------------------------------------------------------------------
    # end / handover
    # ------------------------------------------------------------------

    def do_switch_user(self):
        if not self.session:
            self.show_signin()
            return
        # Unknown counts as open here: setting the hand-over grace when it
        # was not needed is harmless, skipping it is not.
        nis_open = proc.is_running(self.cfg.gated_process_names) is not False
        if nis_open:
            ok = messagebox.askyesno(
                self.cfg.display_name,
                "End the session for %s?\n\nNIS-Elements will stay open and will not "
                "be interrupted. The next person must sign in."
                % (self.session.get("user_name") or "this user"))
            if not ok:
                return
            set_handoff(self.cfg, self.cfg.handoff_grace_seconds)
        self._end("switch_user" if nis_open else "user_ended")

    def _end(self, reason):
        session, self.session = self.session, None
        if session:
            threading.Thread(target=sess.end_session,
                             args=(self.cfg, session, reason), daemon=True).start()
        self.refresh_users()
        self.show_signin()

    # ------------------------------------------------------------------
    # main loop
    # ------------------------------------------------------------------

    def tick(self):
        cfg = self.cfg
        try:
            # Tell the watcher we are alive before anything else. If this
            # stops, the watcher stops enforcing rather than locking the
            # instrument with a logger nobody can sign in to.
            touch_agent_beacon(cfg)
            running = proc.is_running(cfg.gated_process_names)

            if running is None:
                # Could not read the process list. Hold everything: do not
                # end a session, do not raise the sign-in window.
                self._unknown_streak += 1
                self._gone_streak = 0
                if self._unknown_streak == cfg.confirm_polls:
                    log_event(cfg, "process_list_unreadable", where="agent loop")
                self.root.after(max(1, cfg.poll_seconds) * 1000, self.tick)
                return
            self._unknown_streak = 0

            if self.session:
                if not running:
                    # Require several agreeing polls before believing NIS
                    # has closed, so one bad reading cannot end a session.
                    self._gone_streak += 1
                    if self._gone_streak >= cfg.confirm_polls:
                        log_event(cfg, "nis_closed",
                                  session_id=self.session.get("session_id"),
                                  confirmed_over_polls=self._gone_streak)
                        self._gone_streak = 0
                        self._end("nis_closed")
                else:
                    self._gone_streak = 0
                    now = time.time()
                    if now - self._last_heartbeat >= cfg.heartbeat_seconds:
                        self._last_heartbeat = now
                        sess.heartbeat(cfg, self.session)
                    started = parse_local(self.session.get("start_local", ""))
                    mins = 0
                    if started:
                        mins = int((now_local() - started).total_seconds() // 60)
                    self.lbl_badge.configure(
                        text="●  %s   ·   %dh %02dm"
                             % (self.session.get("user_name", "?"), mins // 60, mins % 60))
                    self._place_badge()
            else:
                # Priority 1: someone clicked the NIS-Elements shortcut. That
                # routes here as a launch request. Open the sign-in window; on
                # success _start_session launches NIS-Elements itself.
                req = read_launch_request(cfg)
                if req is not None:
                    clear_launch_request(cfg)
                    log_event(cfg, "launch_requested",
                              requested_by=req.get("requested_by", ""))
                    self.show_signin("Sign in to start NIS-Elements.")
                    self.root.attributes("-topmost", True)
                    self.root.lift()
                # Priority 2 (backstop): NIS-Elements is already running with
                # nobody signed in -- someone bypassed the shortcut and started
                # it directly. Raise the sign-in window; the watcher closes NIS
                # after the grace period if no one signs in.
                elif running and not handoff_active(cfg):
                    info = read_json(unauth_path(cfg)) or {}
                    left = None
                    try:
                        left = int(float(info.get("deadline_epoch", 0)) - time.time())
                    except Exception:
                        left = None
                    if left is not None and left > 0:
                        self.banner.configure(
                            text="NIS-Elements is open but nobody has signed in. "
                                 "It will be closed in %d:%02d unless someone signs in."
                                 % (left // 60, left % 60), fg=DANGER)
                    else:
                        self.banner.configure(
                            text="NIS-Elements is open but nobody has signed in. "
                                 "Please sign in.", fg=DANGER)
                    if self.root.state() == "withdrawn":
                        self.show_signin(self.banner.cget("text"))
                    self.root.attributes("-topmost", True)
                    self.root.lift()
                # Otherwise: idle. Stay hidden until one of the above happens.
                self._health_tick = getattr(self, "_health_tick", 0) + 1
                if self._health_tick % 20 == 0:
                    self.refresh_health_notice()
        except Exception as exc:
            log_event(cfg, "agent_tick_error", error=str(exc))

        self.root.after(max(1, cfg.poll_seconds) * 1000, self.tick)

    def run(self):
        self.root.mainloop()


# ----------------------------------------------------------------------
# entry point
# ----------------------------------------------------------------------

def launch_program(exe):
    """Start a program the way double-clicking its icon would.

    NIS-Elements is manifested to require administrator rights. subprocess.Popen
    uses CreateProcess, which cannot elevate and fails with WinError 740
    ("requires elevation"). ShellExecute with the 'open' verb honors the target's
    manifest, so Windows shows the normal UAC prompt and launches it elevated --
    exactly what happened when the user double-clicked the old shortcut. Programs
    that do not need elevation are unaffected. Raises OSError on failure."""
    workdir = os.path.dirname(exe) or None
    if os.name == "nt":
        import ctypes
        SW_SHOWNORMAL = 1
        # Returns an HINSTANCE > 32 on success; <= 32 is an error code.
        r = ctypes.windll.shell32.ShellExecuteW(None, "open", exe, None, workdir,
                                                SW_SHOWNORMAL)
        if int(r) <= 32:
            raise OSError("ShellExecute could not start %s (code %d)" % (exe, int(r)))
    else:
        subprocess.Popen([exe], cwd=workdir)


def _config_error_window(message, display_name="Microscope Access Log"):
    r = tk.Tk()
    r.title("%s — configuration" % display_name)
    r.configure(bg=BG)
    f = tk.Frame(r, bg=BG, padx=26, pady=22)
    f.pack(fill="both", expand=True)
    # Packed to the bottom FIRST, so however long the message turns out to
    # be, it cannot push the button off the window.
    tk.Button(f, text="Close", command=r.destroy, bg=CARD, fg=FG, relief="flat",
              cursor="hand2", padx=20, pady=8,
              font=("Segoe UI", 10)).pack(side="bottom", anchor="w", pady=(18, 0))
    tk.Label(f, text="This instrument is not configured yet", bg=BG, fg=WARN,
             font=("Segoe UI", 15, "bold"), anchor="w").pack(fill="x")
    tk.Label(f, text=message, bg=BG, fg=FG, font=("Segoe UI", 10), anchor="w",
             justify="left", wraplength=640).pack(fill="x", expand=True, pady=(12, 0))
    r.update_idletasks()
    w = min(max(r.winfo_reqwidth(), 720), int(r.winfo_screenwidth() * 0.95))
    h = min(max(r.winfo_reqheight(), 360), int(r.winfo_screenheight() * 0.90))
    r.minsize(600, 320)
    r.geometry("%dx%d+%d+%d" % (w, h,
                                max(0, (r.winfo_screenwidth() - w) // 2),
                                max(0, (r.winfo_screenheight() - h) // 3)))
    r.mainloop()


def _self_cmd(extra=()):
    """Command that relaunches this program (resident agent mode by default)."""
    if getattr(sys, "frozen", False):
        return [sys.executable] + list(extra)
    return [sys.executable, os.path.abspath(__file__)] + list(extra)


def _spawn_resident_agent(cfg):
    """Start the resident agent detached, so the short-lived launcher can exit."""
    try:
        kwargs = {}
        if os.name == "nt":
            DETACHED_PROCESS = 0x00000008
            CREATE_NEW_PROCESS_GROUP = 0x00000200
            kwargs["creationflags"] = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
        subprocess.Popen(_self_cmd(),
                         cwd=os.path.dirname(os.path.abspath(sys.argv[0])) or None,
                         **kwargs)
        return True
    except Exception as exc:
        log_event(cfg, "resident_spawn_failed", error=str(exc))
        return False


def _launch_nis_directly(cfg, reason):
    """Fail-open path: open NIS-Elements without gating. The watcher still
    records the session and can close NIS if no one signs in, so the
    instrument is never bricked by a fault in the launcher."""
    try:
        exe = cfg.nis_executable
        if not os.path.isfile(exe):
            log_event(cfg, "nis_launch_failed", path=exe, error="not found",
                      via="launcher")
            _config_error_window(
                "NIS-Elements was not found at:\n\n%s\n\nFix [paths] "
                "nis_executable in config.ini." % exe, cfg.display_name)
            return 4
        launch_program(exe)
        log_event(cfg, "nis_launched", path=exe, via="launcher_failopen",
                  reason=reason)
        return 0
    except Exception as exc:
        log_event(cfg, "nis_launch_failed", error=str(exc), via="launcher")
        return 4


def launch_gate(cfg):
    """Runs when the (repointed) NIS-Elements desktop shortcut is clicked.

    It does NOT show any window and does NOT own the session. It signals the
    resident agent to open the sign-in window; the agent launches NIS-Elements
    only after a successful sign-in. If no healthy agent picks the request up
    within the wait window, it fails OPEN and opens NIS directly."""
    ensure_dir(cfg.local_root)
    log_event(cfg, "launcher_clicked", pid=os.getpid())

    # If NIS-Elements is already running, there is nothing to launch. The agent
    # and watcher are already handling whatever session state exists.
    if proc.is_running(cfg.gated_process_names) is True:
        log_event(cfg, "launcher_noop_nis_running")
        return 0

    requested_by = os.environ.get("USERNAME") or os.environ.get("USER") or ""
    write_launch_request(cfg, requested_by=requested_by)

    if not agent_is_alive(cfg, fresh_seconds=max(30, cfg.poll_seconds * 5)):
        _spawn_resident_agent(cfg)

    # Wait for a resident agent to take the request (it deletes the file when it
    # opens the sign-in window), or for NIS to come up. Do NOT fail open just
    # because sign-in is taking the person a while -- once the agent has the
    # request, the ball is theirs.
    deadline = time.time() + max(5, cfg.launcher_wait_seconds)
    while time.time() < deadline:
        if not os.path.isfile(launch_request_path(cfg)):
            return 0
        if proc.is_running(cfg.gated_process_names) is True:
            return 0
        time.sleep(0.4)

    log_event(cfg, "launch_request_unhandled")
    clear_launch_request(cfg)
    return _launch_nis_directly(cfg, "no_agent_consumed_request")


def main():
    launch_mode = "--launch" in sys.argv[1:]

    try:
        cfg = Config()
    except ConfigError as exc:
        _config_error_window(str(exc))
        return 2

    ensure_dir(cfg.local_root)
    missing = cfg.unset_placeholders()
    if missing:
        _config_error_window(
            "These settings in config.ini still contain placeholder text and must be "
            "filled in for this computer:\n\n  \u2022 " + "\n  \u2022 ".join(missing) +
            "\n\nconfig.ini is at:\n" + cfg.path, cfg.display_name)
        return 3

    if launch_mode:
        return launch_gate(cfg)

    # Resident agent. Only one may run at a time, or two sign-in windows fight.
    if agent_is_alive(cfg, fresh_seconds=max(30, cfg.poll_seconds * 5)):
        log_event(cfg, "agent_already_running", pid=os.getpid())
        return 0

    log_event(cfg, "agent_started", version=VERSION, pid=os.getpid())
    Agent(cfg).run()
    log_event(cfg, "agent_stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
