<#
=======================================================================
 ISG-NIS-Helper-Preflight.ps1
 -----------------------------------------------------------------
 Validates a config.ini before (or after) installing. install.bat calls
 this automatically; you can also run it any time to check a machine.

 Exit codes:   0 = ready    1 = problems found    2 = could not read config

 It changes nothing except one temporary file on the network share,
 which it deletes (pass -NoWriteTest to skip even that).
=======================================================================
#>

[CmdletBinding()]
param(
    [string] $ConfigPath = "",
    [switch] $NoWriteTest
)

$ErrorActionPreference = "Continue"
$script:Problems = 0
$script:Warnings = 0

function Good { param($t) Write-Host ("  [ OK ]   " + $t) -ForegroundColor Green }
function Warn { param($t) Write-Host ("  [ !! ]   " + $t) -ForegroundColor Yellow; $script:Warnings++ }
function Bad  { param($t) Write-Host ("  [FAIL]   " + $t) -ForegroundColor Red;    $script:Problems++ }
function Note { param($t) Write-Host ("           " + $t) -ForegroundColor DarkGray }
function Head { param($t) Write-Host ""; Write-Host ("-- " + $t) -ForegroundColor Cyan }

function Read-Ini {
    param([string]$Path)
    $ini = @{}; $section = ""
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith(";") -or $l.StartsWith("#")) { continue }
        if ($l -match '^\[(.+)\]$') { $section = $Matches[1].Trim(); $ini[$section] = @{}; continue }
        $eq = $l.IndexOf("=")
        if ($eq -lt 1 -or -not $section) { continue }
        $k = $l.Substring(0, $eq).Trim()
        # ";" is the data_roots list separator, so it is NOT treated as an
        # inline comment marker here either -- this parser must agree with
        # ISG-NIS-Helper's own. Comments live on their own line.
        $ini[$section][$k] = $l.Substring($eq + 1).Trim()
    }
    return $ini
}
function Val { param($Ini, $S, $K, $D = "") if ($Ini[$S] -and $Ini[$S][$K]) { return $Ini[$S][$K] } return $D }

# ---------------------------------------------------------------- config

if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "config.ini" }

Write-Host ""
Write-Host "  ISG-NIS-Helper preflight" -ForegroundColor White
Write-Host ("  " + $ConfigPath) -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Bad "config.ini not found at that path."
    Note "Run ISG-NIS-Helper-PreScan.ps1 first, review config.generated.ini, then save it as config.ini."
    exit 2
}
$ini = Read-Ini $ConfigPath

Head "Placeholders"
$raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
$unset = @()
foreach ($line in ($raw -split "`r?`n")) {
    if ($line -match '<<<SET_ME' -and -not $line.TrimStart().StartsWith(";")) {
        $key = $line.Split("=")[0].Trim()
        # network_root is optional; it is reported in its own section.
        if ($key -ne "network_root") { $unset += $key }
    }
}
if ($unset.Count) {
    Bad ("Still unset: " + ($unset -join ", "))
    Note "ISG-NIS-Helper will refuse to open a session until these are filled in."
} else { Good "No placeholders remain." }

# ---------------------------------------------------------------- label

Head "Instrument"
$label = Val $ini "instrument" "computer_label"
if (-not $label) { Bad "[instrument] computer_label is empty." }
elseif ($label -eq $env:COMPUTERNAME) {
    Warn "computer_label is just the machine name ($label)."
    Note "A human-readable name ('SCOPE-2 Ti2 Spinning Disk') makes the logs far easier to read."
} else { Good "Labelled as: $label" }

# ---------------------------------------------------------------- nis

Head "NIS-Elements"
$nis = Val $ini "paths" "nis_executable"
if (-not $nis) { Bad "[paths] nis_executable is empty." }
elseif (-not (Test-Path -LiteralPath $nis)) { Bad "nis_executable does not exist: $nis" }
else {
    Good "Found: $nis"
    try {
        $fi = Get-Item -LiteralPath $nis
        Note ("{0}  |  v{1}  |  {2} MB" -f $fi.Name, $fi.VersionInfo.ProductVersion, [math]::Round($fi.Length / 1MB, 1))
    } catch { }
}

$procs = (Val $ini "processes" "nis_process_names") -split "[,;]" | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
$IMPOSTORS = @{
    'nissrv.exe'   = 'Windows Defender Network Realtime Inspection Service'
    'nisvcloc.exe' = 'National Instruments Service Locator'
    'nisds.exe'    = 'National Instruments Sync Domain Service'
    'control.exe'  = 'Windows Control Panel'
    'explorer.exe' = 'Windows Explorer'
    'svchost.exe'  = 'Windows service host'
    'msmpeng.exe'  = 'Windows Defender antimalware engine'
}

if ($procs.Count -eq 0) { Bad "[processes] nis_process_names is empty; nothing would ever be gated." }
else {
    $bad = @($procs | Where-Object { $IMPOSTORS.ContainsKey($_) })
    foreach ($b in $bad) {
        Bad ("nis_process_names contains '{0}' -- that is {1}." -f $b, $IMPOSTORS[$b])
    }
    if ($bad.Count) {
        Note "These run permanently. ISG-NIS-Helper would believe NIS-Elements is always"
        Note "open: sessions would never end, and the watcher would try to terminate"
        Note "a system service every couple of minutes. Remove them."
    }
    $odd = @($procs | Where-Object { $_ -notmatch '^nis[-_]' -and -not $IMPOSTORS.ContainsKey($_) })
    if ($odd.Count) {
        Warn ("Does not look like an NIS-Elements module: " + ($odd -join ", "))
        Note "Every real one is named nis_something.exe. Check before installing."
    }
    Good ("Gating {0} process name(s): {1}" -f $procs.Count, ($procs -join ", "))
    if ($nis -and (Test-Path -LiteralPath $nis)) {
        $exeName = [IO.Path]::GetFileName($nis).ToLower()
        if ($procs -notcontains $exeName) {
            Bad "nis_process_names does not include '$exeName', the executable ISG-NIS-Helper launches."
            Note "Closing NIS would not end the session. Add it to the list."
        } else { Good "The launched executable is in the gated list." }
    }
}

# ---------------------------------------------------------------- data

Head "Data roots"
$roots = (Val $ini "paths" "data_roots") -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($roots.Count -eq 0) { Bad "[paths] data_roots is empty; no file changes would ever be recorded." }
foreach ($r in $roots) {
    if (-not (Test-Path -LiteralPath $r)) { Bad "data_root does not exist: $r"; continue }
    $n = 0
    try { $n = @(Get-ChildItem -LiteralPath $r -Recurse -File -Depth 3 -ErrorAction SilentlyContinue).Count } catch { }
    Good ("$r  (about $n files within 3 levels)")
    if ($n -gt 200000) { Warn "That is a very large tree; snapshots will be slow. Consider a narrower root." }
}

# ---------------------------------------------------------------- network

Head "Approved user list"
$usersCsv = Val $ini "paths" "users_file"
if (-not $usersCsv) { $usersCsv = Join-Path $here "users.csv" }

if (-not (Test-Path -LiteralPath $usersCsv)) {
    Bad "users.csv not found at $usersCsv"
    Note "Copy users_template.csv to users.csv in the ISG-NIS-Helper folder and fill"
    Note "it in. Without it nobody can sign in."
} else {
    try {
        $rows = @(Import-Csv -LiteralPath $usersCsv)
        $active = @($rows | Where-Object { $_.active -notmatch '^(no|false|0|inactive)$' })
        Good ("users.csv parses: {0} rows, {1} active" -f $rows.Count, $active.Count)
        Note ("  " + $usersCsv)

        if ($active.Count -eq 0) {
            Bad "No active users. Nobody would be able to sign in."
            Note "The shipped template is deliberately empty -- fill it in for this scope."
        }

        $noPin = @($active | Where-Object { -not $_.pin })
        if ($noPin.Count) { Bad ("{0} active user(s) have no PIN: {1}" -f $noPin.Count, (($noPin | ForEach-Object { $_.name }) -join ", ")) }

        $noEmail = @($active | Where-Object { $_.email -notmatch '@' })
        if ($noEmail.Count) { Bad ("{0} active user(s) have no valid email." -f $noEmail.Count) }

        $dupPin = $active | Group-Object pin | Where-Object { $_.Count -gt 1 -and $_.Name }
        if ($dupPin) {
            foreach ($g in $dupPin) {
                Bad ("PIN {0} is shared by: {1}" -f $g.Name, (($g.Group | ForEach-Object { $_.name }) -join ", "))
            }
            Note "Shared PINs destroy attribution, which is the entire point."
        } elseif ($active.Count) { Good "All PINs are unique." }

        $shortPin = @($active | Where-Object { $_.pin -and $_.pin.Length -lt 4 })
        if ($shortPin.Count) { Warn ("{0} PIN(s) are shorter than 4 digits." -f $shortPin.Count) }
    } catch { Bad ("users.csv could not be parsed: " + $_.Exception.Message) }
}

Head "Log mirror (optional)"
$net = Val $ini "paths" "network_root"
if (-not $net) {
    Good "No mirror configured. Logs stay on this machine."
    Note "That is a complete, working setup. Set network_root only if you want"
    Note "several scopes to pool their finished session files in one folder."
} elseif ($net -match '<<<SET_ME') {
    Bad "network_root still contains placeholder text."
    Note "It is optional -- leave it BLANK rather than filling it in."
} elseif ($net -match '\.csv$') {
    Bad "network_root points at a FILE, not a folder: $net"
    Note "It is a folder to mirror logs into. The user list is local now."
} else {
    $reach = $false
    try { $reach = (Test-Path -LiteralPath $net) -or (Test-Path -LiteralPath (Split-Path -Parent $net)) } catch { }
    if (-not $reach) {
        Warn "Cannot reach $net"
        Note "Not fatal: logs are written locally and queue until it returns."
    } else {
        Good "Reachable: $net"
        if (-not $NoWriteTest) {
            $dir = $net
            if (-not (Test-Path -LiteralPath $net)) { $dir = Split-Path -Parent $net }
            $probe = Join-Path $dir ("ISG-NIS-Helper-writetest-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".tmp")
            $wrote = $false
            try {
                Set-Content -LiteralPath $probe -Value "test" -ErrorAction Stop
                Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                $wrote = $true
            } catch { }
            if ($wrote) { Good "Writable." }
            else { Warn "Not writable. Logs stay local until that is fixed." }
        }
    }
}

# ---------------------------------------------------------------- local

Head "Local log store"
$local = Val $ini "paths" "local_root" "C:\ProgramData\ISG-NIS-Helper"
try {
    if (-not (Test-Path -LiteralPath $local)) { New-Item -ItemType Directory -Path $local -Force | Out-Null }
    $probe = Join-Path $local ("pf-" + [guid]::NewGuid().ToString("N").Substring(0, 6) + ".tmp")
    Set-Content -LiteralPath $probe -Value "x" -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force
    Good "Writable: $local"
} catch {
    Bad ("Cannot write to $local : " + $_.Exception.Message)
    Note "install.bat grants the Users group Modify on this folder; run it as Administrator."
}

# ---------------------------------------------------------------- access

Head "Master PIN"
$mp = Val $ini "access" "master_pin"
if (-not $mp) { Warn "No master PIN set. Managers will have no way in if the share is unreachable." }
elseif ($mp.Length -lt 4) { Bad "Master PIN is shorter than 4 digits." }
else { Good ("Set ({0} digits)." -f $mp.Length) }

# ---------------------------------------------------------------- tasks

Head "Scheduled tasks"
foreach ($t in @("ISG-NIS-Helper-Svc", "ISG-NIS-Helper-Agent")) {
    # Guarded: preflight is run by the diagnostic collector, and one
    # unexpected error here must not abort the whole report.
    try {
        & schtasks /query /TN $t 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Good "$t is registered." }
        else { Warn "$t is not registered yet (install.bat does this)." }
    } catch {
        Warn ("could not query the $t task: " + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- clock

Head "Clock"
$src = ""
try { $src = (& w32tm /query /source 2>&1) -join " " } catch { }
if ($src -match "Local CMOS|Free-running|not been started") {
    Good "Free-running clock. Fine unless it drifts by hours."
} elseif ($src) { Good "Time source: $src" } else { Good "Time source unreadable (needs elevation). Not important." }

# ---------------------------------------------------------------- verdict

Write-Host ""
Write-Host ("=" * 62) -ForegroundColor DarkGray
if ($script:Problems -eq 0 -and $script:Warnings -eq 0) {
    Write-Host "  Ready to install." -ForegroundColor Green
} elseif ($script:Problems -eq 0) {
    Write-Host ("  Ready to install, with {0} warning(s) above." -f $script:Warnings) -ForegroundColor Yellow
} else {
    Write-Host ("  {0} problem(s) and {1} warning(s). Fix the problems first." -f $script:Problems, $script:Warnings) -ForegroundColor Red
}
Write-Host ("=" * 62) -ForegroundColor DarkGray
Write-Host ""
exit $(if ($script:Problems) { 1 } else { 0 })
