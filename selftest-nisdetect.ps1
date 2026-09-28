<#
  ISG-NIS-Helper NIS-detection self-test.

  Replays the real candidate list from a Nikon Ti2 workstation through the
  pre-scan's scoring, and asserts that the acquisition application wins and
  that permanently-running services are never gated.

  The fixture is not invented. On that machine the pre-scan's first version
  nominated the NIS Settings Utility as the microscope software, and swept
  Windows Defender's NisSrv.exe, two National Instruments services and the
  Control Panel into the list of processes to gate. Gating a service that
  never stops means sessions that never end and a watcher trying to kill it
  on a loop. These checks exist so that cannot come back.

      powershell -NoProfile -ExecutionPolicy Bypass -File selftest-nisdetect.ps1

  Reads only. Creates nothing.
#>

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here "ISG-NIS-Helper-PreScan.ps1"
if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "ISG-NIS-Helper-PreScan.ps1 not found next to this script." -ForegroundColor Red; exit 2
}
$e = $null; $t = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$t, [ref]$e)
if ($e.Count) { $e | ForEach-Object { "PARSE line $($_.Extent.StartLineNumber): $($_.Message)" }; exit 1 }
"ISG-NIS-Helper-PreScan.ps1 parses cleanly"

# pull the real scoring functions and the real constants out of the real file
$raw = Get-Content -LiteralPath $src -Raw
foreach ($m in [regex]::Matches($raw, '(?m)^\$NIS_[A-Z_]+\s*=.*$')) { Invoke-Expression $m.Value }
foreach ($f in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($f.Name -in @("Get-NisScore", "Test-NisApp", "Get-DriveRoot", "Get-LeafName")) { Invoke-Expression $f.Extent.Text }
}
if (-not $NIS_IMPOSTORS -or -not $NIS_APP_NAMES -or -not $NIS_UTILITIES) {
    Write-Host "constants did not load -- every -match would be vacuously true" -ForegroundColor Red
    exit 1
}
"constants loaded: impostors, app names, utilities"


$fail = 0
function T($l, $c) { if ($c) { "  PASS  $l" } else { "  FAIL  $l"; $script:fail++ } }

# --- the EXACT candidates the real pre-scan found on DESKTOP-STQVARQ -------
$cands = @(
 [pscustomobject]@{ Path='C:\Program Files\NIS-Elements\utl_exportsettings.exe'; Name='utl_exportsettings.exe'; SizeMB=0.1; Description=$null
   How='shortcut: NIS Settings Utility' }
 [pscustomobject]@{ Path='C:\WINDOWS\system32\control.exe'; Name='control.exe'; SizeMB=0.1; Description='Windows Control Panel'
   How='shortcut: Administrative Tools' }
 [pscustomobject]@{ Path='C:\Program Files\NIS-Elements\nis_ar.exe'; Name='nis_ar.exe'; SizeMB=2.4; Description='NIS Elements'
   How='shortcut: NIS-Elements AR 5.42.06 64-bit; shortcut: NIS-Elements AR Analysis 5.42.04 64-bit; shortcut: NIS-Elements AR Analysis 5.42.06 64-bit; shortcut: NIS-Elements AR 6.10.02 64-bit; shortcut: NIS-Elements AR Analysis 6.10.02 64-bit; installed: NIS-Elements 6.10.02 LO (build 2031 64-bit); found under Program Files' }
 [pscustomobject]@{ Path='C:\Program Files\NIS-Elements\nis_ai_train.exe'; Name='nis_ai_train.exe'; SizeMB=0.6; Description='Standalone utility for training NIS.ai networks'
   How='installed: NIS-Elements 6.10.02 LO (build 2031 64-bit); found under Program Files' }
 [pscustomobject]@{ Path='C:\Program Files\Windows Defender\NisSrv.exe'; Name='NisSrv.exe'; SizeMB=4.2; Description='Microsoft Network Realtime Inspection Service'
   How='found under Program Files' }
 [pscustomobject]@{ Path='C:\Program Files (x86)\National Instruments\Shared\nisvcloc\nisvcloc.exe'; Name='nisvcloc.exe'; SizeMB=0.1; Description='NI Service Locator'
   How='found under Program Files' }
 [pscustomobject]@{ Path='C:\Program Files\National Instruments\Shared\Sync Domain\nisds.exe'; Name='nisds.exe'; SizeMB=0; Description='NI Sync Domain Service'
   How='found under Program Files' }
 [pscustomobject]@{ Path='C:\Program Files\NIS-Elements\HASP\nis_hasp_update.exe'; Name='nis_hasp_update.exe'; SizeMB=4.1; Description=''
   How='found under Program Files' }
)
foreach ($c in $cands) {
    $c | Add-Member -NotePropertyName Score    -NotePropertyValue (Get-NisScore $c) -Force
    $c | Add-Member -NotePropertyName IsNisApp -NotePropertyValue (Test-NisApp $c.Path) -Force
}
$ranked = $cands | Sort-Object Score -Descending

""
"-- ranking, DESKTOP-STQVARQ's real candidates --"
foreach ($c in $ranked) { "  {0,5}  {1,-8}  {2}" -f $c.Score, $(if($c.IsNisApp){"gate"}else{"ignore"}), $c.Path }
""
T "nis_ar.exe now ranks first"            ($ranked[0].Name -eq 'nis_ar.exe')
T "the settings utility is not the pick"  ($ranked[0].Name -ne 'utl_exportsettings.exe')
T "Control Panel scores below zero"       (($cands | Where-Object Name -eq 'control.exe').Score -lt 0)
T "Windows Defender scores below zero"    (($cands | Where-Object Name -eq 'NisSrv.exe').Score -lt 0)
T "NI Service Locator scores below zero"  (($cands | Where-Object Name -eq 'nisvcloc.exe').Score -lt 0)
T "NI Sync Domain scores below zero"      (($cands | Where-Object Name -eq 'nisds.exe').Score -lt 0)

$gated = @($cands | Where-Object IsNisApp | ForEach-Object { $_.Name.ToLower() })
"gated: $($gated -join ', ')"
T "exactly one executable is gated"       ($gated.Count -eq 1)
T "and it is nis_ar.exe"                  ($gated -contains 'nis_ar.exe')
T "Windows Defender is NOT gated"         (-not ($gated -contains 'nissrv.exe'))
T "NI services are NOT gated"             (-not ($gated -contains 'nisvcloc.exe') -and -not ($gated -contains 'nisds.exe'))
T "Control Panel is NOT gated"            (-not ($gated -contains 'control.exe'))
T "the AI trainer is NOT gated"           (-not ($gated -contains 'nis_ai_train.exe'))
T "the HASP updater is NOT gated"         (-not ($gated -contains 'nis_hasp_update.exe'))
T "the settings utility is NOT gated"     (-not ($gated -contains 'utl_exportsettings.exe'))

""
"-- shortcut name filter --"
$rx = '(\bNIS\b|NIS-Elements|Nikon|\bElements\b)'
T "'Administrative Tools' no longer matches" (-not ('Administrative Tools' -match $rx))
T "'NIS-Elements AR 6.10.02 64-bit' matches" ('NIS-Elements AR 6.10.02 64-bit' -match $rx)
T "'NIS Settings Utility' still matches"     ('NIS Settings Utility' -match $rx)
T "'Nikon Ti2 Control' matches"              ('Nikon Ti2 Control' -match $rx)
T "'Administrator Console' does not match"   (-not ('Administrator Console' -match $rx))

""
"-- data_roots fallback on the real census --"
$real = @(
  [pscustomobject]@{ Path='F:\Nongyun\20260608_P70-P85_Round1_Day2\Time'; Count=2048 }
  [pscustomobject]@{ Path='F:\Nongyun\20240802 Corelets_6'; Count=1200 }
  [pscustomobject]@{ Path='E:\Yi-Shuan\20260515_MN_MMS_recovery'; Count=1080 }
  [pscustomobject]@{ Path='E:\Henry\2026_08_12_bleach_test_fixed_cells'; Count=315 }
  [pscustomobject]@{ Path='E:\Chao-E\20250503 MSC newC 100x'; Count=285 }
  [pscustomobject]@{ Path='E:\Lance\2024_GEM_clones\20240315 GEM'; Count=282 }
  [pscustomobject]@{ Path='D:\Andrew B\20250815 WT RLTPSC'; Count=241 }
  [pscustomobject]@{ Path='E:\Guru\260522_U2OS_53BP1'; Count=240 }
  [pscustomobject]@{ Path='E:\Farida\20240714_ORF1p'; Count=231 }
  [pscustomobject]@{ Path='E:\Nora\250728_siCHD4'; Count=186 }
  [pscustomobject]@{ Path='E:\Ying\08Sept2023 polyLC'; Count=184 }
  [pscustomobject]@{ Path='F:\Chao\20230301-ER-hela'; Count=182 }
)
$tot = ($real | Measure-Object Count -Sum).Sum
$covered = ($real | Where-Object { $_.Path -like 'E:\Guru*' -or $_.Path -like 'E:\Chao-E*' -or
                                   $_.Path -like 'F:\Nongyun*' -or $_.Path -like 'D:\Andrew B*' } |
            Measure-Object Count -Sum).Sum
$pct = [math]::Round(100 * $covered / $tot)
"folder-level coverage: $pct%"
T "folder-level roots fall short of 80%" ($pct -lt 80)
$driveRoots = @($real | ForEach-Object { Get-DriveRoot $_.Path } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
"fallback proposes: $($driveRoots -join '; ')"
T "fallback proposes three drives"  ($driveRoots.Count -eq 3)
T "and they are D:, E:, F:"         (($driveRoots -join ';') -eq 'D:\;E:\;F:\')
T "UNC root parsed correctly"       ((Get-DriveRoot '\\srv\share\Data\x') -eq '\\srv\share\')
T "already-a-root survives"         ((Get-DriveRoot 'E:\') -eq 'E:\')

""
"-- Get-LeafName (no [IO.Path], so it behaves the same everywhere) --"
T "windows path"       ((Get-LeafName 'C:\Program Files\NIS-Elements\nis_ar.exe') -eq 'nis_ar.exe')
T "UNC path"           ((Get-LeafName '\\srv\share\a\b.exe') -eq 'b.exe')
T "forward slashes"    ((Get-LeafName 'C:/x/y/z.exe') -eq 'z.exe')
T "bare name"          ((Get-LeafName 'nis_ar.exe') -eq 'nis_ar.exe')
T "trailing separator" ((Get-LeafName 'C:\x\y\') -eq 'y')
T "empty input"        ((Get-LeafName '') -eq '')

""
if ($fail) { Write-Host "$fail CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "all NIS-detection checks passed" -ForegroundColor Green
