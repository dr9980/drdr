# sustained-write-curve.ps1
# The one test that actually answers "did my SSD really get slow?".
#
# WHY THIS EXISTS
#   ATTO (256 MB) and AS SSD (1 GB) finish inside the SLC cache and the Windows
#   write-back cache, so they report the drive's BEST CASE (~950 MB/s here).
#   A long file copy runs PAST those caches and exposes the real sustained speed.
#   This script writes a big file while sampling throughput every second, then
#   reports the curve shape and prints a verdict.
#
# SAFETY
#   Creates ONE temp file (<Drive>:\_dsh_sustained_test.bin) and deletes it at the end.
#   Make sure the drive has enough free space (default 12 GB).
#   Run with -WhatIf to see the plan without writing anything.
#
# USAGE (no admin required)
#   powershell -ExecutionPolicy Bypass -File .\tools\sustained-write-curve.ps1 -DriveLetter E
#   powershell -ExecutionPolicy Bypass -File .\tools\sustained-write-curve.ps1 -DriveLetter E -Gb 20
#   powershell -ExecutionPolicy Bypass -File .\tools\sustained-write-curve.ps1 -DriveLetter E -WhatIf
#   powershell -ExecutionPolicy Bypass -File .\tools\sustained-write-curve.ps1 -DriveLetter E -KeepFile

[CmdletBinding()]
param(
    [string]$DriveLetter = 'E',
    [int]$Gb             = 12,
    [int]$BlockKB        = 1024,
    [switch]$WhatIf,
    [switch]$KeepFile,
    [string]$ReportPath  = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$letter = $DriveLetter.TrimEnd(':', '\')
$root   = ($letter + ':\')
# NOTE: build the path by string concat - Join-Path throws DriveNotFoundException
# for a nonexistent drive letter and leaks a noisy error to stderr.
$file   = $root + '_dsh_sustained_test.bin'

if (-not $ReportPath) {
    $ReportPath = Join-Path $env:USERPROFILE ("sustained-curve-{0}-{1}.txt" -f $letter, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$log = New-Object System.Collections.Generic.List[string]
function Say {
    param([Parameter(ValueFromRemainingArguments = $true)]$Parts)
    $line = if ($null -eq $Parts) { '' } else { ($Parts | ForEach-Object { "$_" }) -join ' ' }
    Write-Host $line
    $script:log.Add($line)
}

$bar = '=' * 72
Say $bar
Say "  SUSTAINED WRITE CURVE TEST   target $root   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Say $bar

# ---- preflight -------------------------------------------------------------
if (-not (Test-Path $root)) { Say "ERROR: $root does not exist."; return }

$vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
if (-not $vol) { Say "ERROR: cannot read volume $letter."; return }

$needBytes = [int64]$Gb * 1GB
$freeBytes = [int64]$vol.SizeRemaining
Say "Filesystem   : $($vol.FileSystem)"
Say "Volume size  : $([math]::Round($vol.Size/1GB,2)) GB"
Say "Free space   : $([math]::Round($freeBytes/1GB,2)) GB"
Say "Test size    : $Gb GB   (free after test: ~$([math]::Round(($freeBytes-$needBytes)/1GB,2)) GB)"
Say "Block size   : ${BlockKB} KiB"
Say "Test file    : $file"
Say ''
Say 'NOTE: NTFS/exFAT may briefly hold data in the Windows write-back cache, so the'
Say '      first seconds can exceed what the drive really sustains. That is exactly why'
Say '      this test runs long enough for the true landing speed to appear.'
Say ''

if ($freeBytes -lt ($needBytes + 1GB)) {
    Say "ERROR: not enough free space for a ${Gb} GB test plus 1 GB headroom."
    Say "       Use -Gb <smaller>, e.g. -Gb 4"
    return
}

if ($WhatIf) {
    Say 'WhatIf: plan only, nothing written.'
    Say "        would create $file ($Gb GB), sample every 1s, then delete it."
    return
}

# ---- warm-up temperature (best effort) ------------------------------------
$diskName = $null
try {
    $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
    $diskName = (Get-Disk -Number $part.DiskNumber).FriendlyName
} catch { }
function Get-Temp {
    if (-not $diskName) { return $null }
    try {
        $c = Get-PhysicalDisk | Where-Object { $_.FriendlyName -eq $diskName } |
             Get-StorageReliabilityCounter -ErrorAction Stop
        if ($c -and $null -ne $c.Temperature -and $c.Temperature -gt 0) { return [int]$c.Temperature }
    } catch { }
    return $null
}
$t0 = Get-Temp
Say "Disk         : $(if ($diskName) { $diskName } else { 'unknown' })"
Say "Temperature before: $(if ($null -eq $t0) { 'n/a (USB bridge hides it via WMI)' } else { "$t0 C" })"
Say ''

# ---- the test --------------------------------------------------------------
$blockBytes = $BlockKB * 1KB
$buf = New-Object byte[] $blockBytes
# Fill once OUTSIDE the timed loop so generation time is not mistaken for disk time.
(New-Object Random).NextBytes($buf)

$blocksPerMB = [math]::Ceiling(1MB / $blockBytes)
$totalMB     = $Gb * 1024

$samples = New-Object System.Collections.Generic.List[object]
$fs      = $null
try {
    $fs = [IO.File]::Create($file)
    $swAll = [Diagnostics.Stopwatch]::StartNew()
    $secSw = [Diagnostics.Stopwatch]::StartNew()
    $writtenMB = 0
    $secMB = 0
    $secBlocks = 0

    Say '  elapsed   throughput   progress'
    Say '  -------   ----------   --------'

    while ($writtenMB -lt $totalMB) {
        $fs.Write($buf, 0, $buf.Length)
        $secBlocks++
        if ($secBlocks -ge $blocksPerMB) {
            $writtenMB++
            $secBlocks = 0
            $secMB++
        }
        if ($secSw.Elapsed.TotalSeconds -ge 1.0) {
            $secSw.Restart()
            $pct = if ($totalMB -gt 0) { [math]::Round(100.0 * $writtenMB / $totalMB, 1) } else { 0 }
            $samples.Add([pscustomobject]@{ Sec = $samples.Count + 1; MBps = $secMB; CumPct = $pct })
            Say ("  {0,5} s   {1,7} MB/s   {2,5}%" -f $samples.Count, $secMB, $pct)
            $secMB = 0
        }
    }
    $fs.Flush($true)
    $fs.Close()
    $swAll.Stop()
    $fs = $null

    $elapsed = [math]::Round($swAll.Elapsed.TotalSeconds, 1)
    $avg     = if ($elapsed -gt 0) { [math]::Round($totalMB / $elapsed, 0) } else { 0 }
    Say ''
    Say "Wrote ${totalMB} MB in ${elapsed} s  =>  average ${avg} MB/s"
}
catch {
    Say "ERROR during write: $($_.Exception.Message)"
}
finally {
    if ($fs) { try { $fs.Close() } catch { } }
}

# ---- analysis --------------------------------------------------------------
$t1 = Get-Temp
Say ''
Say "Temperature after: $(if ($null -eq $t1) { 'n/a' } else { "$t1 C" })"
if ($null -ne $t0 -and $null -ne $t1) { Say "Temperature rise : $($t1 - $t0) C" }

$n = $samples.Count
if ($n -ge 6) {
    $q      = [Math]::Max(1, [int]($n / 4))
    $firstQ = [math]::Round((($samples | Select-Object -First $q | Measure-Object MBps -Average).Average), 0)
    $lastQ  = [math]::Round((($samples | Select-Object -Last  $q | Measure-Object MBps -Average).Average), 0)
    $minv   = ($samples | Measure-Object MBps -Minimum).Minimum
    $maxv   = ($samples | Measure-Object MBps -Maximum).Maximum
    $peakSec= ($samples | Sort-Object MBps -Descending | Select-Object -First 1).Sec
    $lowSec = ($samples | Where-Object { $_.MBps -eq $minv } | Select-Object -First 1).Sec

    Say ''
    Say '---------------- CURVE ANALYSIS ----------------'
    Say "Samples          : $n"
    Say "Peak             : $maxv MB/s  (at t=${peakSec}s)"
    Say "Minimum          : $minv MB/s  (at t=${lowSec}s)"
    Say "First-quarter avg: $firstQ MB/s"
    Say "Last-quarter avg : $lastQ MB/s"
    if ($firstQ -gt 0) { Say ("Drop ratio       : {0}  (last/first)" -f [math]::Round($lastQ / $firstQ, 2)) }
    Say ''

    $shape = if ($lastQ -ge 250) { 'stable landing' }
             elseif ($lastQ -ge 100) { 'low landing' }
             elseif ($lastQ -ge 60) { 'very low landing' }
             else { 'collapse' }
    Say "Shape: $shape"
    Say ''

    if ($lastQ -ge 250) {
        Say 'VERDICT: HEALTHY. The drive steps down from burst speed to a stable 250+ MB/s,'
        Say '         which is normal for a DRAM-less SATA SSD behind a USB bridge.'
        Say '         Your earlier "slowdown" was most likely the burst-vs-sustained difference,'
        Say '         not damage from the hot-unplug.'
    } elseif ($lastQ -ge 100) {
        Say 'VERDICT: BORDERLINE. Real sustained speed 100-250 MB/s.'
        Say '         Check: free space (want 20-30%+), TRIM enabled, and whether the drive is'
        Say '         exFAT (slower dispatch than NTFS). Verify against a direct SATA connection.'
    } elseif ($lastQ -ge 60) {
        Say 'VERDICT: POOR. Sustained speed under 100 MB/s is below this hardware class.'
        Say '         Re-test on a direct SATA port to rule the USB bridge out, and re-check'
        Say '         SMART for growing reallocated/pending sectors.'
    } else {
        Say 'VERDICT: SEVERE COLLAPSE. Sustained speed under 60 MB/s or stalling.'
        Say '         Back up now. Then: full TRIM, idle the drive powered for several hours,'
        Say '         retest; if unchanged, secure-erase; if still unchanged, treat as failing.'
    }

    if ($maxv -ge 800 -and $lastQ -lt 400) {
        Say ''
        Say 'Note: the large burst-to-landing gap is EXPECTED for this drive class and is'
        Say '      precisely what ATTO/AS SSD hide by testing only 256 MB - 1 GB.'
    }
} else {
    Say ''
    Say "Only $n sample(s) collected - too short for curve analysis. Increase -Gb."
}

# ---- cleanup ---------------------------------------------------------------
Say ''
if ($KeepFile) {
    Say "Kept test file (as requested): $file"
    Say 'Delete it manually when done.'
} else {
    Remove-Item $file -Force -ErrorAction SilentlyContinue
    if (Test-Path $file) { Say "WARNING: could not delete $file - remove it manually." }
    else { Say "Test file deleted: $file" }
}

try {
    $log -join "`r`n" | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Host ''
    Write-Host "Report saved: $ReportPath" -ForegroundColor Green
} catch {
    Write-Host "Failed to write report: $($_.Exception.Message)" -ForegroundColor Red
}
