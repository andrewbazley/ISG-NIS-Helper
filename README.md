# ISG-NIS-Helper

A usage recorder for shared microscope PCs running NIS-Elements.

Clicking the NIS-Elements icon opens a sign-in window first; NIS-Elements itself launches only after someone signs in with their name and a PIN. The session is recorded from sign-in until NIS-Elements closes, along with an index of every data file created, modified or deleted during it. If NIS-Elements is started another way — directly from its executable — while nobody is signed in, it is closed after a grace period and the attempt is logged.

**The purpose is accountability, not security.** Anyone determined to defeat it can. What it achieves is that every period of instrument use has a name attached to it, which turns an informal expectation into an enforceable policy: *whoever is signed in is responsible for the instrument for the duration of their session, including for anyone they allow to operate it.*

## Guides

| | |
|---|---|
| **[docs/Installation](docs/Installation.md)** | Unzip, pre-scan, install. Rebuilding is an appendix |
| **[docs/Usage](docs/Usage.md)** | Managing users, reading the logs, changing settings, what it cannot do |
| **[docs/Troubleshooting](docs/Troubleshooting.md)** | Symptoms and fixes, how it fails safe, the diagnostic bundle |

Each is also in the same folder as `.docx` and `.pdf`.

## Design commitments

These are guarantees, not side effects. They are what makes ISG-NIS-Helper safe to leave running on an instrument, and the automated self-test asserts the first two.

1. **A signed-in session is never interrupted.** No timeout, no idle check, no automatic logout. If NIS-Elements is open, the session is open — for ten minutes or for four days.
2. **Microscope data is never touched.** The snapshot engine calls `scandir` and `stat` and nothing else. It never opens, reads, moves, copies, renames, locks or deletes a file.
3. **The sign-in is a launch gate, and enforcement happens only at launch.** The desktop shortcut opens the sign-in window before NIS-Elements starts. The only process ISG-NIS-Helper will close is a copy of NIS-Elements started *another* way while no session was open, after a grace period. If the gate itself ever fails, it opens NIS-Elements anyway rather than blocking the instrument — the recorder and the backstop still apply.
4. **Local disk is the source of truth.** The network share is a mirror. If it is unreachable, sessions log locally and copies flush later.
5. **It never acts on a guess.** If the process list cannot be trusted, if its own state store will not read and write, if the NIS executable has vanished, if the sign-in program is dead, or if Windows has just updated, it declines to close anything and records why.

## The two programs

| | `isg-nis-helper-agent.exe` | `isg-nis-helper-svc.exe` |
|---|---|---|
| **Runs as** | the logged-in user, at logon | SYSTEM, at boot |
| **Has a window** | yes: sign-in, and the corner badge | no |
| **Owns** | sessions, snapshots, logs, the share | enforcement only |
| **Restarts if killed** | yes, by Task Scheduler | yes, by Task Scheduler |

Split because a SYSTEM process cannot draw on the user's desktop. They coordinate through `C:\ProgramData\ISG-NIS-Helper\session.json`.

**How launching works.** The NIS-Elements shortcuts on the desktop, Start menu and taskbar are repointed by the installer to run `isg-nis-helper-agent.exe --launch` while keeping the NIS-Elements name and icon. That short-lived launcher does not own a session — it signals the resident agent, which opens the sign-in window and, on a successful sign-in, starts NIS-Elements itself. The SYSTEM service is the backstop: it stays running from boot so that if someone bypasses the shortcut and starts NIS-Elements directly, the launch is still noticed, the sign-in window is raised, and NIS is closed after the grace period if no one signs in. The installer saves each original shortcut and the uninstaller puts them all back.

**Everything lives in two folders.** `C:\ISG-NIS-Helper` holds the program, its config, its user list and these guides; `C:\ProgramData\ISG-NIS-Helper` holds everything it writes. No network share, no user profile, no registry.

Nothing a user sees carries the name "ISG-NIS-Helper" — the window is titled with `[instrument] display_name`, default *Microscope Access Log*.

## Before you trust it

```
python selftest.py                   103 checks, no microscope needed
powershell -File selftest-prescan.ps1     20 checks on path handling
powershell -File selftest-nisdetect.ps1   25 checks on NIS detection
```

Neither covers the sign-in window, which needs a desktop: run `python isg_agent.py` once and confirm it draws.

Then the four checks at the instrument in the Installation guide — especially the overnight one.

## When something looks wrong

Run **`Run-Collect.bat`** and send the zip. `00-SUMMARY.md` inside is written to be pasted whole. PINs are redacted; no image data is included.

## Version

ISG-NIS-Helper 3.0.4 — Python 3.8+, Windows 10 and 11 (7 SP1 if built with Python 3.8).
Dependencies: `psutil` (optional; falls back to built-in `tasklist`).
