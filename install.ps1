<#
=======================================================================
 install.ps1  --  install ISG-NIS-Helper on this microscope PC

 Run it through install.bat (right-click, Run as administrator), or:
     powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1

 Everything printed here is also written to
     install-logs\<stamp>_install.txt
 and the script finishes by running ISG-NIS-Helper-Collect.ps1, which gathers
 the config, pre-scan, tasks, self-tests and machine details into one
 folder and one zip. Send that zip if a machine ever misbehaves.

 Registering the two scheduled tasks is the ONLY step that changes this
 machine. Everything before it is reversible by deleting a folder.
=======================================================================
#>

[CmdletBinding()]
param(
    [switch] $Force,      # install even if preflight reports problems
    [switch] $NoCollect,
    [switch] $NoRelaunch  # internal: set once we have elevated
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

function Resolve-LogRoot {
    <#  Somewhere we can actually write.

        The preferred spot is install-logs\ beside the program, but a program
        folder under C:\Program Files is not writable without elevation, so
        anything a normal user runs (the collector especially) would fail
        there. Fall back to ProgramData, which install.ps1 grants the Users
        group Modify on, and to TEMP after that. #>
    param([string]$Preferred)
    # Built defensively: if one of these environment variables is unset,
    # Join-Path fails and takes the whole array assignment with it, leaving
    # $candidates null and the loop never running.
    $candidates = New-Object System.Collections.ArrayList
    if ($Preferred)        { [void]$candidates.Add($Preferred) }
    if ($env:ProgramData)  { [void]$candidates.Add((Join-Path $env:ProgramData "ISG-NIS-Helper\install-logs")) }
    if ($env:TEMP)         { [void]$candidates.Add((Join-Path $env:TEMP "ISG-NIS-Helper-logs")) }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        # NOTE: `continue` inside a catch block does NOT continue the loop in
        # PowerShell -- it exits it. Use a flag instead. The same mistake is
        # why an unwritable folder used to be returned as if it were fine.
        $ok = $false
        try {
            # -PathType Container matters: a FILE sitting at this path makes
            # Test-Path true while being useless as a log folder.
            if (-not (Test-Path -LiteralPath $c -PathType Container)) {
                New-Item -ItemType Directory -Path $c -Force -ErrorAction Stop | Out-Null
            }
            $probe = Join-Path $c (".w" + [guid]::NewGuid().ToString("N").Substring(0, 6))
            Set-Content -LiteralPath $probe -Value "x" -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $ok = $true
        } catch {
            $ok = $false
        }
        if ($ok) { return $c }
    }
    return $Preferred
}

$script:ProductVersion = "unknown"
try {
    $vm = [regex]::Match((Get-Content -LiteralPath (Join-Path $here "isg_common.py") -Raw),
                         'VERSION\s*=\s*"([^"]+)"')
    if ($vm.Success) { $script:ProductVersion = $vm.Groups[1].Value }
} catch { }

$stamp  = Get-Date -Format "yyyy-MM-dd_HHmm"
$logDir = Resolve-LogRoot (Join-Path $here "install-logs")
$log = Join-Path $logDir ("{0}_install.txt" -f $stamp)

# Tee-Object has no -Encoding in Windows PowerShell 5.1 and writes UTF-16
# while Add-Content defaults to ANSI; mixing them makes a log that reads as
# "P y t h o n". Everything goes through Write-Log.
function Write-Log { param([string]$Text = "")
    try { Add-Content -LiteralPath $log -Value $Text -Encoding UTF8 } catch { }
}
function Note { param($t = "")
    Write-Host $t
    Write-Log $t
}
function Head { param($t)
    $line = "`r`n=== $t " + ("=" * [Math]::Max(0, 64 - $t.Length))
    Write-Host $line -ForegroundColor Cyan
    Write-Log $line
}
function Good { param($t) Write-Host ("  [ OK ]   " + $t) -ForegroundColor Green; Write-Log ("  [ OK ]   " + $t) }
function Warn { param($t) Write-Host ("  [ !! ]   " + $t) -ForegroundColor Yellow; Write-Log ("  [ !! ]   " + $t) }
function Stop-Install { param($t)
    Write-Host ""
    Write-Host "  INSTALL STOPPED: $t" -ForegroundColor Red
    Write-Host ("  Log: " + $log) -ForegroundColor DarkGray
    Write-Log ("INSTALL STOPPED: " + $t)
    exit 1
}
function Invoke-Logged {
    param([string]$Exe, [string[]]$Arguments)
    Write-Log ("`r`n> $Exe " + ($Arguments -join " "))
    # Native tools write ordinary output to stderr; with 2>&1 those arrive as
    # ErrorRecords and PowerShell renders them as red NativeCommandError
    # blocks, making healthy output look like failure. Flatten to strings.
    & $Exe @Arguments 2>&1 | ForEach-Object {
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
        Write-Host $line
        Write-Log $line
    }
    return $LASTEXITCODE
}

Set-Content -LiteralPath $log -Value "ISG-NIS-Helper install" -Encoding UTF8
Note "==================================================================="
Note " ISG-NIS-Helper install"
Note ("   when      : " + $stamp)
Note ("   computer  : " + $env:COMPUTERNAME)
Note ("   user      : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
Note ("   version   : " + $script:ProductVersion)
Note ("   folder    : " + $here)
Note ("   logs      : " + $logDir)
Note "==================================================================="

# ---------------------------------------------------------------- admin
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
    if ($Force)     { $argLine += " -Force" }
    if ($NoCollect) { $argLine += " -NoCollect" }
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
    Stop-Install "not running as Administrator. Right-click install.bat and choose 'Run as administrator'."
}

foreach ($exe in @("isg-nis-helper-agent.exe", "isg-nis-helper-svc.exe")) {
    if (-not (Test-Path -LiteralPath (Join-Path $here $exe))) {
        Stop-Install "$exe is not in this folder. Copy dist\ISG-NIS-Helper here, not the source folder."
    }
}
if (Test-Path -LiteralPath (Join-Path $here "build.ps1")) {
    Warn "this folder also contains the build scripts."
    Note "  That is harmless, but the installed folder is meant to be a copy of"
    Note "  dist\ISG-NIS-Helper, not the source tree. Build in a writable working"
    Note "  folder (e.g. the Desktop), then deploy the built dist\ISG-NIS-Helper here."
}

# ---------------------------------------------------------------- config
Head "Configuration"
$cfgPath = Join-Path $here "config.ini"
$genPath = Join-Path $here "config.generated.ini"

function Get-IniValues {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith(";") -or $l.StartsWith("#") -or $l.StartsWith("[")) { continue }
        $eq = $l.IndexOf("=")
        if ($eq -lt 1) { continue }
        $map[$l.Substring(0, $eq).Trim()] = $l.Substring($eq + 1).Trim()
    }
    return $map
}

$needsConfig = $true
if (Test-Path -LiteralPath $cfgPath) {
    $needsConfig = (Get-Content -LiteralPath $cfgPath -Raw) -match '<<<SET_ME'
}

if ($needsConfig) {
    if (Test-Path -LiteralPath $genPath) {
        Note "  config.ini is missing or still has placeholders, and a"
        Note "  config.generated.ini from the pre-scan is sitting here."
        Note ""
        $answer = Read-Host "  Use the generated one? [Y/N]"
        if ($answer -match '^[Yy]') {
            $old = Get-IniValues $cfgPath
            if (Test-Path -LiteralPath $cfgPath) {
                Copy-Item -LiteralPath $cfgPath -Destination (Join-Path $logDir ("{0}_config.ini.backup" -f $stamp)) -Force
                Note "  previous config.ini saved into install-logs"
            }
            $genText = Get-Content -LiteralPath $genPath -Raw

            # Carry over anything you already filled in by hand that the
            # generated file leaves blank or unset. Without this, adopting the
            # generated config silently discards your edits -- which is exactly
            # what happened when a hand-set network_root was replaced by a
            # placeholder and the install came up non-functional.
            $carried = @()
            foreach ($key in $old.Keys) {
                $mine = $old[$key]
                if (-not $mine -or $mine -match '<<<SET_ME') { continue }
                # [ \t]* not \s*: \s matches newlines, so a greedy \s* after the
                # "=" runs past the end of an empty value into the NEXT line,
                # and the merge silently decides the generated file already
                # had a value. Spaces and tabs only.
                $pattern = '(?m)^([ \t]*' + [regex]::Escape($key) + '[ \t]*=)[ \t]*(.*)$'
                $m = [regex]::Match($genText, $pattern)
                if (-not $m.Success) { continue }
                $theirs = $m.Groups[2].Value.Trim()
                if ($theirs -and $theirs -notmatch '<<<SET_ME') { continue }
                $genText = [regex]::Replace($genText, $pattern, ('${1} ' + $mine.Replace('$', '$$$$')), 1)
                $carried += $key
            }
            # Write UTF-8 WITHOUT a BOM. PowerShell 5.1's -Encoding UTF8 prepends a
            # byte-order mark, and Python configparser then fails on line 1 with
            # "File contains no section headers". WriteAllText + UTF8Encoding($false)
            # avoids it; TrimStart drops any BOM carried in from the source.
            [System.IO.File]::WriteAllText($cfgPath, $genText.TrimStart([char]0xFEFF), (New-Object System.Text.UTF8Encoding($false)))
            Good "config.generated.ini adopted as config.ini"
            if ($carried.Count) {
                Good ("kept your existing values for: " + ($carried -join ", "))
            }
        } else {
            Warn "declined; continuing with the existing config.ini"
        }
    } else {
        Note "  config.ini still has placeholders and there is no"
        Note "  config.generated.ini here."
        Note ""
        Note "  Run the pre-scan first:   Run-PreScan.bat"
        Stop-Install "no usable configuration"
    }
}

# ---- the user list ------------------------------------------------------
$usersCsv = Join-Path $here "users.csv"
$usersTpl = Join-Path $here "users_template.csv"
if (-not (Test-Path -LiteralPath $usersCsv)) {
    if (Test-Path -LiteralPath $usersTpl) {
        Copy-Item -LiteralPath $usersTpl -Destination $usersCsv -Force
        Warn "created an EMPTY users.csv from the template."
        Note ("  " + $usersCsv)
        Note "  Nobody can sign in until you add people to it."
    } else {
        Warn "no users.csv and no template to create one from."
    }
} else {
    Good "users.csv is present"
}

# ---------------------------------------------------------------- preflight
Head "Preflight"
$pf = Join-Path $here "ISG-NIS-Helper-Preflight.ps1"
$pfOut = & $pf -ConfigPath $cfgPath 2>&1 6>&1
$pfText = ($pfOut | Out-String)
foreach ($o in $pfOut) {
    $line = if ($o -is [System.Management.Automation.ErrorRecord]) { $o.ToString() } else { [string]$o }
    Write-Host $line
    Write-Log $line
}

$pfProblems = 0
if ($pfText -match '(\d+) problem\(s\)') { $pfProblems = [int]$Matches[1] }

if ($pfProblems -gt 0) {
    Note ""
    Warn "Preflight found $pfProblems problem(s)."
    Note "  Fixing them now is much cheaper than discovering them at the microscope."
    if (-not $Force) {
        Note ""
        $answer = Read-Host "  Install anyway? [Y/N]"
        if ($answer -notmatch '^[Yy]') {
            Stop-Install "stopped by the operator. Nothing was changed."
        }
    }
    Warn "continuing despite preflight problems (operator's choice)"
}

# ---------------------------------------------------------------- store
Head "Local log store"
$localRoot = "C:\ProgramData\ISG-NIS-Helper"
foreach ($line in (Get-Content -LiteralPath $cfgPath)) {
    if ($line -match '^\s*local_root\s*=\s*(.+?)\s*$') { $localRoot = $Matches[1] }
}
if (-not (Test-Path -LiteralPath $localRoot)) {
    New-Item -ItemType Directory -Path $localRoot -Force | Out-Null
}
# Grant the Users group Modify, by SID so it works on any language of Windows.
# A copy of the program inside the log store is stray -- and granting the
# Users group Modify across it would hand everyone write access to the
# executables. Refuse to do that silently.
$strayProgram = @(Get-ChildItem -LiteralPath $localRoot -Filter "*.ps1" -ErrorAction SilentlyContinue)
$strayProgram += @(Get-ChildItem -LiteralPath $localRoot -Filter "isg_*.py" -ErrorAction SilentlyContinue)
if ($strayProgram.Count) {
    Warn "$localRoot contains a stray copy of the program ($($strayProgram.Count) files)."
    Note "  That folder is the LOG STORE. Delete everything in it except"
    Note "  session.json, health.json, logs\ and pins\, then re-run this."
    Note "  Granting Modify across a copy of the executables is not something"
    Note "  this installer will do quietly."
    Note ""
    $answer = Read-Host "  Delete the stray program files now? [Y/N]"
    if ($answer -match '^[Yy]') {
        $keep = @("logs", "pins", "buffers", "manifests", "pending_sync", "install-logs",
                  "session.json", "health.json", "SAFEMODE.json", "agent.json",
                  "unauth.json", "handoff.json", "launch_request.json", "shortcuts.json")
        $removed = 0
        foreach ($item in (Get-ChildItem -LiteralPath $localRoot -Force -ErrorAction SilentlyContinue)) {
            if ($keep -contains $item.Name) { continue }
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $removed++
            } catch {
                Warn ("could not remove " + $item.Name + ": " + $_.Exception.Message)
            }
        }
        Good ("removed $removed stray item(s); logs and state kept")
    } else {
        Warn "left in place. Nothing else will use them, but they will confuse you later."
    }
}

Invoke-Logged "icacls.exe" @($localRoot, "/grant", "*S-1-5-32-545:(OI)(CI)M", "/T") | Out-Null
Good "ready: $localRoot"

# ---------------------------------------------------------------- tasks
Head "Scheduled tasks"
$agent = Join-Path $here "isg-nis-helper-agent.exe"
$watch = Join-Path $here "isg-nis-helper-svc.exe"

foreach ($t in @(
    @{ Name = "ISG-NIS-Helper-Svc"; Xml = "tasks\ISG-NIS-Helper-Svc.xml"; Token = "__WATCH_EXE__"; Exe = $watch },
    @{ Name = "ISG-NIS-Helper-Agent"; Xml = "tasks\ISG-NIS-Helper-Agent.xml"; Token = "__AGENT_EXE__"; Exe = $agent }
)) {
    $srcXml = Join-Path $here $t.Xml
    if (-not (Test-Path -LiteralPath $srcXml)) { Stop-Install ("missing " + $t.Xml) }
    $xml = (Get-Content -LiteralPath $srcXml -Raw).Replace($t.Token, $t.Exe).Replace("__APP_DIR__", $here)
    $tmp = Join-Path $env:TEMP ("sg-" + $t.Name + ".xml")
    Set-Content -LiteralPath $tmp -Value $xml -Encoding Unicode

    $code = Invoke-Logged "schtasks.exe" @("/Create", "/TN", $t.Name, "/XML", $tmp, "/F")
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { Stop-Install ("could not register " + $t.Name) }
    Good ("registered " + $t.Name)
}

foreach ($n in @("ISG-NIS-Helper-Svc", "ISG-NIS-Helper-Agent")) {
    Invoke-Logged "schtasks.exe" @("/Run", "/TN", $n) | Out-Null
}
Good "both started"

# ---------------------------------------------------------------- shortcuts
# Repoint every NIS-Elements shortcut (desktop, Start menu, taskbar, all
# users) so clicking it runs the helper with --launch. The helper shows the
# sign-in window and only then launches NIS-Elements. The original target,
# arguments and icon are saved to shortcuts.json so the uninstaller can put
# each shortcut back exactly as it was.
Head "NIS-Elements shortcuts"

$nisExe = ""
foreach ($line in (Get-Content -LiteralPath $cfgPath)) {
    if ($line -match '^\s*nis_executable\s*=\s*(.+?)\s*$') { $nisExe = $Matches[1] }
}
if (-not $nisExe -or $nisExe -match '<<<') {
    Warn "nis_executable is not set in config.ini; leaving shortcuts untouched."
} else {
    $nisLeaf     = Split-Path $nisExe -Leaf
    $manifest    = Join-Path $localRoot "shortcuts.json"
    $already     = @{}
    if (Test-Path -LiteralPath $manifest) {
        try {
            foreach ($e in (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json)) {
                if ($e.LnkPath) { $already[$e.LnkPath.ToLower()] = $true }
            }
        } catch { }
    }

    # Search roots: all users + every profile's desktop, start menu and taskbar.
    $roots = New-Object System.Collections.Generic.List[string]
    $pub = $env:PUBLIC; if (-not $pub) { $pub = "C:\Users\Public" }
    [void]$roots.Add((Join-Path $pub "Desktop"))
    [void]$roots.Add((Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"))
    $usersDir = Join-Path $env:SystemDrive "Users"
    if (Test-Path -LiteralPath $usersDir) {
        foreach ($prof in (Get-ChildItem -LiteralPath $usersDir -Directory -ErrorAction SilentlyContinue)) {
            [void]$roots.Add((Join-Path $prof.FullName "Desktop"))
            [void]$roots.Add((Join-Path $prof.FullName "AppData\Roaming\Microsoft\Windows\Start Menu\Programs"))
            [void]$roots.Add((Join-Path $prof.FullName "AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"))
        }
    }

    $sh = New-Object -ComObject WScript.Shell
    $records   = @()
    $repointed = 0
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $lnks = @(Get-ChildItem -LiteralPath $root -Filter *.lnk -Recurse -ErrorAction SilentlyContinue)
        foreach ($lnk in $lnks) {
            $target = ""
            try {
                $s = $sh.CreateShortcut($lnk.FullName)
                $target = $s.TargetPath
            } catch { continue }
            if (-not $target) { continue }

            $isNis = ($target -ieq $nisExe) -or ((Split-Path $target -Leaf) -ieq $nisLeaf)
            $isOurs = ($target -ieq $agent)
            if ($isOurs) { continue }           # already repointed on a prior run
            if (-not $isNis) { continue }
            if ($already.ContainsKey($lnk.FullName.ToLower())) { continue }

            # Preserve the Elements icon so the shortcut still looks like NIS.
            $icon = $s.IconLocation
            if (-not $icon -or $icon -eq ",0" -or $icon -eq "") { $icon = ($target + ",0") }

            $records += [pscustomobject]@{
                LnkPath          = $lnk.FullName
                TargetPath       = $target
                Arguments        = $s.Arguments
                WorkingDirectory = $s.WorkingDirectory
                IconLocation     = $s.IconLocation
                Description      = $s.Description
            }
            try {
                $s.TargetPath       = $agent
                $s.Arguments        = "--launch"
                $s.WorkingDirectory = $here
                $s.IconLocation     = $icon
                if (-not $s.Description) { $s.Description = "NIS-Elements" }
                $s.Save()
                $repointed++
                Good ("repointed " + $lnk.FullName)
            } catch {
                Warn ("could not repoint " + $lnk.FullName + ": " + $_.Exception.Message)
            }
        }
    }

    if ($records.Count) {
        $existing = @()
        if (Test-Path -LiteralPath $manifest) {
            try { $existing = @(Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json) } catch { $existing = @() }
        }
        $all = @($existing) + @($records)
        Set-Content -LiteralPath $manifest -Value ($all | ConvertTo-Json -Depth 4) -Encoding UTF8
    }
    if ($repointed -eq 0) {
        Note "  No NIS-Elements shortcuts matched. Users who start NIS by its"
        Note "  own executable are still caught by the background service."
    } else {
        Good ("$repointed shortcut(s) now open the sign-in window first")
        Note "  Pinned taskbar icons refresh after the next sign-out / sign-in."
    }
}

# ---------------------------------------------------------------- collect
if (-not $NoCollect) {
    Head "Collecting the installation record"
    & (Join-Path $here "ISG-NIS-Helper-Collect.ps1") -OutRoot $logDir
}

# ---------------------------------------------------------------- done
Note ""
Note "==================================================================="
Note "  Installed."
Note ""
Note ("  Install log : " + $log)
Note ("  Diagnostics : " + $logDir + "  (a dated folder and a zip)")
Note ""
Note "  If anything ever looks wrong on this or another machine, run"
Note "  Run-Collect.bat and send the zip. Start with 00-SUMMARY.md."
Note ""
Note "  CHECK THESE FOUR THINGS BEFORE YOU TRUST IT:"
Note "    1. Click the NIS-Elements desktop icon - the sign-in window opens"
Note "       FIRST; sign in and NIS-Elements launches; close NIS and a"
Note ("       session file appears under " + $localRoot + "\logs")
Note "    2. Click the icon and cancel the sign-in - NIS does NOT open"
Note "    3. Start NIS by its own .exe (bypassing the icon) and do NOT sign"
Note "       in - the sign-in window comes to the front with a countdown and"
Note "       NIS closes after the grace period (unauthorized_launch_closed"
Note "       appears in the events file)"
Note "    4. Run a long acquisition overnight on a throwaway sample and"
Note "       confirm in the morning that it was untouched"
Note "==================================================================="
Note ""
exit 0
