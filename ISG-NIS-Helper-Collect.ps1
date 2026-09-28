<#
=======================================================================
 ISG-NIS-Helper-Collect.ps1
 -----------------------------------------------------------------
 Gathers everything anyone would need to diagnose this machine into one
 folder and one zip, and writes a SUMMARY.md designed to be pasted
 straight into a conversation.

 install.bat runs this automatically at the end. Run it by hand any time
 something looks wrong:

     powershell -NoProfile -ExecutionPolicy Bypass -File ISG-NIS-Helper-Collect.ps1

 It collects: the machine and OS, the ISG-NIS-Helper version and file hashes,
 config.ini and config.generated.ini, the pre-scan report, the registered
 scheduled tasks, a preflight run, all three self-tests, the health and
 safe-mode state, the ProgramData tree, and the most recent events.

 PINS ARE REDACTED. The PIN column of users.csv and master_pin in any
 config are replaced with ****, so the bundle is safe to send. Nothing
 else is altered and nothing is deleted.
=======================================================================
#>

[CmdletBinding()]
param(
    [string] $OutRoot = "",
    [int]    $EventLines = 400,
    [switch] $NoTests
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$pc    = $env:COMPUTERNAME
if (-not $pc) { $pc = [System.Net.Dns]::GetHostName() }
if (-not $pc) { $pc = "unknown-pc" }
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

if (-not $OutRoot) { $OutRoot = Resolve-LogRoot (Join-Path $here "install-logs") }
$dir = Join-Path $OutRoot ("{0}_{1}" -f $stamp, $pc)
New-Item -ItemType Directory -Path $dir -Force | Out-Null

function Put { param([string]$Name, $Content)
    $p = Join-Path $dir $Name
    if ($null -eq $Content) { $Content = "(nothing)" }
    $Content | Out-String | Set-Content -LiteralPath $p -Encoding UTF8
    return $p
}
function Run { param([string]$Name, [scriptblock]$Block)
    Write-Host ("  collecting " + $Name) -ForegroundColor DarkGray
    $out = $null
    # 6>&1 as well as 2>&1: Write-Host writes to the INFORMATION stream, so
    # 2>&1 alone captures none of it. Preflight and the self-tests print
    # almost everything with Write-Host, so without this their files come
    # back nearly empty and their verdicts unreadable.
    try { $out = & $Block 2>&1 6>&1 } catch { $out = "ERROR: $($_.Exception.Message)" }
    Put $Name $out | Out-Null
    return $out
}
function Redact { param([string]$Text)
    if (-not $Text) { return $Text }
    # master_pin = 123456   ->   master_pin = ****
    $Text = [regex]::Replace($Text, '(?im)^(\s*master_pin\s*=\s*).*$', '${1}**** (redacted)')
    return $Text
}
function RedactUsers { param([string]$Path)
    # Replace the pin column with ****, keeping every other column intact.
    try {
        $rows = @(Import-Csv -LiteralPath $Path)
        if ($rows.Count -eq 0) { return "(users.csv has a header only)" }
        foreach ($r in $rows) {
            if ($r.PSObject.Properties.Name -contains 'pin') {
                $r.pin = if ($r.pin) { '****' } else { '(blank)' }
            }
        }
        return ($rows | ConvertTo-Csv -NoTypeInformation)
    } catch {
        return "could not parse users.csv: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "  ISG-NIS-Helper diagnostic collection" -ForegroundColor White
Write-Host ("  -> " + $dir) -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------- machine
$os = $null
try { $os = Get-CimInstance Win32_OperatingSystem } catch { }

$elevated = $null
try {
    $elevated = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

$tz = "unknown"
try { $tz = (Get-TimeZone).Id } catch { }

$machine = [ordered]@{
    Collected    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    CollectedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    ComputerName = $pc
    OS           = if ($os) { $os.Caption } else { "unknown" }
    OSVersion    = if ($os) { $os.Version } else { "unknown" }
    OSBuild      = if ($os) { $os.BuildNumber } else { "unknown" }
    LastBoot     = if ($os) { $os.LastBootUpTime.ToString("yyyy-MM-dd HH:mm") } else { "unknown" }
    User         = "$env:USERDOMAIN\$env:USERNAME"
    Elevated     = $elevated
    PSVersion    = $PSVersionTable.PSVersion.ToString()
    InstallDir    = $here
    TimeZone     = $tz
}
Put "01-machine.txt" ($machine.GetEnumerator() | ForEach-Object { "{0,-14} {1}" -f $_.Key, $_.Value }) | Out-Null

Run "02-windows-updates.txt" {
    "--- most recent hotfixes ---"
    Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending |
        Select-Object -First 25 HotFixID, Description, InstalledOn | Format-Table -AutoSize | Out-String
} | Out-Null

Run "03-time-sync.txt" { & w32tm /query /status 2>&1; "---"; & w32tm /query /source 2>&1 } | Out-Null

# ---------------------------------------------------------------- files
Run "04-isg-nis-helper-files.txt" {
    "--- program folder ---"
    Get-ChildItem -LiteralPath $here -File -ErrorAction SilentlyContinue |
        Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize | Out-String
    "--- hashes of the executables and scripts ---"
    Get-ChildItem -LiteralPath $here -File -Include *.exe, *.ps1, *.bat, *.py -Recurse -Depth 1 -ErrorAction SilentlyContinue |
        ForEach-Object {
            $h = "?"
            try { $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.Substring(0, 16) } catch { }
            "{0}  {1,10}  {2}" -f $h, $_.Length, $_.Name
        }
} | Out-Null

# ---------------------------------------------------------------- config
foreach ($f in @("config.ini", "config.generated.ini")) {
    $src = Join-Path $here $f
    if (Test-Path -LiteralPath $src) {
        Put ("05-" + $f + ".txt") (Redact (Get-Content -LiteralPath $src -Raw)) | Out-Null
        Write-Host ("  collecting " + $f + " (master_pin redacted)") -ForegroundColor DarkGray
    }
}

# read config to find the share and the local root
$netRoot = ""; $localRoot = "C:\ProgramData\ISG-NIS-Helper"
try {
    foreach ($line in (Get-Content -LiteralPath (Join-Path $here "config.ini") -ErrorAction Stop)) {
        if ($line -match '^\s*network_root\s*=\s*(.+)$') { $netRoot = $Matches[1].Trim() }
        if ($line -match '^\s*local_root\s*=\s*(.+)$')   { $localRoot = $Matches[1].Trim() }
    }
} catch { }

# ---------------------------------------------------------------- users
if ($netRoot -and (Test-Path -LiteralPath (Join-Path $netRoot "users.csv"))) {
    Put "06-users-redacted.csv" (RedactUsers (Join-Path $netRoot "users.csv")) | Out-Null
    Write-Host "  collecting users.csv (PINs redacted)" -ForegroundColor DarkGray
} else {
    Put "06-users-redacted.csv" "users.csv not found under network_root ($netRoot)" | Out-Null
}

# ---------------------------------------------------------------- prescan
$copied = 0
foreach ($pat in @("ISG-NIS-Helper-PreScan_*.txt", "prescan.json")) {
    foreach ($f in (Get-ChildItem -LiteralPath $here -Filter $pat -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dir ("07-" + $f.Name)) -Force
        $copied++
    }
}
if (-not $copied) { Put "07-prescan-missing.txt" "No pre-scan output found in $here" | Out-Null }

# ---------------------------------------------------------------- tasks
Run "08-scheduled-tasks.txt" {
    foreach ($t in @("ISG-NIS-Helper-Agent", "ISG-NIS-Helper-Svc")) {
        "===== $t ====="
        & schtasks /query /TN $t /V /FO LIST 2>&1
        ""
    }
} | Out-Null

Run "09-running-processes.txt" {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'isg-nis-helper|nis' } |
        Select-Object Id, ProcessName, StartTime, Path | Format-Table -AutoSize | Out-String
} | Out-Null

# ---------------------------------------------------------------- state
Run "10-programdata-tree.txt" {
    if (Test-Path -LiteralPath $localRoot) {
        Get-ChildItem -LiteralPath $localRoot -Recurse -ErrorAction SilentlyContinue |
            Select-Object @{n='Path';e={$_.FullName.Substring($localRoot.Length)}}, Length, LastWriteTime |
            Format-Table -AutoSize | Out-String
    } else { "$localRoot does not exist" }
} | Out-Null

foreach ($f in @("health.json", "SAFEMODE.json", "session.json")) {
    $p = Join-Path $localRoot $f
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $dir ("11-" + $f)) -Force }
}

Run "12-recent-events.txt" {
    $evd = Join-Path $localRoot ("logs\" + $pc + "\events_rolling")
    if (Test-Path -LiteralPath $evd) {
        $files = Get-ChildItem -LiteralPath $evd -Filter *.jsonl | Sort-Object LastWriteTime -Descending | Select-Object -First 3
        foreach ($f in $files) {
            "===== $($f.Name) (last $EventLines lines) ====="
            Get-Content -LiteralPath $f.FullName -Tail $EventLines
            ""
        }
    } else { "no events_rolling folder yet at $evd" }
} | Out-Null

Run "13-recent-sessions.txt" {
    $idx = Join-Path $localRoot ("logs\" + $pc + "\index.csv")
    if (Test-Path -LiteralPath $idx) {
        Import-Csv -LiteralPath $idx | Select-Object -Last 40 |
            Format-Table start_local, user_name, duration_min, end_reason, files_new, files_deleted -AutoSize | Out-String
    } else { "no index.csv yet" }
} | Out-Null

# ---------------------------------------------------------------- checks
$preflightOut = Run "14-preflight.txt" {
    & (Join-Path $here "ISG-NIS-Helper-Preflight.ps1") -ConfigPath (Join-Path $here "config.ini") -NoWriteTest
}
$pfJoined = ($preflightOut | Out-String)
$preflightVerdict = "could not be determined"
if     ($pfJoined -match 'Ready to install\.')            { $preflightVerdict = "PASS" }
elseif ($pfJoined -match 'Ready to install, with (\d+)')   { $preflightVerdict = "PASS with $($Matches[1]) warning(s)" }
elseif ($pfJoined -match '(\d+) problem\(s\)')             { $preflightVerdict = "$($Matches[1]) PROBLEM(S)" }

$testResults = @{}
if (-not $NoTests) {
    foreach ($t in @(@("15-selftest-prescan.txt", "selftest-prescan.ps1"),
                     @("16-selftest-nisdetect.txt", "selftest-nisdetect.ps1"))) {
        $script = Join-Path $here $t[1]
        if (Test-Path -LiteralPath $script) {
            $o = Run $t[0] { & $script }
            $testResults[$t[1]] = ($o | Out-String)
        }
    }
    $py = Join-Path $here "selftest.py"
    if (Test-Path -LiteralPath $py) {
        $o = Run "17-selftest-python.txt" {
            $exe = (Get-Command python -ErrorAction SilentlyContinue).Source
            if ($exe) { & $exe $py } else { "python is not on PATH on this machine (normal for a scope PC -- the .exe files need no Python)" }
        }
        $testResults["selftest.py"] = ($o | Out-String)
    }
}

# ---------------------------------------------------------------- summary
function Verdict { param($text, $pattern, $good, $bad)
    if ($text -match $pattern) { return $good } else { return $bad }
}
$sum = @()
$sum += "# ISG-NIS-Helper diagnostic summary"
$sum += ""
$sum += "Paste this whole file. The other files in this folder have the detail."
$sum += ""
$sum += "## Machine"
$sum += ""
foreach ($k in $machine.Keys) { $sum += ("- **{0}**: {1}" -f $k, $machine[$k]) }
$sum += ""
$sum += "## State"
$sum += ""
function TaskState { param([string]$Name)
    $text = ""
    $code = 1
    try {
        $text = (& schtasks /query /TN $Name 2>&1) -join " "
        $code = $LASTEXITCODE
    } catch {
        return "could not check (schtasks unavailable)"
    }
    if ($code -eq 0 -and $text -notmatch 'ERROR:') { return "registered" }
    return "NOT registered"
}
$sum += ("- **ISG-NIS-Helper-Agent task**: " + (TaskState "ISG-NIS-Helper-Agent"))
$sum += ("- **ISG-NIS-Helper-Svc task**: " + (TaskState "ISG-NIS-Helper-Svc"))
$safe = Join-Path $localRoot "SAFEMODE.json"
if (Test-Path -LiteralPath $safe) {
    $sm = Get-Content -LiteralPath $safe -Raw | ConvertFrom-Json
    $sum += ("- **SAFE MODE IS ACTIVE** since {0}: {1}" -f $sm.since_local, $sm.reason)
    $sum += ("  - detail: " + $sm.detail)
} else {
    $sum += "- **Safe mode**: not active"
}
$hp = Join-Path $localRoot "health.json"
if (Test-Path -LiteralPath $hp) {
    $h = Get-Content -LiteralPath $hp -Raw | ConvertFrom-Json
    $sum += ("- **Health last written**: " + $h.updated_local)
    $sum += ("- **Enforcement paused**: " + $h.enforcement_paused)
    $sum += ("- **Terminations in the last hour**: " + $h.terminations_last_hour)
    if ($h.last_checks) {
        $sum += "- **Last health checks**:"
        foreach ($p in $h.last_checks.PSObject.Properties) { $sum += ("  - {0}: {1}" -f $p.Name, $p.Value) }
    }
} else { $sum += "- **health.json**: not written yet (the watcher may never have run)" }
$sum += ""
$sum += "## Results"
$sum += ""
$sum += ("- **Preflight**: " + $preflightVerdict)
foreach ($line in ($pfJoined -split "`r?`n")) { if ($line -match '\[FAIL\]|\[ !! \]') { $sum += ("  - " + $line.Trim()) } }
foreach ($k in $testResults.Keys) {
    $t = $testResults[$k]
    $v = "see file"
    if ($t -match 'all .*checks passed|0 failed') { $v = "PASS" }
    elseif ($t -match '(?m)^\s*FAIL\s') { $v = "FAILURES" }
    $sum += ("- **{0}**: {1}" -f $k, $v)
    foreach ($line in ($t -split "`r?`n")) { if ($line -match '^\s*FAIL\s') { $sum += ("  - " + $line.Trim()) } }
}
$sum += ""
$sum += "## Notable recent events"
$sum += ""
$notable = @()
$evd = Join-Path $localRoot ("logs\" + $pc + "\events_rolling")
if (Test-Path -LiteralPath $evd) {
    foreach ($f in (Get-ChildItem -LiteralPath $evd -Filter *.jsonl | Sort-Object LastWriteTime -Descending | Select-Object -First 3)) {
        foreach ($line in (Get-Content -LiteralPath $f.FullName -Tail 1000)) {
            if ($line -match 'safe_mode|unauthorized|enforcement_withheld|watch_error|process_list_unreadable|os_build_changed|agent_not_heartbeating|nis_launch_failed|diff_failed') {
                $notable += $line
            }
        }
    }
}
if ($notable.Count) {
    $sum += '```'
    $sum += ($notable | Select-Object -Last 40)
    $sum += '```'
} else { $sum += "None." }
$sum += ""
$sum += "## Files in this bundle"
$sum += ""
foreach ($f in (Get-ChildItem -LiteralPath $dir -File | Sort-Object Name)) {
    $sum += ("- `{0}` ({1:N0} bytes)" -f $f.Name, $f.Length)
}
$sum += ""
$sum += "_PINs are redacted in 05-config and 06-users. No image data is included._"

Put "00-SUMMARY.md" ($sum -join "`r`n") | Out-Null

# ---------------------------------------------------------------- zip
$zip = Join-Path $OutRoot ("ISG-NIS-Helper-diagnostics_{0}_{1}.zip" -f $pc, $stamp)
try {
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $zip -Force
} catch {
    $zip = "(could not create a zip: " + $_.Exception.Message + ")"
}

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor DarkGray
Write-Host "  Collected." -ForegroundColor Green
Write-Host ("    folder: " + $dir)
Write-Host ("    zip   : " + $zip)
Write-Host ""
Write-Host "  Start with 00-SUMMARY.md -- it is written to be pasted whole." -ForegroundColor Cyan
Write-Host "  PINs are redacted. No image data is included." -ForegroundColor DarkGray
Write-Host ("=" * 70) -ForegroundColor DarkGray
Write-Host ""
