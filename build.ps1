<#
=======================================================================
 build.ps1  --  compile the two ISG-NIS-Helper executables

 Run it through build.bat, or directly:
     powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1

 If you are using conda, activate the environment FIRST and then run
 build.bat by typing its name in that same window. Double-clicking it
 opens a fresh shell with no environment active.

 Everything printed here is also written to install-logs\<stamp>_build.txt.

 This is a PowerShell script rather than a batch file on purpose. The
 earlier version invoked PowerShell from inside batch, and quoting a
 pipe through cmd's parser is a reliable source of bugs that only show
 up on the target machine.
=======================================================================
#>

[CmdletBinding()]
param(
    [switch] $SkipDeps
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

function Test-Writable {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
        $probe = Join-Path $Path (".w" + [guid]::NewGuid().ToString("N").Substring(0, 6))
        Set-Content -LiteralPath $probe -Value "x" -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

$script:ProductVersion = "unknown"
try {
    $vm = [regex]::Match((Get-Content -LiteralPath (Join-Path $here "isg_common.py") -Raw),
                         'VERSION\s*=\s*"([^"]+)"')
    if ($vm.Success) { $script:ProductVersion = $vm.Groups[1].Value }
} catch { }

$stamp  = Get-Date -Format "yyyy-MM-dd_HHmm"
$logDir = Resolve-LogRoot (Join-Path $here "install-logs")
$log = Join-Path $logDir ("{0}_build.txt" -f $stamp)

# PyInstaller writes the .spec file, its work folder and dist\ next to the
# source. A folder under C:\Program Files is not writable, so building in
# place there fails with PermissionError on the .spec. Put the whole build
# workspace somewhere writable instead and say so.
$hereWritable = Test-Writable $here
if ($hereWritable) {
    $buildBase = $here
} else {
    $buildBase = Join-Path $env:TEMP "ISG-NIS-Helper-build"
    if (-not (Test-Path -LiteralPath $buildBase)) {
        New-Item -ItemType Directory -Path $buildBase -Force | Out-Null
    }
}
$specPath  = $buildBase
$workPath  = Join-Path $buildBase "build"
$distAgent = Join-Path $buildBase "dist_agent"
$distWatch = Join-Path $buildBase "dist_watch"
$dist      = Join-Path $buildBase "dist\ISG-NIS-Helper"

# Tee-Object has no -Encoding parameter in Windows PowerShell 5.1 and writes
# UTF-16, while Add-Content defaults to ANSI. Mixing them produced a log file
# that reads as "P y t h o n   3 . 1 4 . 7". Everything goes through here now.
function Write-Log { param([string]$Text = "")
    try { Add-Content -LiteralPath $log -Value $Text -Encoding UTF8 } catch { }
}
function Head { param($t)
    $line = "`r`n=== $t " + ("=" * [Math]::Max(0, 66 - $t.Length))
    Write-Host $line -ForegroundColor Cyan
    Write-Log $line
}
function Note { param($t = "")
    Write-Host $t
    Write-Log $t
}
function Warn { param($t)
    Write-Host ("  [ !! ]   " + $t) -ForegroundColor Yellow
    Write-Log ("  [ !! ]   " + $t)
}
function Fail { param($t)
    Write-Host ""
    Write-Host "  BUILD FAILED: $t" -ForegroundColor Red
    Write-Host "  Full log: $log" -ForegroundColor DarkGray
    Write-Log ("BUILD FAILED: " + $t)
    exit 1
}

# Run a native command, showing its output live AND appending it to the
# log, and return its exit code.
function Invoke-Logged {
    param([string]$Exe, [string[]]$Arguments)
    Write-Log ("`r`n> $Exe " + ($Arguments -join " "))
    # PyInstaller writes its ordinary INFO lines to stderr. With 2>&1 those
    # arrive as ErrorRecords, and PowerShell renders them as red
    # NativeCommandError blocks -- which makes a perfectly healthy build look
    # like it is failing. Flattening each object to a string avoids that and
    # keeps the output streaming live.
    & $Exe @Arguments 2>&1 | ForEach-Object {
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { [string]$_ }
        Write-Host $line
        Write-Log $line
    }
    return $LASTEXITCODE
}

if (-not $hereWritable) {
    Write-Host ""
    Write-Host "  NOTE: this folder is not writable, so the build workspace is" -ForegroundColor Yellow
    Write-Host ("        " + $buildBase) -ForegroundColor Yellow
    Write-Host "        That is normal under C:\Program Files. The program folder" -ForegroundColor DarkGray
    Write-Host "        is where ISG-NIS-Helper is INSTALLED; it is not a build folder." -ForegroundColor DarkGray
}

Set-Content -LiteralPath $log -Value ("ISG-NIS-Helper build  {0}  version {1}  on {2} by {3}`r`n  source: {4}" -f
    $stamp, $script:ProductVersion, $env:COMPUTERNAME, $env:USERNAME, $here) -Encoding UTF8

# ---------------------------------------------------------------- sanity
# Running a stale copy of the program out of the log store is an easy and
# expensive mistake: the build looks like it works and produces old code.
# C:\ProgramData\ISG-NIS-Helper is where ISG-NIS-Helper WRITES; it is never a place
# to build from.
$progData = $env:ProgramData
if ($progData -and $here.ToLower().StartsWith((Join-Path $progData "ISG-NIS-Helper").ToLower())) {
    Fail ("this is the LOG STORE, not a program folder:`r`n    " + $here +
          "`r`n  A copy of the program here is stray. Delete everything in it" +
          "`r`n  except logs\, then build from a writable folder such as the Desktop.")
}

Write-Host ""
Write-Host ("  ISG-NIS-Helper build " + $script:ProductVersion) -ForegroundColor White
Write-Host ("  from " + $here) -ForegroundColor DarkGray

# ---------------------------------------------------------------- python
Head "Python environment"
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { Fail "python is not on PATH. Activate your environment first (see manual 3.4)." }
if ($py.Source -like "*WindowsApps*") {
    Fail ("python resolves to the Microsoft Store placeholder:`r`n    " + $py.Source +
          "`r`n  Turn off the App Execution Aliases for python.exe, or install from python.org.")
}
Note ("  python : " + $py.Source)
Invoke-Logged $py.Source @("--version") | Out-Null

Note "  checking tkinter (the sign-in window needs it)..."
$code = Invoke-Logged $py.Source @("-c", "import tkinter; r=tkinter.Tk(); r.destroy(); print('tkinter OK')")
if ($code -ne 0) {
    Fail ("tkinter does not work in this environment. With conda:  conda install tk`r`n" +
          "  Building without it produces an agent that dies at launch.")
}

# ---------------------------------------------------------------- deps
if (-not $SkipDeps) {
    Head "Build dependencies"
    $code = Invoke-Logged $py.Source @("-m", "pip", "install", "--upgrade", "pyinstaller", "psutil")
    if ($code -ne 0) { Fail "pip could not install pyinstaller and psutil. See manual 3.6." }
}

# ---------------------------------------------------------------- build
Head "Building isg-nis-helper-agent.exe"
$code = Invoke-Logged $py.Source @(
    "-m", "PyInstaller", "--noconfirm", "--clean", "--windowed", "--onedir",
    "--name", "isg-nis-helper-agent",
    "--specpath", $specPath, "--workpath", $workPath, "--distpath", $distAgent,
    (Join-Path $here "isg_agent.py"))
if ($code -ne 0) { Fail "PyInstaller failed on the agent." }

Head "Building isg-nis-helper-svc.exe"
$code = Invoke-Logged $py.Source @(
    "-m", "PyInstaller", "--noconfirm", "--clean", "--console", "--onedir",
    "--name", "isg-nis-helper-svc",
    "--specpath", $specPath, "--workpath", $workPath, "--distpath", $distWatch,
    (Join-Path $here "isg_watch.py"))
if ($code -ne 0) { Fail "PyInstaller failed on the watcher." }

# ---------------------------------------------------------------- assemble
Head "Assembling dist\ISG-NIS-Helper"
if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist -Force | Out-Null

# Order matters. Both builds produce an _internal folder holding the Python
# DLL, base_library.zip and the extension modules. The agent's is a superset
# (it carries Tcl/Tk), so it is copied LAST and wins any collision. Copying
# it first would let the watcher's smaller build overwrite shared files,
# which fails at runtime rather than at build time.
foreach ($full in @((Join-Path $distWatch "isg-nis-helper-svc"),
                    (Join-Path $distAgent "isg-nis-helper-agent"))) {
    if (-not (Test-Path -LiteralPath $full)) { Fail "expected build output missing: $full" }
    Copy-Item -Path (Join-Path $full '*') -Destination $dist -Recurse -Force
}

$files = @(
    "config.ini", "users_template.csv",
    "install.bat", "install.ps1", "uninstall.bat", "uninstall.ps1",
    "build.bat", "build.ps1", "README.md",
    "ISG-NIS-Helper-PreScan.ps1", "ISG-NIS-Helper-Preflight.ps1", "ISG-NIS-Helper-Collect.ps1",
    "Run-PreScan.bat", "Run-Collect.bat",
    "selftest.py", "selftest-prescan.ps1", "selftest-nisdetect.ps1"
)
foreach ($f in $files) {
    if (Test-Path -LiteralPath (Join-Path $here $f)) {
        Copy-Item -LiteralPath (Join-Path $here $f) -Destination $dist -Force
    }
}
Copy-Item -Path (Join-Path $here "isg_*.py") -Destination $dist -Force
New-Item -ItemType Directory -Path (Join-Path $dist "tasks") -Force | Out-Null
Copy-Item -Path (Join-Path $here "tasks\*.xml") -Destination (Join-Path $dist "tasks") -Force
if (Test-Path -LiteralPath (Join-Path $here "docs")) {
    Copy-Item -LiteralPath (Join-Path $here "docs") -Destination $dist -Recurse -Force
}

# ---------------------------------------------------------------- verify
Head "Checking the assembled folder"
$missing = @()
foreach ($exe in @("isg-nis-helper-agent.exe", "isg-nis-helper-svc.exe")) {
    $p = Join-Path $dist $exe
    if (Test-Path -LiteralPath $p) {
        $fi = Get-Item -LiteralPath $p
        Note ("  {0,-22} {1:N0} bytes" -f $fi.Name, $fi.Length)
    } else { $missing += $exe }
}
if ($missing.Count) { Fail ("missing from dist\ISG-NIS-Helper: " + ($missing -join ", ")) }

# ---------------------------------------------------------------- package
Head "Packaging"
$version = $script:ProductVersion
$zip = Join-Path $buildBase ("ISG-NIS-Helper-{0}.zip" -f $version)
try {
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $zip -Force
    Note ("  " + $zip)
    Note "  This zip is the whole program. Copy it to any microscope PC,"
    Note "  unzip it into C:\ISG-NIS-Helper, and run install.bat."
    Note "  Nothing on that machine needs Python."
} catch {
    Warn ("could not create the zip: " + $_.Exception.Message)
    Note ("  Copy the folder instead: " + $dist)
}

Note ""
Note "  SMOKE TEST -- run this now, before copying anything anywhere:"
Note ("      " + (Join-Path $dist "isg-nis-helper-agent.exe"))
Note "  A window listing the unset <<<SET_ME>>> keys proves tkinter survived"
Note "  freezing, the config parser works, and the placeholder guard fires."
Note "  The agent is windowed and has no console: if nothing happens at all,"
Note "  run  python isg_agent.py  here to see the traceback."
Note ""
Note ("  Build log: " + $log)
Write-Host ""
Write-Host ("Build complete: " + $dist) -ForegroundColor Green
Write-Host "Copy that folder to each microscope PC." -ForegroundColor Green
Write-Host ""
exit 0
