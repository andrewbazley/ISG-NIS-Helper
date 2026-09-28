<#
=======================================================================
 uninstall.ps1  --  remove ISG-NIS-Helper completely

 Run through uninstall.bat (right-click, Run as administrator), or:
     powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1

 Removes, in order:
   * both scheduled tasks
   * the two running programs
   * C:\ProgramData\ISG-NIS-Helper      (state; logs only if you say so)
   * the TEMP build workspace
   * the program folder itself, including this script

 Your session logs are the whole point of ISG-NIS-Helper, so it will not
 delete them without being told to, and it offers to copy them, your
 config and your user list somewhere safe first.

 Switches, for when you know exactly what you want:
     -KeepLogs      never touch the logs, do not ask
     -RemoveLogs    delete them, do not ask
     -KeepProgram   leave the program folder in place
=======================================================================
#>

[CmdletBinding()]
param(
    [switch] $KeepLogs,
    [switch] $RemoveLogs,
    [switch] $KeepProgram,
    [switch] $NoRelaunch   # internal: set once we have elevated
)

$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Say  { param($t = "") Write-Host $t }
function Good { param($t) Write-Host ("  [ OK ]   " + $t) -ForegroundColor Green }
function Warn { param($t) Write-Host ("  [ !! ]   " + $t) -ForegroundColor Yellow }
function Head { param($t) Write-Host ""; Write-Host ("-- " + $t) -ForegroundColor Cyan }

Say ""
Say "  ISG-NIS-Helper uninstall"
Say ("  program folder: " + $here)

$isAdmin = $false
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

if (-not $isAdmin -and -not $NoRelaunch) {
    # Ask for elevation rather than just refusing. A PowerShell window opened
    # in C:\WINDOWS\system32 looks elevated and very often is not, and
    # "remember to run as administrator" is a step that keeps getting missed.
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }
    Write-Host ""
    Write-Host "  Not running as Administrator. Requesting elevation..." -ForegroundColor Yellow
    Write-Host "  Approve the prompt; a new window opens and stays open." -ForegroundColor DarkGray
    $argLine = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "' + $self + '" -NoRelaunch'
    if ($KeepLogs)    { $argLine += " -KeepLogs" }
    if ($RemoveLogs)  { $argLine += " -RemoveLogs" }
    if ($KeepProgram) { $argLine += " -KeepProgram" }
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argLine | Out-Null
        Write-Host "  Continue in the new window." -ForegroundColor Green
        Write-Host ""
        exit 0
    } catch {
        Write-Host ""
        Write-Host "  Elevation was declined or failed." -ForegroundColor Red
    }
}

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  Must run as Administrator. Right-click uninstall.bat and" -ForegroundColor Red
    Write-Host "  choose 'Run as administrator'." -ForegroundColor Red
    Write-Host ""
    exit 1
}

# ---------------------------------------------------------------- inventory
$localRoot = "C:\ProgramData\ISG-NIS-Helper"
$cfg = Join-Path $here "config.ini"
if (Test-Path -LiteralPath $cfg) {
    foreach ($line in (Get-Content -LiteralPath $cfg)) {
        if ($line -match '^\s*local_root\s*=\s*(.+?)\s*$') { $localRoot = $Matches[1] }
    }
}
$tempBuild = Join-Path $env:TEMP "ISG-NIS-Helper-build"
$logsDir   = Join-Path $localRoot "logs"

$sessionCount = 0
if (Test-Path -LiteralPath $logsDir) {
    $sessionCount = @(Get-ChildItem -LiteralPath $logsDir -Recurse -Filter "*.csv" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '_files\.csv$' -and $_.Name -ne 'index.csv' }).Count
}

Head "What is here"
foreach ($t in @("ISG-NIS-Helper-Agent", "ISG-NIS-Helper-Svc")) {
    $found = $false
    try { & schtasks /query /TN $t 2>&1 | Out-Null; $found = ($LASTEXITCODE -eq 0) } catch { }
    Say ("    task {0,-18} {1}" -f $t, $(if ($found) { "registered" } else { "not present" }))
}
Say ("    state folder       {0}" -f $(if (Test-Path -LiteralPath $localRoot) { $localRoot } else { "not present" }))
Say ("    recorded sessions  {0}" -f $sessionCount)
Say ("    build workspace    {0}" -f $(if (Test-Path -LiteralPath $tempBuild) { $tempBuild } else { "not present" }))

# ---------------------------------------------------------------- decide
$deleteLogs = $false
if ($RemoveLogs) { $deleteLogs = $true }
elseif ($KeepLogs) { $deleteLogs = $false }
elseif ($sessionCount -gt 0) {
    Head "Your logs"
    Say "  $sessionCount recorded sessions are in $logsDir."
    Say "  These are the record of who used this instrument. Once deleted they"
    Say "  are gone."
    Say ""
    $a = Read-Host "  Delete the logs as well? [y/N]"
    $deleteLogs = ($a -match '^[Yy]')
}

if ($sessionCount -gt 0 -or (Test-Path -LiteralPath $cfg)) {
    Say ""
    $a = Read-Host "  Copy the logs, config.ini and users.csv somewhere first? [Y/n]"
    if ($a -notmatch '^[Nn]') {
        $dest = Join-Path ([Environment]::GetFolderPath("Desktop")) `
                          ("ISG-NIS-Helper-saved-" + (Get-Date -Format "yyyy-MM-dd_HHmm"))
        try {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            if (Test-Path -LiteralPath $logsDir) {
                Copy-Item -LiteralPath $logsDir -Destination $dest -Recurse -Force
            }
            foreach ($f in @("config.ini", "users.csv")) {
                $src = Join-Path $here $f
                if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dest -Force }
            }
            Good ("saved to " + $dest)
        } catch {
            Warn ("could not save: " + $_.Exception.Message)
            $a2 = Read-Host "  Carry on with the uninstall anyway? [y/N]"
            if ($a2 -notmatch '^[Yy]') { Say "  Stopped. Nothing was changed."; exit 1 }
        }
    }
}

# ---------------------------------------------------------------- tasks
Head "Scheduled tasks"
foreach ($t in @("ISG-NIS-Helper-Agent", "ISG-NIS-Helper-Svc")) {
    & schtasks /End /TN $t 2>&1 | Out-Null
    & schtasks /Delete /TN $t /F 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Good "removed $t" } else { Say "    $t was not registered" }
}

Head "Running programs"
foreach ($p in @("isg-nis-helper-agent", "isg-nis-helper-svc")) {
    $procs = @(Get-Process -Name $p -ErrorAction SilentlyContinue)
    foreach ($proc in $procs) {
        try { $proc.Kill(); Good "stopped $p (pid $($proc.Id))" } catch { Warn "could not stop $p" }
    }
    if (-not $procs.Count) { Say "    $p was not running" }
}
Start-Sleep -Seconds 1

# ---------------------------------------------------------------- shortcuts
# Put every repointed NIS-Elements shortcut back exactly as it was. Do this
# before the state folder (which holds shortcuts.json) is removed.
Head "NIS-Elements shortcuts"
$manifest = Join-Path $localRoot "shortcuts.json"
if (Test-Path -LiteralPath $manifest) {
    $records = @()
    try { $records = @(Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json) } catch { $records = @() }
    if ($records.Count) {
        $sh = New-Object -ComObject WScript.Shell
        $restored = 0
        foreach ($r in $records) {
            if (-not $r.LnkPath -or -not (Test-Path -LiteralPath $r.LnkPath)) { continue }
            try {
                $s = $sh.CreateShortcut($r.LnkPath)
                $s.TargetPath       = $r.TargetPath
                $s.Arguments        = $r.Arguments
                $s.WorkingDirectory = $r.WorkingDirectory
                $s.IconLocation     = $r.IconLocation
                $s.Description       = $r.Description
                $s.Save()
                $restored++
                Good ("restored " + $r.LnkPath)
            } catch {
                Warn ("could not restore " + $r.LnkPath + ": " + $_.Exception.Message)
            }
        }
        Good ("$restored NIS-Elements shortcut(s) put back")
        Say  "    Pinned taskbar icons refresh after the next sign-out / sign-in."
    } else {
        Say "    no shortcuts were repointed; nothing to restore"
    }
} else {
    Say "    no shortcut record found; nothing to restore"
}

# ---------------------------------------------------------------- state
Head "State and logs"
if (Test-Path -LiteralPath $localRoot) {
    if ($deleteLogs) {
        try {
            Remove-Item -LiteralPath $localRoot -Recurse -Force -ErrorAction Stop
            Good "removed $localRoot entirely"
        } catch { Warn ("could not remove " + $localRoot + ": " + $_.Exception.Message) }
    } else {
        $removed = 0
        foreach ($item in (Get-ChildItem -LiteralPath $localRoot -Force -ErrorAction SilentlyContinue)) {
            if ($item.Name -eq "logs") { continue }
            try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop; $removed++ } catch { }
        }
        Good "removed $removed item(s); kept $logsDir"
    }
} else { Say "    nothing to remove" }

if (Test-Path -LiteralPath $tempBuild) {
    try {
        Remove-Item -LiteralPath $tempBuild -Recurse -Force -ErrorAction Stop
        Good "removed the TEMP build workspace"
    } catch { Warn "could not remove $tempBuild" }
}

# ---------------------------------------------------------------- program
Head "Program folder"
if ($KeepProgram) {
    Say "    kept, as asked"
} else {
    # This script lives in the folder it is deleting, so the final removal is
    # handed to a detached shell that waits for PowerShell to exit first.
    $cmd = 'timeout /t 3 /nobreak >nul & rmdir /s /q "' + $here + '"'
    try {
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -WindowStyle Hidden | Out-Null
        Good "scheduled for removal a few seconds after this window closes"
        Say  ("    " + $here)
    } catch {
        Warn "could not schedule removal; delete the folder by hand:"
        Say  ("    " + $here)
    }
}

Say ""
Say "==================================================================="
Say "  ISG-NIS-Helper removed."
if (-not $deleteLogs -and $sessionCount -gt 0) {
    Say ""
    Say "  Your $sessionCount session records were kept:"
    Say ("    " + $logsDir)
    Say "  Delete that folder by hand when you no longer need them."
}
Say "==================================================================="
Say ""
