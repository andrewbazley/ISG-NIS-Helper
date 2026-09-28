<#
  ISG-NIS-Helper pre-scan self-test.

  Loads the two path-handling functions out of ISG-NIS-Helper-PreScan.ps1 and
  exercises them against a temporary folder tree it builds itself. These
  are the functions that decide which folders end up in data_roots, so
  getting them wrong means logging the wrong thing quietly.

      powershell -NoProfile -ExecutionPolicy Bypass -File selftest-prescan.ps1

  Builds and deletes a tree under your TEMP folder. Touches nothing else.
#>

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here "ISG-NIS-Helper-PreScan.ps1"
if (-not (Test-Path -LiteralPath $src)) { Write-Host "ISG-NIS-Helper-PreScan.ps1 not found next to this script." -ForegroundColor Red; exit 2 }

$e = $null; $t = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$t, [ref]$e)
if ($e.Count) {
    Write-Host "ISG-NIS-Helper-PreScan.ps1 has parse errors:" -ForegroundColor Red
    $e | ForEach-Object { "  line $($_.Extent.StartLineNumber): $($_.Message)" }
    exit 1
}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($f.Name -in @("Get-FileCensus", "Get-Ancestor", "Remove-SystemDriveRoots")) { Invoke-Expression $f.Extent.Text }
}

$script:fail = 0
function T($label, $cond) {
    if ($cond) { Write-Host "  PASS  $label" -ForegroundColor Green }
    else { Write-Host "  FAIL  $label" -ForegroundColor Red; $script:fail++ }
}

Write-Host ""
Write-Host "-- Get-Ancestor (decides how data_roots are rolled up)" -ForegroundColor Cyan
T "drive path, level 1"              ((Get-Ancestor 'D:\ImagingData\2026-09-21\SampleB' 1) -eq 'D:\ImagingData')
T "drive path, level 2"              ((Get-Ancestor 'D:\ImagingData\2026-09-21\SampleB' 2) -eq 'D:\ImagingData\2026-09-21')
T "never rolls up to the bare drive" ((Get-Ancestor 'D:\ImagingData' 1) -eq 'D:\ImagingData')
T "trailing separator tolerated"     ((Get-Ancestor 'D:\ImagingData\Sub\' 1) -eq 'D:\ImagingData')
T "forward slashes tolerated"        ((Get-Ancestor 'D:/ImagingData/Sub' 1) -eq 'D:\ImagingData')
T "UNC share, level 1"               ((Get-Ancestor '\\srv\share\Data\Sub' 1) -eq '\\srv\share\Data')
T "UNC share, level 2"               ((Get-Ancestor '\\srv\share\Data\Sub' 2) -eq '\\srv\share\Data\Sub')
T "levels beyond depth clamp"        ((Get-Ancestor 'C:\A' 5) -eq 'C:\A')
T "empty input survives"             ((Get-Ancestor '' 1) -eq '')

$tempBase = $env:TEMP
if (-not $tempBase) { $tempBase = [System.IO.Path]::GetTempPath() }
$root = Join-Path $tempBase ("sgtest-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$treeBuilt = $false
try {
    foreach ($d in @("Data\2026-09-20\SampleA", "Data\2026-09-21\SampleB", "Data\Archive",
                     "Profiles\lab\Documents\NIS", "Junk\node_modules\deep")) {
        New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
    }
    function Fill($rel, $n) {
        1..$n | ForEach-Object { Set-Content -LiteralPath (Join-Path (Join-Path $root $rel) "f$_.nd2") -Value "x" }
    }
    Fill "Data\2026-09-20\SampleA" 40
    Fill "Data\2026-09-21\SampleB" 55
    Fill "Data\Archive" 12
    Fill "Profiles\lab\Documents\NIS" 7
    Fill "Junk\node_modules\deep" 99
    Set-Content -LiteralPath (Join-Path $root "Data\2026-09-21\SampleB\notes.txt") -Value "not an image"
    $treeBuilt = $true

    Write-Host ""
    Write-Host "-- Get-FileCensus (counts data files, skips what it should)" -ForegroundColor Cyan
    $c = Get-FileCensus -Roots @($root) -Extensions @(".nd2") -BudgetSeconds 60 -Depth 12 -ExcludeNames @("node_modules")
    $dirs = @($c.Dirs); $total = ($dirs | Measure-Object Count -Sum).Sum
    foreach ($d in $dirs) { "    {0,5}  {1}" -f $d.Count, $d.Path }
    T "excluded directory not walked" ($total -eq 114)
    T "four directories with data"    ($dirs.Count -eq 4)
    T "sorted busiest first"          ($dirs[0].Count -eq 55)
    T "other extensions ignored"      (-not ($dirs | Where-Object { $_.Path -like "*notes*" }))
    T "finished within budget"        (-not $c.Truncated)

    Write-Host ""
    Write-Host "-- proposed data_roots" -ForegroundColor Cyan
    # Fed synthetic Windows-shaped paths rather than the temp tree: the
    # rollup works in levels below the DRIVE ROOT, and a tree buried under
    # %TEMP% is already four levels down, so it could not exercise this.
    $sample = @(
        [pscustomobject]@{ Path = 'D:\ImagingData\2026-09-21\SampleB';      Count = 55 }
        [pscustomobject]@{ Path = 'D:\ImagingData\2026-09-20\SampleA';      Count = 40 }
        [pscustomobject]@{ Path = 'D:\ImagingData\Archive';                  Count = 12 }
        [pscustomobject]@{ Path = 'D:\Profiles\lab\Documents\NIS';          Count = 7  }
    )
    $sTotal = ($sample | Measure-Object Count -Sum).Sum
    $rollup = @{}
    foreach ($d in $sample) { foreach ($lvl in 1, 2) {
        $a = Get-Ancestor -Path $d.Path -Levels $lvl
        if (-not $rollup.ContainsKey($a)) { $rollup[$a] = [pscustomobject]@{ Path = $a; Count = 0 } }
        $rollup[$a].Count += $d.Count } }
    $ranked = $rollup.Values | Sort-Object -Property `
        @{ Expression = "Count"; Descending = $true }, @{ Expression = { $_.Path.Length }; Descending = $true }
    $proposed = @(); $covered = 0
    foreach ($r in $ranked) {
        if ($proposed.Count -ge 4) { break }
        if ($covered -ge ($sTotal * 0.95)) { break }
        $isChild = $false
        foreach ($p in $proposed) { if ($r.Path.ToLower().StartsWith($p.ToLower().TrimEnd('\') + '\')) { $isChild = $true; break } }
        if ($isChild) { continue }
        $proposed += $r.Path; $covered += $r.Count
    }
    $proposed | ForEach-Object { "    $_" }
    T "picks the ImagingData parent, not each leaf" ($proposed -contains 'D:\ImagingData')
    T "picks up the stray Documents tree"           (($proposed | Where-Object { $_ -like 'D:\Profiles*' }).Count -eq 1)
    T "tie-break chose the narrower path"           ($proposed -contains 'D:\Profiles\lab')
    T "covers at least 95% of files"                ($covered -ge $sTotal * 0.95)
    T "no root nested inside another"               ((@($proposed | Where-Object { $p = $_; ($proposed | Where-Object { $_ -ne $p -and $p.StartsWith($_ + '\') }) })).Count -eq 0)
    T "proposal stays short"                        ($proposed.Count -le 4)

    # --- system-drive exclusion (data_roots never proposes C:\) ---
    $mixed = @("C:\", "D:\", "E:\", "F:\")
    $keptDrives = Remove-SystemDriveRoots -Roots $mixed -SystemDrive "C:"
    T "drops the C:\ drive root"                     (-not ($keptDrives -contains "C:\"))
    T "keeps the data drives"                        (($keptDrives -contains "D:\") -and ($keptDrives -contains "E:\") -and ($keptDrives -contains "F:\"))
    $folders = @("C:\Users\Nikon\Desktop", "D:\Andrew B", "E:\Guru")
    $keptFolders = Remove-SystemDriveRoots -Roots $folders -SystemDrive "C:"
    T "drops folders on the system drive"            (-not ($keptFolders | Where-Object { $_ -like 'C:*' }))
    T "keeps folders on data drives"                 ($keptFolders.Count -eq 2)
    T "case-insensitive on the drive letter"         ((Remove-SystemDriveRoots -Roots @("c:\junk","D:\ok") -SystemDrive "C:").Count -eq 1)
    T "empty system drive leaves the list untouched" ((Remove-SystemDriveRoots -Roots @("D:\","E:\") -SystemDrive "").Count -eq 2)
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if (-not $treeBuilt) {
    Write-Host "  COULD NOT BUILD THE TEST TREE -- no checks were run." -ForegroundColor Red
    Write-Host "  A green result above would have been meaningless." -ForegroundColor Red
    exit 1
}
if ($script:fail) { Write-Host "  $($script:fail) CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "  all pre-scan checks passed" -ForegroundColor Green
Write-Host ""
exit 0
