<#
=======================================================================
 ISG-NIS-Helper-PreScan.ps1
 -----------------------------------------------------------------
 Run this on a microscope PC BEFORE installing ISG-NIS-Helper.

 It finds the machine-specific things ISG-NIS-Helper needs to be told --
 where NIS-Elements actually lives, where image data actually lands,
 which network share is actually writable -- and writes out:

     ISG-NIS-Helper-PreScan_<PC>_<date>.txt    human-readable report
     prescan.json                          machine-readable results
     config.generated.ini                  a ready-to-review config

 THIS SCRIPT CHANGES NOTHING ON THIS COMPUTER.
 It reads the registry, the file system and the running process list.
 The only things it writes are the three files above, plus (unless you
 pass -NoWriteTest) one tiny temporary file on each network share,
 which it deletes immediately. It never touches image data.

 Usage (from an ordinary Command Prompt or PowerShell):

     powershell -NoProfile -ExecutionPolicy Bypass -File ISG-NIS-Helper-PreScan.ps1

 or just double-click Run-PreScan.bat.

 Useful switches:
     -Deep               search every fixed drive exhaustively (slower)
     -ScanSeconds 300    raise the time budget for the data-file census
     -NoWriteTest        do not test-write to network shares
     -OutDir <path>      where to put the three output files
=======================================================================
#>

[CmdletBinding()]
param(
    [string] $OutDir = "",
    [string] $Label = "",
    [int]    $ScanSeconds = 180,
    [int]    $MaxDepth = 12,
    [switch] $NoWriteTest,
    [switch] $Deep
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

if ($Deep) { if ($ScanSeconds -lt 600) { $ScanSeconds = 600 }; $MaxDepth = 24 }

# ---------------------------------------------------------------- report

$script:Lines = New-Object System.Collections.ArrayList
$script:Data  = [ordered]@{}

function Say {
    param([string]$Text = "", [string]$Color = "Gray")
    [void]$script:Lines.Add($Text)
    Write-Host $Text -ForegroundColor $Color
}
function Head {
    param([string]$Text)
    Say ""
    Say ("=" * 70) "DarkGray"
    Say ("  " + $Text) "Cyan"
    Say ("=" * 70) "DarkGray"
}
function Item { param([string]$K, $V) Say ("    {0,-26} {1}" -f ($K + ":"), $V) }
function Good { param([string]$T) Say ("  [ OK ]   " + $T) "Green" }
function Warn { param([string]$T) Say ("  [ !! ]   " + $T) "Yellow" }
function Bad  { param([string]$T) Say ("  [FAIL]   " + $T) "Red" }
function Note { param([string]$T) Say ("           " + $T) "DarkGray" }

# ---------------------------------------------------------------- helpers

function Resolve-Shortcut {
    param([string]$LnkPath)
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($LnkPath)
        $t  = $sc.TargetPath
        [Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
        if ($t -and (Test-Path -LiteralPath $t)) { return $t }
    } catch { }
    return $null
}

function Get-FileCensus {
    <#  Stack-based walk with a wall-clock budget. Per-directory errors are
        skipped rather than aborting, exactly like ISG-NIS-Helper's own scanner. #>
    param(
        [string[]] $Roots,
        [string[]] $Extensions,
        [int]      $BudgetSeconds,
        [int]      $Depth,
        [string[]] $ExcludeNames
    )
    $sw     = [Diagnostics.Stopwatch]::StartNew()
    $exts   = @{}; foreach ($e in $Extensions) { $exts[$e.ToLower()] = $true }
    $skip   = @{}; foreach ($n in $ExcludeNames) { $skip[$n.ToLower()] = $true }
    $tally  = @{}
    $stack  = New-Object System.Collections.Stack
    $dirsSeen = 0
    $truncated = $false

    foreach ($r in $Roots) {
        if (Test-Path -LiteralPath $r) { $stack.Push([pscustomobject]@{ P = $r; D = 0 }) }
    }

    while ($stack.Count -gt 0) {
        if ($sw.Elapsed.TotalSeconds -ge $BudgetSeconds) { $truncated = $true; break }
        $cur = $stack.Pop()
        $dirsSeen++
        $di = $null
        # `continue` in a catch exits the loop in PowerShell rather than
        # continuing it, so one unreadable directory would have silently
        # truncated the whole census. Test the result instead.
        try { $di = New-Object System.IO.DirectoryInfo $cur.P } catch { $di = $null }
        if ($null -eq $di) { continue }

        try {
            foreach ($f in $di.GetFiles()) {
                $ext = $f.Extension.ToLower()
                if ($exts.ContainsKey($ext)) {
                    $k = $di.FullName
                    if (-not $tally.ContainsKey($k)) {
                        $tally[$k] = [pscustomobject]@{
                            Path = $k; Count = 0; Bytes = [int64]0
                            Newest = [datetime]'1900-01-01'; Oldest = [datetime]'2999-01-01'
                        }
                    }
                    $t = $tally[$k]
                    $t.Count++
                    $t.Bytes += $f.Length
                    if ($f.LastWriteTime -gt $t.Newest) { $t.Newest = $f.LastWriteTime }
                    if ($f.LastWriteTime -lt $t.Oldest) { $t.Oldest = $f.LastWriteTime }
                }
            }
        } catch { }

        if ($cur.D -lt $Depth) {
            try {
                foreach ($d in $di.GetDirectories()) {
                    if ($skip.ContainsKey($d.Name.ToLower())) { continue }
                    if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push([pscustomobject]@{ P = $d.FullName; D = $cur.D + 1 })
                }
            } catch { }
        }
    }

    return [pscustomobject]@{
        Dirs      = ($tally.Values | Sort-Object -Property Count -Descending)
        DirsSeen  = $dirsSeen
        Seconds   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Truncated = $truncated
    }
}

function Remove-SystemDriveRoots {
    <#  Drop the system drive from a list of proposed data roots. Data lands on
        the data drives; snapshotting C:\ every session is slow and pulls in
        unrelated files. A function so it can be unit-tested off Windows. #>
    param([string[]]$Roots, [string]$SystemDrive = $env:SystemDrive)
    $sys = ("" + $SystemDrive).TrimEnd('\')
    if (-not $sys) { return @($Roots) }
    $sysU = $sys.ToUpper()
    return @($Roots | Where-Object {
        $rp = ("" + $_).TrimEnd('\')
        -not ($rp.ToUpper() -eq $sysU -or $rp.ToUpper().StartsWith($sysU + '\')) })
}

function Get-DriveRoot {
    <#  "F:\Nongyun\2026..." -> "F:\" ,  "\\srv\share\x" -> "\\srv\share\"
        Parsed here rather than via [IO.Path]::GetPathRoot, whose behaviour
        depends on the platform it runs on. #>
    param([string]$Path)
    if (-not $Path) { return "" }
    if ($Path -match '^(\\\\[^\\/]+[\\/][^\\/]+)') { return ($Matches[1] + '\') }
    if ($Path -match '^([A-Za-z]:)')               { return ($Matches[1] + '\') }
    if ($Path -match '^/')                          { return '/' }
    return ""
}

function Get-Ancestor {
    <#  "D:\ImagingData\2026-09-21\SampleB" at Levels 1 -> "D:\ImagingData".

        The root is parsed here rather than handed to [IO.Path]::GetPathRoot,
        so the behaviour is identical whatever platform this is checked on,
        and so it can be unit-tested. Handles drive letters, UNC shares and
        POSIX paths.                                                        #>
    param([string]$Path, [int]$Levels)
    if (-not $Path) { return $Path }

    $root = ""
    $sep  = '\'
    if ($Path -match '^(\\\\[^\\/]+[\\/][^\\/]+)([\\/]|$)') {   # \\server\share
        $root = $Matches[1]
    } elseif ($Path -match '^([A-Za-z]:)([\\/]|$)') {           # D:\ or D:
        $root = $Matches[1]
    } elseif ($Path -match '^/') {                              # /var/data
        $sep = '/'
    } elseif ($Path -match '/' -and $Path -notmatch '\\') {
        $sep = '/'
    }

    $rest = $Path.Substring($root.Length).Trim([char[]]@('\', '/'))
    if (-not $rest) { return $Path }
    $parts = $rest.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -eq 0) { return $Path }
    $take = [Math]::Min([Math]::Max(1, $Levels), $parts.Count)
    return ($root + $sep + ($parts[0..($take - 1)] -join $sep))
}

# ---------------------------------------------------------------- start

Clear-Host
Say ""
Say "  ISG-NIS-Helper pre-install scan" "White"
Say "  This script only READS this computer. It changes nothing." "DarkGray"
Say ""

$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$pc    = $env:COMPUTERNAME

# What should this instrument be called in the logs? Ask now, before the slow
# scan, so it lands in the generated config. -Label skips the prompt.
$scopeLabel = $Label
if (-not $scopeLabel) {
    Say ""
    Say "  What should this instrument be called in the logs?" "White"
    Say ("  A human name, e.g. 'SCOPE-2 Ti2 Spinning Disk'. Press Enter to use '{0}'." -f $pc) "DarkGray"
    $ans = Read-Host "  Instrument name"
    if ($ans) { $scopeLabel = $ans.Trim() }
}
if (-not $scopeLabel) { $scopeLabel = $pc }
Say ("  Using instrument name: {0}" -f $scopeLabel) "Green"

if (-not $OutDir) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    $probe = Join-Path $here ("w" + [guid]::NewGuid().ToString("N").Substring(0, 6) + ".tmp")
    try { Set-Content -LiteralPath $probe -Value "x" -ErrorAction Stop; Remove-Item $probe -Force; $OutDir = $here }
    catch { $OutDir = Join-Path $env:USERPROFILE "Desktop\ISG-NIS-Helper-PreScan" }
}
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ---------------------------------------------------------------- 1. system

Head "1.  Computer and operating system"
$os = $null; $cs = $null
try { $os = Get-CimInstance Win32_OperatingSystem } catch { }
try { $cs = Get-CimInstance Win32_ComputerSystem } catch { }

$sysInfo = [ordered]@{
    ComputerName = $pc
    OS           = if ($os) { $os.Caption } else { "unknown" }
    Version      = if ($os) { $os.Version } else { "unknown" }
    Build        = if ($os) { $os.BuildNumber } else { "unknown" }
    Architecture = $env:PROCESSOR_ARCHITECTURE
    Domain       = if ($cs) { $cs.Domain } else { "unknown" }
    PartOfDomain = if ($cs) { [bool]$cs.PartOfDomain } else { $false }
    LastBoot     = if ($os) { $os.LastBootUpTime.ToString("yyyy-MM-dd HH:mm") } else { "unknown" }
    PSVersion    = $PSVersionTable.PSVersion.ToString()
    LocalTime    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    UtcTime      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    TimeZone     = (Get-TimeZone -ErrorAction SilentlyContinue).Id
}
foreach ($k in $sysInfo.Keys) { Item $k $sysInfo[$k] }
$script:Data.System = $sysInfo

if ($sysInfo.PartOfDomain) { Note "Domain-joined. Worth telling IT before installing." }
else { Good "Standalone (workgroup) machine, as expected." }

# ---------------------------------------------------------------- 2. accounts

Head "2.  Accounts and privileges"
$isAdmin = $false
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

Item "Signed in as" ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
Item "Running elevated" $isAdmin

$adminMembers = @()
try {
    $raw = & net localgroup Administrators 2>$null
    $started = $false
    foreach ($l in $raw) {
        if ($l -match '^-+$') { $started = -not $started; continue }
        if ($started -and $l -and $l -notmatch 'completed successfully') { $adminMembers += $l.Trim() }
    }
} catch { }

$localUsers = @()
try { $localUsers = (Get-LocalUser -ErrorAction Stop | Where-Object Enabled).Name } catch {
    try { $localUsers = (Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND Disabled=False").Name } catch { }
}

Item "Enabled local accounts" ($localUsers -join ", ")
Item "Administrators group" ($adminMembers -join ", ")
$script:Data.Accounts = [ordered]@{
    CurrentUser = "$env:USERDOMAIN\$env:USERNAME"; Elevated = $isAdmin
    LocalUsers = $localUsers; Administrators = $adminMembers
}

if (-not $isAdmin) { Warn "Not elevated. That is fine for this scan; install.bat does need Administrator." }
if ($adminMembers.Count -gt 2) {
    Warn "$($adminMembers.Count) entries in the Administrators group."
    Note "Every one of them can change NIS configurations and end the ISG-NIS-Helper watcher."
}

# ---------------------------------------------------------------- 3. drives

Head "3.  Drives"
$drives = @()
try {
    foreach ($d in (Get-CimInstance Win32_LogicalDisk)) {
        $type = switch ($d.DriveType) { 2 { "removable" } 3 { "fixed" } 4 { "network" } 5 { "optical" } default { "other" } }
        $drives += [ordered]@{
            Letter = $d.DeviceID; Type = $type; Label = $d.VolumeName
            FileSystem = $d.FileSystem
            SizeGB = if ($d.Size) { [math]::Round($d.Size / 1GB, 1) } else { $null }
            FreeGB = if ($d.FreeSpace) { [math]::Round($d.FreeSpace / 1GB, 1) } else { $null }
            Remote = $d.ProviderName
        }
    }
} catch { }
foreach ($d in $drives) {
    Say ("    {0,-4} {1,-10} {2,-18} {3,8} GB free of {4,8} GB   {5}" -f `
        $d.Letter, $d.Type, $d.Label, $d.FreeGB, $d.SizeGB, $d.Remote)
}
$script:Data.Drives = $drives

$sysFree = ($drives | Where-Object { $_.Letter -eq $env:SystemDrive }).FreeGB
if ($sysFree -ne $null -and $sysFree -lt 5) { Warn "Less than 5 GB free on $env:SystemDrive. Logs are small, but worth clearing." }

# ---------------------------------------------------------------- 4. NIS

Head "4.  NIS-Elements"
$nisCandidates = @()

# Executables that merely happen to begin with "nis". NisSrv.exe is Windows
# Defender's Network Realtime Inspection Service; nisvcloc/nisds are National
# Instruments services. All three run permanently, so gating any of them makes
# ISG-NIS-Helper believe NIS is always open: sessions never end, and the watcher
# tries to terminate a system service every couple of minutes.
$NIS_IMPOSTORS = '^(nissrv|nisvcloc|nisds|nissvc|niservice)\.exe$'

# Real NIS-Elements acquisition modules.
$NIS_APP_NAMES = '^(nis_ar|nis_br|nis_c|nis_d|nis_el|nis_elements)\.exe$'

# Inside the NIS-Elements folder, but utilities rather than the application.
$NIS_UTILITIES = 'utl_|_train|hasp|_update|exportsettings|uninstall|setup'

function Get-LeafName {
    <#  "C:\Program Files\NIS-Elements\nis_ar.exe" -> "nis_ar.exe"
        Not [IO.Path]::GetFileName: that treats "\" as a separator only when
        running on Windows, and returns the whole string otherwise. #>
    param([string]$Path)
    if (-not $Path) { return "" }
    $parts = $Path.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Count -eq 0) { return "" }
    return $parts[-1]
}

function Test-NisApp {
    <# Is this an NIS-Elements ACQUISITION executable, as opposed to a utility
       beside it or an unrelated program whose name starts with "nis"? #>
    param([string]$Path)
    $name = (Get-LeafName $Path).ToLower()
    if ($name -match $NIS_IMPOSTORS) { return $false }
    if ($Path -notmatch '\\NIS-Elements\\') { return $false }
    if ($name -match $NIS_UTILITIES) { return $false }
    return ($name -match $NIS_APP_NAMES)
}

function Get-NisScore {
    <# Score by the weight of the evidence, not by which search found it
       first. An earlier version gave every shortcut hit the same score, so a
       settings utility that happened to sort first beat the application with
       five shortcuts and a registry record behind it. #>
    param($Candidate)
    $name = $Candidate.Name.ToLower()
    $score = 0

    if ($Candidate.How -match 'currently running')   { $score += 60 }
    $shortcuts = ([regex]::Matches($Candidate.How, 'shortcut:')).Count
    if ($shortcuts -ge 1) { $score += 25 + (10 * [Math]::Min($shortcuts - 1, 4)) }
    if ($Candidate.How -match 'installed:')          { $score += 25 }
    if ($Candidate.How -match 'under Program Files') { $score += 5 }

    if ($name -match $NIS_APP_NAMES)                    { $score += 50 }
    if ($Candidate.Path -match '\\NIS-Elements\\')      { $score += 20 }
    if ($Candidate.Description -match 'NIS[ ._-]?Elements') { $score += 20 }

    if ($name -match $NIS_IMPOSTORS)                 { $score -= 200 }
    if ($name -match $NIS_UTILITIES)                 { $score -= 60 }
    if ($Candidate.Path -match '\\Windows\\|\\Windows Defender\\|\\National Instruments\\') { $score -= 200 }
    if ($Candidate.SizeMB -lt 0.2)                   { $score -= 15 }

    return $score
}

function Add-Nis {
    param([string]$Path, [string]$How, [int]$Score)
    if (-not $Path) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ((Get-LeafName $Path) -notmatch '\.exe$') { return }
    $existing = $script:nisCandidates | Where-Object { $_.Path -eq $Path }
    if ($existing) {
        if ($existing.How -notmatch [regex]::Escape($How)) { $existing.How += "; $How" }
        $existing.Score = Get-NisScore $existing
        return
    }
    $fi = Get-Item -LiteralPath $Path
    $ver = ""
    try { $ver = $fi.VersionInfo.ProductVersion } catch { }
    $desc = ""
    try { $desc = $fi.VersionInfo.FileDescription } catch { }
    $cand = [pscustomobject]@{
        Path = $Path; Name = $fi.Name; How = $How; Score = 0
        Version = $ver; Description = $desc
        SizeMB = [math]::Round($fi.Length / 1MB, 1)
        Modified = $fi.LastWriteTime.ToString("yyyy-MM-dd")
        IsNisApp = $false
    }
    $cand.Score = Get-NisScore $cand
    $cand.IsNisApp = Test-NisApp $Path
    $script:nisCandidates += $cand
}

Say "  Looking in the running process list..."
try {
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(nis|NIS)' })) {
        try { Add-Nis $p.Path "currently running" 100 } catch { }
    }
} catch { }

Say "  Looking at desktop and Start Menu shortcuts..."
$lnkRoots = @(
    [Environment]::GetFolderPath("Desktop"),
    [Environment]::GetFolderPath("CommonDesktopDirectory"),
    [Environment]::GetFolderPath("Programs"),
    [Environment]::GetFolderPath("CommonPrograms")
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

foreach ($r in $lnkRoots) {
    foreach ($lnk in (Get-ChildItem -LiteralPath $r -Recurse -Filter *.lnk -ErrorAction SilentlyContinue)) {
        # \b matters: a bare "NIS" also matches "admiNIStrative Tools".
        if ($lnk.BaseName -match '(\bNIS\b|NIS-Elements|Nikon|\bElements\b)') {
            $t = Resolve-Shortcut $lnk.FullName
            if ($t) { Add-Nis $t ("shortcut: " + $lnk.BaseName) 90 }
        }
    }
}

Say "  Looking in the registry (installed programs)..."
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$installed = @()
foreach ($k in $uninstallKeys) {
    foreach ($e in (Get-ItemProperty $k -ErrorAction SilentlyContinue)) {
        if ($e.DisplayName -match 'NIS|Nikon|Laboratory Imaging') {
            $installed += [ordered]@{
                Name = $e.DisplayName; Version = $e.DisplayVersion
                Publisher = $e.Publisher; Location = $e.InstallLocation
            }
            if ($e.InstallLocation -and (Test-Path -LiteralPath $e.InstallLocation)) {
                foreach ($exe in (Get-ChildItem -LiteralPath $e.InstallLocation -Filter "nis*.exe" -ErrorAction SilentlyContinue)) {
                    Add-Nis $exe.FullName ("installed: " + $e.DisplayName) 80
                }
            }
        }
    }
}
foreach ($i in $installed) { Item "Installed program" ("{0}  {1}" -f $i.Name, $i.Version) }

Say "  Looking under Program Files..."
$pfRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
foreach ($pf in $pfRoots) {
    foreach ($exe in (Get-ChildItem -LiteralPath $pf -Recurse -Filter "nis*.exe" -Depth 4 -ErrorAction SilentlyContinue)) {
        if ($exe.FullName -notmatch '\\NIS-Elements\\') { continue }
        Add-Nis $exe.FullName "found under Program Files" 0
    }
}

Say ""
if ($nisCandidates.Count -eq 0) {
    Bad "No NIS-Elements executable found."
    Note "Open the NIS shortcut's Properties and read the Target field by hand,"
    Note "then put that path into config.ini as [paths] nis_executable."
} else {
    $nisCandidates = $nisCandidates | Sort-Object -Property Score -Descending
    Say ("  Found {0} candidate executable(s), best first:" -f $nisCandidates.Count) "White"
    $n = 0
    foreach ($c in $nisCandidates) {
        $n++
        $mark = if ($n -eq 1) { " <== best guess" } else { "" }
        Say ("    {0}. {1}{2}" -f $n, $c.Path, $mark) $(if ($n -eq 1) { "Green" } else { "Gray" })
        Say ("       {0}  |  v{1}  |  {2} MB  |  {3}  |  {4}" -f `
            $c.Name, $c.Version, $c.SizeMB, $c.Modified, $c.How) "DarkGray"
    }
    $gatable = @($nisCandidates | Where-Object { $_.IsNisApp })
    if ($gatable.Count -gt 1) {
        Warn "More than one acquisition module. Confirm which one people launch."
    } elseif ($nisCandidates.Count -gt 1) {
        Note "The others are utilities or services and are excluded from gating."
    }
}
$script:Data.NIS = [ordered]@{ Candidates = $nisCandidates; InstalledPrograms = $installed }

# ---- process names -----------------------------------------------------
# Only confirmed NIS-Elements applications go in this list, never every
# candidate. Gating a permanently-running service would mean sessions that
# never end and a watcher trying to kill it on a loop.
$procNames = @()
foreach ($c in $nisCandidates) {
    if ($c.IsNisApp) { $procNames += $c.Name.ToLower() }
}
foreach ($d in @("nis_ar.exe", "nis_br.exe", "nis_c.exe", "nis_d.exe", "nis_el.exe", "nis_elements.exe")) {
    if ($procNames -notcontains $d) { $procNames += $d }
}
$procNames = $procNames | Select-Object -Unique
Item "Process names to gate" ($procNames -join ", ")

$rejected = @($nisCandidates | Where-Object { -not $_.IsNisApp })
if ($rejected.Count) {
    Note ("Excluded from gating (not NIS-Elements applications): " +
          (($rejected | ForEach-Object { $_.Name }) -join ", "))
}
$script:Data.ProcessNames = $procNames

# ---- NIS support / log folders ----------------------------------------
Say ""
Say "  NIS support folders (useful when cross-referencing an incident):" "White"
$supportRoots = @($env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA) | Where-Object { $_ }
$support = @()
foreach ($sr in $supportRoots) {
    foreach ($d in (Get-ChildItem -LiteralPath $sr -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -match 'NIS|Nikon|Laboratory Imaging') {
            $logs = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -Include *.log, *.txt -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 5)
            $support += [ordered]@{ Path = $d.FullName; SampleLogs = ($logs | ForEach-Object { $_.FullName }) }
            Say ("    {0}" -f $d.FullName)
            foreach ($l in $logs) { Say ("       log: {0}" -f $l.FullName) "DarkGray" }
        }
    }
}
if ($support.Count -eq 0) { Note "None found under ProgramData or AppData." }
$script:Data.NISSupportFolders = $support

# ---------------------------------------------------------------- 5. data

Head "5.  Where image data actually lands"
Say "  Counting .nd2 files. This is the slow part; budget is $ScanSeconds seconds."
Say ""

$scanRoots = @()
foreach ($d in $drives) {
    if ($d.Type -eq "fixed") { $scanRoots += ($d.Letter + "\") }
}
$excludeNames = @(
    'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData',
    '$Recycle.Bin', 'System Volume Information', 'Recovery',
    'WinSxS', 'node_modules', 'AppData', '$WinREAgent', 'PerfLogs'
)

$census = Get-FileCensus -Roots $scanRoots -Extensions @(".nd2") `
    -BudgetSeconds $ScanSeconds -Depth $MaxDepth -ExcludeNames $excludeNames

$primaryExt = ".nd2"
if (($census.Dirs | Measure-Object).Count -eq 0) {
    Warn "No .nd2 files found. Falling back to a .tif / .tiff census."
    $census = Get-FileCensus -Roots $scanRoots -Extensions @(".tif", ".tiff") `
        -BudgetSeconds ([int]($ScanSeconds / 2)) -Depth $MaxDepth -ExcludeNames $excludeNames
    $primaryExt = ".tif/.tiff"
}

Item "Directories examined" $census.DirsSeen
Item "Seconds spent" $census.Seconds
Item "File type counted" $primaryExt
if ($census.Truncated) {
    Warn "Time budget reached; the scan is incomplete. Re-run with -ScanSeconds 600 for a full picture."
}

$dirList = @($census.Dirs)
$totalFiles = ($dirList | Measure-Object -Property Count -Sum).Sum
if (-not $totalFiles) { $totalFiles = 0 }

Say ""
if ($dirList.Count -eq 0) {
    Bad "No image files found anywhere on the fixed drives."
    Note "Open NIS-Elements and check its export/save path by hand, then set"
    Note "[paths] data_roots to the folder it writes into."
} else {
    Say ("  {0} files in {1} directories. Busiest directories:" -f $totalFiles, $dirList.Count) "White"
    $show = $dirList | Select-Object -First 12
    foreach ($d in $show) {
        Say ("    {0,7} files  {1,9} MB  newest {2}   {3}" -f `
            $d.Count, [math]::Round($d.Bytes / 1MB, 0), $d.Newest.ToString("yyyy-MM-dd"), $d.Path)
    }
}

# ---- roll up to proposed roots ----------------------------------------
$rollup = @{}
foreach ($d in $dirList) {
    foreach ($lvl in 1, 2) {
        $a = Get-Ancestor -Path $d.Path -Levels $lvl
        if (-not $rollup.ContainsKey($a)) {
            $rollup[$a] = [pscustomobject]@{ Path = $a; Count = 0; Bytes = [int64]0; Newest = [datetime]'1900-01-01' }
        }
        $rollup[$a].Count += $d.Count
        $rollup[$a].Bytes += $d.Bytes
        if ($d.Newest -gt $rollup[$a].Newest) { $rollup[$a].Newest = $d.Newest }
    }
}

$proposedRoots = @()
if ($totalFiles -gt 0) {
    $ranked = $rollup.Values | Sort-Object -Property `
        @{ Expression = 'Count'; Descending = $true }, `
        @{ Expression = { $_.Path.Length }; Descending = $true }
    $covered = 0
    foreach ($r in $ranked) {
        if ($proposedRoots.Count -ge 4) { break }
        if ($covered -ge ($totalFiles * 0.95)) { break }
        $isChild = $false
        foreach ($p in $proposedRoots) {
            if ($r.Path.ToLower().StartsWith($p.ToLower().TrimEnd('\') + '\')) { $isChild = $true; break }
        }
        if ($isChild) { continue }
        $proposedRoots += $r.Path
        $covered += $r.Count
    }
    Say ""
    $pct = [math]::Round(100 * $covered / [Math]::Max(1, $totalFiles))

    # If per-folder roots miss a lot of the data, the folders are not the
    # natural unit -- data organised as <drive>:\<person>\<experiment> has as
    # many top folders as there are people, and no useful subset of four.
    # Fall back to the drives that actually hold data.
    if ($pct -lt 80) {
        $driveRoots = @($dirList | ForEach-Object {
            Get-DriveRoot $_.Path } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
        if ($driveRoots.Count -gt 0 -and $driveRoots.Count -le 6) {
            Warn ("Folder-level roots covered only {0}% of the files, so the data is spread" -f $pct)
            Note "across too many top-level folders to pick four. Proposing the drives instead."
            $proposedRoots = $driveRoots
            $covered = $totalFiles
            $pct = 100
        }
    }

    # Policy: never propose the system drive (see Remove-SystemDriveRoots).
    $beforeCount = $proposedRoots.Count
    $proposedRoots = Remove-SystemDriveRoots -Roots $proposedRoots -SystemDrive $env:SystemDrive
    if ($proposedRoots.Count -lt $beforeCount) {
        Note ("Left the system drive {0}\ out of data_roots (policy)." -f ($env:SystemDrive).TrimEnd('\'))
    }
    if ($proposedRoots.Count -eq 0) {
        Warn "After excluding the system drive, no data roots remain to propose."
        Note "All detected data appears to be on the system drive. Set [paths] data_roots by hand."
    }

    Say ("  Proposed data_roots (covering about {0}% of the files found):" -f $pct) "White"
    foreach ($p in $proposedRoots) { Say ("    {0}" -f $p) "Green" }
    Warn "CHECK THESE. A root that is too broad makes snapshots slow; too narrow and changes are missed."
}

$script:Data.DataScan = [ordered]@{
    Extension = $primaryExt; TotalFiles = $totalFiles
    DirectoriesWithFiles = $dirList.Count; Truncated = $census.Truncated
    SecondsSpent = $census.Seconds
    TopDirectories = @($dirList | Select-Object -First 25 | ForEach-Object {
        [ordered]@{ Path = $_.Path; Count = $_.Count; MB = [math]::Round($_.Bytes / 1MB, 1)
                    Newest = $_.Newest.ToString("yyyy-MM-dd"); Oldest = $_.Oldest.ToString("yyyy-MM-dd") } })
    ProposedRoots = $proposedRoots
}

# ---------------------------------------------------------------- 6. network

Head "6.  Network shares"
$netCandidates = @()
try {
    foreach ($d in (Get-CimInstance Win32_MappedLogicalDisk -ErrorAction SilentlyContinue)) {
        $netCandidates += [pscustomobject]@{ Local = $d.DeviceID; Unc = $d.ProviderName; How = "mapped drive" }
    }
} catch { }
try {
    foreach ($m in (Get-SmbMapping -ErrorAction SilentlyContinue)) {
        if ($netCandidates.Unc -notcontains $m.RemotePath) {
            $netCandidates += [pscustomobject]@{ Local = $m.LocalPath; Unc = $m.RemotePath; How = "SMB mapping" }
        }
    }
} catch { }

if ($netCandidates.Count -eq 0) {
    Warn "No mapped network drives found for this user."
    Note "ISG-NIS-Helper works fine fully local -- leave [paths] network_root blank --"
    Note "but then each scope keeps its own logs and nothing is pooled."
}

$netResults = @()
foreach ($n in $netCandidates) {
    $target = if ($n.Unc) { $n.Unc } else { $n.Local }
    $reachable = $false; $writable = $false; $err = ""
    try { $reachable = Test-Path -LiteralPath $target } catch { $err = $_.Exception.Message }

    if ($reachable -and -not $NoWriteTest) {
        $probe = Join-Path $target ("ISG-NIS-Helper-writetest-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".tmp")
        try {
            Set-Content -LiteralPath $probe -Value "ISG-NIS-Helper write test" -ErrorAction Stop
            $writable = Test-Path -LiteralPath $probe
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        } catch { $err = $_.Exception.Message }
    }

    Say ("    {0,-5} {1}" -f $n.Local, $target)
    if ($reachable) { Good "reachable" } else { Bad ("not reachable  " + $err) }
    if (-not $NoWriteTest) {
        if ($writable) { Good "writable (test file created and deleted)" }
        elseif ($reachable) { Bad ("read-only or permission denied  " + $err) }
    }
    $netResults += [ordered]@{ Local = $n.Local; Unc = $n.Unc; How = $n.How
                               Reachable = $reachable; Writable = $writable; Error = $err }
}
$script:Data.Network = $netResults

$bestShare = ($netResults | Where-Object { $_.Writable } | Select-Object -First 1)
$proposedNetworkRoot = ""
if ($bestShare) {
    $base = if ($bestShare.Unc) { $bestShare.Unc } else { $bestShare.Local }
    $proposedNetworkRoot = (Join-Path $base "ISG-NIS-Helper")
    Say ""
    Good "Proposed network_root: $proposedNetworkRoot"
    Note "ISG-NIS-Helper creates that subfolder itself. users.csv goes directly inside it."
}

# ---------------------------------------------------------------- 7. python

Head "7.  Python and conda"
$py = [ordered]@{ Python = $null; Py = $null; Conda = $null; Pip = $null
                  StoreStub = $false; Launchers = @() }

foreach ($name in "python", "python3", "py", "conda", "pip") {
    $cmds = @(Get-Command $name -ErrorAction SilentlyContinue)
    foreach ($c in $cmds) {
        $src = $c.Source
        Item $name $src
        if ($src -like "*WindowsApps*") { $py.StoreStub = $true }
        switch ($name) {
            "python"  { if (-not $py.Python) { $py.Python = $src } }
            "python3" { if (-not $py.Python) { $py.Python = $src } }
            "py"      { if (-not $py.Py)     { $py.Py = $src } }
            "conda"   { if (-not $py.Conda)  { $py.Conda = $src } }
            "pip"     { if (-not $py.Pip)    { $py.Pip = $src } }
        }
    }
    if ($cmds.Count -eq 0) { Item $name "not found" }
}

try {
    $vers = & py -0p 2>$null
    if ($vers) { $py.Launchers = @($vers); Say "  py launcher knows about:"; foreach ($v in $vers) { Say ("    " + $v) } }
} catch { }

try { if ($py.Python) { Item "python --version" (& $py.Python --version 2>&1) } } catch { }

if ($py.StoreStub) {
    Warn "'python' resolves into WindowsApps -- that is the Microsoft Store placeholder,"
    Note "not a real Python. See the setup manual: turn off the App Execution Aliases"
    Note "for python.exe / python3.exe, or install from python.org and tick 'Add to PATH'."
}
if (-not $py.Python -and -not $py.Conda) {
    Note "No Python here. That is fine -- only the ONE machine you build on needs it."
    Note "Microscope PCs run the compiled .exe and need nothing installed."
}
$script:Data.Python = $py

# ---------------------------------------------------------------- 8. time

Head "8.  Clock and time synchronisation"
Item "Local time" (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
Item "UTC time" (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
$timeSource = ""; $timeStatus = ""
try { $timeSource = (& w32tm /query /source 2>&1) -join " " } catch { }
try { $timeStatus = (& w32tm /query /status 2>&1 | Select-String "Source|Last Successful|Stratum") -join " | " } catch { }
Item "Time source" $timeSource
Item "Sync status" $timeStatus
if ($timeSource -match "Local CMOS|Free-running|not been started") {
    Note "This clock is free-running rather than synchronised. That only matters"
    Note "if it drifts by hours; both local time and UTC are recorded either way."
}
$script:Data.Time = [ordered]@{ Source = $timeSource; Status = $timeStatus
                                Local = (Get-Date).ToString("s"); Utc = (Get-Date).ToUniversalTime().ToString("s") }

# ---------------------------------------------------------------- 9. existing

Head "9.  Existing ISG-NIS-Helper installation"
$existing = [ordered]@{ ProgramData = $false; TaskAgent = $false; TaskWatch = $false; Sessions = 0 }
$pd = "C:\ProgramData\ISG-NIS-Helper"
$existing.ProgramData = Test-Path -LiteralPath $pd
foreach ($t in @(@("ISG-NIS-Helper-Agent", "TaskAgent"), @("ISG-NIS-Helper-Svc", "TaskWatch"))) {
    $out = & schtasks /query /TN $t[0] 2>$null
    $existing[$t[1]] = ($LASTEXITCODE -eq 0)
}
if ($existing.ProgramData) {
    # Only real session files, which live under logs\. Counting every .csv
    # here used to include users_template.csv and report a clean machine as
    # having sessions.
    $logsDir = Join-Path $pd "logs"
    if (Test-Path -LiteralPath $logsDir) {
        $existing.Sessions = @(Get-ChildItem -LiteralPath $logsDir -Recurse -Filter "*.csv" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '_files\.csv$' -and $_.Name -ne 'index.csv' }).Count
    }
    $stray = @(Get-ChildItem -LiteralPath $pd -Filter "*.ps1" -ErrorAction SilentlyContinue)
    if ($stray.Count) {
        Warn "$pd also contains program files (build.ps1 and friends)."
        Note "That folder is the LOG STORE. A copy of the program there is stray"
        Note "and should be deleted -- keep only session.json, logs\, pins\."
    }
}
foreach ($k in $existing.Keys) { Item $k $existing[$k] }
if ($existing.TaskAgent -or $existing.TaskWatch) {
    Warn "ISG-NIS-Helper is already installed here. install.bat will replace the tasks; logs are kept."
} else { Good "Clean machine, nothing to remove first." }
$script:Data.Existing = $existing

# ---------------------------------------------------------------- 10. config

Head "10.  Generated configuration"

$masterPin = (Get-Random -Minimum 100000 -Maximum 999999).ToString()
$bestNis = if ($nisCandidates.Count -gt 0) { $nisCandidates[0].Path } else { "<<<SET_ME: full path to the NIS-Elements .exe>>>" }
$rootsLine = if ($proposedRoots.Count -gt 0) { ($proposedRoots -join "; ") } else { "<<<SET_ME: folder(s) NIS-Elements exports into>>>" }
# Optional, so never a placeholder -- a blank here is a valid, working
# configuration. A writable share becomes a suggestion in a comment.
$netLine = ""
$netComment = ""
if ($proposedNetworkRoot) {
    $netComment = "`r`n;   a writable share was found here: " + $proposedNetworkRoot
}

$alt = ""
if ($nisCandidates.Count -gt 1) {
    $alt = "`r`n" + (($nisCandidates | Select-Object -Skip 1 | ForEach-Object { ";   alternative: " + $_.Path }) -join "`r`n")
}
$altRoots = ""
if ($dirList.Count -gt 0) {
    $altRoots = "`r`n" + (($dirList | Select-Object -First 8 | ForEach-Object {
        ";   {0,7} files  newest {1}   {2}" -f $_.Count, $_.Newest.ToString("yyyy-MM-dd"), $_.Path }) -join "`r`n")
}

$cfg = @"
; =====================================================================
;  ISG-NIS-Helper configuration -- GENERATED by ISG-NIS-Helper-PreScan.ps1
;  Computer : $pc
;  Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm")
;
;  REVIEW THIS BEFORE USING IT. The pre-scan guesses from evidence on
;  disk and can be wrong. Anything it could not determine is left as
;  <<<SET_ME ...>>> and ISG-NIS-Helper refuses to open a session until fixed.
;
;  When you are happy, save this as config.ini in the ISG-NIS-Helper folder.
;  install.bat offers to do that, and preserves anything you have
;  already filled in by hand.
; =====================================================================

[instrument]
; The name you gave at scan time. Edit here if it needs changing.
computer_label   = $scopeLabel
computer_id      =
display_name     = Microscope Access Log

[paths]
; Best guess from: $(if ($nisCandidates.Count -gt 0) { $nisCandidates[0].How } else { "nothing found" })$alt
nis_executable   = $bestNis

; Rolled up from a census of $primaryExt files ($totalFiles found).$altRoots
data_roots       = $rootsLine

; Blank = users.csv next to this file. Each instrument keeps its own list.
users_file       =

local_root       = C:\ProgramData\ISG-NIS-Helper

; OPTIONAL mirror for finished logs. Blank = local only. ISG-NIS-Helper never
; reads from here and never depends on it.$netComment
network_root     = $netLine

[processes]
nis_process_names   = $($procNames -join ", ")
gate_viewer         = false
viewer_process_names = nis_viewer.exe, nis-elements viewer.exe

[behavior]
launch_grace_seconds  = 120
poll_seconds          = 3
heartbeat_seconds     = 15
handoff_grace_seconds = 300
write_master_index    = true
max_detail_rows       = 50000
fullscreen_signin     = false
badge_corner          = br

[scan]
exclude_dirs       = `$RECYCLE.BIN; System Volume Information; Windows; Program Files; Program Files (x86); AppData; ProgramData; `$WinREAgent; Recovery
include_extensions =
follow_symlinks    = false

[failsafe]
confirm_polls             = 3
post_update_grace_hours   = 24
max_terminations_per_hour = 3
max_errors_per_10min      = 10
require_agent             = true
agent_silence_seconds     = 120

[contacts]
admin1_name  = Andrew Bazley
admin1_email = Andrew.Bazley@nyulangone.org
admin2_name  = Guru Kidiyoor
admin2_email = gururaj.kidiyoor@nyulangone.org

[access]
; Randomly generated. Write it down; managers only.
master_pin = $masterPin
"@

$cfgPath = Join-Path $OutDir "config.generated.ini"
# UTF-8 without a BOM: a BOM breaks Python configparser on the adopted file.
[System.IO.File]::WriteAllText($cfgPath, $cfg, (New-Object System.Text.UTF8Encoding($false)))
Good "Wrote $cfgPath"
Say ""
Say "    MASTER PIN for this machine: $masterPin" "Yellow"
Say "    Write it down now. It is in config.generated.ini as well." "DarkGray"

$script:Data.Generated = [ordered]@{
    ConfigPath = $cfgPath; MasterPin = $masterPin
    NisExecutable = $bestNis; DataRoots = $proposedRoots; NetworkRoot = $netLine
}

# ---------------------------------------------------------------- 11. verdict

Head "11.  Ready to install?"
$blockers = @()
if ($nisCandidates.Count -eq 0) { $blockers += "NIS-Elements executable not found" }
if ($totalFiles -eq 0)          { $blockers += "no image data folders identified" }
if (@($nisCandidates | Where-Object { $_.IsNisApp }).Count -gt 1) { $blockers += "more than one acquisition module -- confirm which one is used" }
if ($census.Truncated)          { $blockers += "data census hit its time budget and is incomplete" }
# A share is optional now, so its absence is not a blocker.

if ($blockers.Count -eq 0) {
    Good "Nothing needs a human decision. Review config.generated.ini and install."
} else {
    Warn "Check these before installing:"
    foreach ($b in $blockers) { Say ("      - " + $b) "Yellow" }
}
$script:Data.Blockers = $blockers

# ---------------------------------------------------------------- write out

$txtPath  = Join-Path $OutDir ("ISG-NIS-Helper-PreScan_{0}_{1}.txt" -f $pc, $stamp)
$jsonPath = Join-Path $OutDir "prescan.json"
$script:Lines -join "`r`n" | Set-Content -LiteralPath $txtPath -Encoding UTF8
$script:Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

Say ""
Say ("=" * 70) "DarkGray"
Say "  Done. Three files written to:" "White"
Say ("    " + $OutDir) "White"
Say ""
Say "    ISG-NIS-Helper-PreScan_..._.txt   the report you are reading" "Gray"
Say "    prescan.json                 the same thing, machine-readable" "Gray"
Say "    config.generated.ini         a config to review, then adopt" "Gray"
Say ""
Say "  NEXT: send the .txt file (or just sections 4, 5 and 6) for review" "Cyan"
Say "  before running install.bat. The paths are the part worth checking." "Cyan"
Say ("=" * 70) "DarkGray"
Say ""
