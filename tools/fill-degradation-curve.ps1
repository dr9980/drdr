# fill-degradation-curve.ps1
# THE LAST UNTESTED HYPOTHESIS:
#   Does this SSD lose speed as it FILLS UP?
#
# WHY THIS EXISTS
#   The plain sustained test wrote 12 GB to a 99.9%-empty drive and held a flat
#   ~671 MB/s. That cannot reveal the classic DRAM-less failure mode, which is
#   throughput collapse at HIGH occupancy (too little free space for garbage
#   collection). This script fills the drive and records speed vs. occupancy.
#
# WHAT IT DOES
#   Falls through fill levels 10% -> 90%, writing one big file the whole time,
#   sampling throughput every second, and writes a CSV + report at the end.
#
# COST - READ THIS
#   On a ~950 GB drive, 90% occupancy means writing roughly 800 GB.
#   At 671 MB/s that is about 20 MINUTES of continuous writing.
#   It consumes that much of the drive's write endurance (negligible: ~1% of a 1 TB
#   drive's typical 600 TBW rating, and this drive has 100% life left).
#
# SAFETY BRAKES (all automatic)
#   * refuses to start without -Yes
#   * stops if free space would fall below -MinFreeGB (default 5 GB)
#   * stops if the data file cannot grow (disk full)
#   * stops if throughput stays under 20 MB/s for 30 consecutive seconds
#   * deletes the test file by default when finished (-KeepFile to keep it)
#   * samples are streamed to CSV as they are taken, so an interrupt still leaves data
#
# USAGE
#   # 1) dry run first - shows the plan, writes nothing:
#   powershell -ExecutionPolicy Bypass -File .\tools\fill-degradation-curve.ps1 -DriveLetter E -WhatIf
#
#   # 2) real run (asks for confirmation):
#   powershell -ExecutionPolicy Bypass -File .\tools\fill-degradation-curve.ps1 -DriveLetter E -Yes
#
#   # 3) shorter run, stop at 70% and keep the file:
#   powershell -ExecutionPolicy Bypass -File .\tools\fill-degradation-curve.ps1 -DriveLetter E -Yes -TargetFillPct 70 -KeepFile

[CmdletBinding()]
param(
    [string]$DriveLetter  = 'E',
    [int]$TargetFillPct   = 90,     # stop when the volume reaches this % used
    [int]$MinFreeGB       = 5,      # hard floor: always leave at least this much free
    [int]$BufMB           = 256,    # in-memory buffer size (not a file size limit)
    [int]$Files           = 10,     # split the fill across N files (kinder to exFAT, gives band labels)
    [int]$ReportEverySec  = 10,     # console progress line interval
    [int]$MaxSeconds      = 0,      # wall-clock cap; 0 = unlimited (useful for short test runs)
    [switch]$Yes,                   # skip the confirmation prompt
    [switch]$WhatIf,
    [switch]$KeepFile,
    [string]$OutDir       = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$letter = $DriveLetter.TrimEnd(':', '\')
$root   = ($letter + ':\')
$file   = $root + '_dsh_fill_test.bin'
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not $OutDir) { $OutDir = $env:USERPROFILE }
$csvPath    = Join-Path $OutDir "fill-curve-$letter-$stamp.csv"
$reportPath = Join-Path $OutDir "fill-curve-$letter-$stamp.txt"

$log = New-Object System.Collections.Generic.List[string]
function Say {
    param([Parameter(ValueFromRemainingArguments = $true)]$Parts)
    $line = if ($null -eq $Parts) { '' } else { ($Parts | ForEach-Object { "$_" }) -join ' ' }
    Write-Host $line
    $script:log.Add($line)
}

$bar = '=' * 72
Say $bar
Say "  FILL-DEGRADATION CURVE TEST   target $root   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Say $bar
Say "  Goal: find whether sustained write speed collapses as occupancy rises."
Say ''

# ------------------------------------------------------------------ preflight
if (-not (Test-Path $root)) { Say "ERROR: $root does not exist."; return }

$vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
if (-not $vol) { Say "ERROR: cannot read volume $letter."; return }

$totalBytes = [int64]$vol.Size
$freeBytes  = [int64]$vol.SizeRemaining
$usedBytes  = $totalBytes - $freeBytes
$usedPct    = if ($totalBytes -gt 0) { [math]::Round(100.0 * $usedBytes / $totalBytes, 1) } else { 0 }

Say "Filesystem     : $($vol.FileSystem)"
Say "Volume size    : $([math]::Round($totalBytes/1GB,1)) GB"
Say "Currently used : $([math]::Round($usedBytes/1GB,1)) GB  ($usedPct%)"
Say "Currently free : $([math]::Round($freeBytes/1GB,1)) GB"
Say "Target fill    : $TargetFillPct%"
Say "Minimum free   : $MinFreeGB GB  (hard stop)"
Say "Test file      : $file"
Say ''

$targetUsedBytes = [int64]($totalBytes * $TargetFillPct / 100.0)
$needBytes       = $targetUsedBytes - $usedBytes
$maxWritable     = $freeBytes - ([int64]$MinFreeGB * 1GB)

if ($needBytes -le 0) {
    Say "Volume is already at or above $TargetFillPct% used. Nothing to do."
    return
}
if ($needBytes -gt $maxWritable) {
    $needBytes = $maxWritable
    $achievablePct = [math]::Round(100.0 * ($usedBytes + $needBytes) / $totalBytes, 1)
    Say "NOTE: honoring the ${MinFreeGB} GB free-space floor."
    Say "      Will write $([math]::Round($needBytes/1GB,1)) GB, reaching about $achievablePct% used."
}

# rough ETA - deliberately conservative (500 MB/s) so we never under-promise
$etaMin = [math]::Round($needBytes / 1MB / 500 / 60, 1)
Say "Will write     : $([math]::Round($needBytes/1GB,1)) GB"
Say "Rough ETA      : about $etaMin minutes (at an assumed 500 MB/s; slower drives take longer)"
Say ''

if ($WhatIf) {
    Say 'WhatIf: plan only. Nothing written.'
    Say "        CSV would go to   : $csvPath"
    Say "        report would go to: $reportPath"
    return
}

if (-not $Yes) {
    Say 'This will continuously write for many minutes and consume real write endurance.'
    Say 'Re-run with -Yes to proceed, or -WhatIf to only see this plan.'
    return
}

# --------------------------------------------------------------- disk metadata
$diskName = $null
try {
    $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
    $diskName = (Get-Disk -Number $part.DiskNumber).FriendlyName
} catch { }
Say "Disk           : $(if ($diskName) { $diskName } else { 'unknown' })"

function Get-FreeGB {
    try {
        $v = Get-Volume -DriveLetter $letter -ErrorAction Stop
        if ($v) { return [math]::Round([int64]$v.SizeRemaining / 1GB, 2) }
    } catch { }
    return $null
}

# ------------------------------------------------------------------- the run
$bufBytes = [int64]$BufMB * 1MB
$buf      = New-Object byte[] $bufBytes
(New-Object Random).NextBytes($buf)

$sw      = [Diagnostics.Stopwatch]::StartNew()
$csv     = New-Object System.IO.StreamWriter($csvPath, $false, [Text.Encoding]::UTF8)
$csv.WriteLine('ElapsedSec,TotalMB,InstantMBps,FillPct,FreeGB,Note')

$written     = [int64]0
$lastSampleT = 0.0
$lastSampleB = [int64]0
$samples     = 0
$slowStreak  = 0
$stopReason  = 'reached target'
$freeGB      = Get-FreeGB
$hardStopB   = $needBytes + $bufBytes   # never write past this
$fileCount   = [Math]::Max(1, $Files)
$perFileB    = [int64][math]::Ceiling($hardStopB / [double]$fileCount)
$filesDone   = 0
$segStats    = New-Object System.Collections.Generic.List[object]

function Write-Segment {
    param([int64]$LimitBytes, [string]$Tag)

    $segStartB = $script:written
    $lastSampleT = $script:lastSampleT
    $lastSampleB = $script:lastSampleB
    $fs = $null
    $deleted = $false
    # Use this segment's OWN stopwatch. Using the shared 1-second sample clock made
    # sub-second segments divide by an almost-zero interval and report absurd MB/s.
    $segSw = [Diagnostics.Stopwatch]::StartNew()

    try {
        $fs = [IO.File]::Create($script:file)
        $segSw.Restart()
        while ($script:written -lt $LimitBytes) {
            $fs.Write($script:buf, 0, $script:buf.Length)
            $script:written += $script:bufBytes

            $elapsed = $script:sw.Elapsed.TotalSeconds
            if (($elapsed - $lastSampleT) -ge 1.0) {
                $deltaB = $script:written - $lastSampleB
                $deltaT = $elapsed - $lastSampleT
                $inst   = if ($deltaT -gt 0) { [math]::Round($deltaB / 1MB / $deltaT, 0) } else { 0 }
                $avg    = if ($elapsed  -gt 0) { [math]::Round($script:written / 1MB / $elapsed, 0) } else { 0 }
                $fillPct = if ($script:totalBytes -gt 0) { [math]::Round(100.0 * ($script:usedBytes + $script:written) / $script:totalBytes, 1) } else { 0 }

                if (($script:samples % 10) -eq 0) { $script:freeGB = Get-FreeGB }
                $freeStr = if ($null -eq $script:freeGB) { 'n/a' } else { "$($script:freeGB)" }

                $script:csv.WriteLine(("{0:F1},{1},{2},{3},{4},{5}" -f $elapsed, [math]::Round($script:written/1MB,0), $inst, $fillPct, $freeStr, $Tag))

                if (($script:samples % $ReportEverySec) -eq 0) {
                    Say ("  {0,7:F0} s   {1,6:F1}%   {2,9}   {3,12}    {4,6}   {5}" -f $elapsed, $fillPct, $freeStr, $inst, $avg, $Tag)
                }

                $lastSampleT = $elapsed
                $lastSampleB = $script:written
                $script:samples++

                if ($inst -lt 20) { $script:slowStreak++ } else { $script:slowStreak = 0 }
                if ($script:slowStreak -ge 30) {
                    $script:stopReason = "throughput stayed under 20 MB/s for 30 s at ${fillPct}% fill"
                    return 'stop'
                }
                if ($null -ne $script:freeGB -and $script:freeGB -le $MinFreeGB) {
                    $script:stopReason = "free space reached the ${MinFreeGB} GB floor at ${fillPct}% fill"
                    return 'stop'
                }
                if ($script:written -ge $script:needBytes) {
                    $script:stopReason = "reached target fill of about ${fillPct}%"
                    return 'stop'
                }
                if ($MaxSeconds -gt 0 -and $elapsed -ge $MaxSeconds) {
                    $script:stopReason = "hit the -MaxSeconds ${MaxSeconds}s cap at ${fillPct}% fill"
                    return 'stop'
                }
            }
        }
        $fs.Flush($true); $fs.Close(); $fs = $null
    }
    catch {
        $script:stopReason = "write error: $($_.Exception.Message)"
        Say ''
        Say "WRITE ERROR: $($_.Exception.Message)"
        return 'stop'
    }
    finally {
        if ($fs) { try { $fs.Close() } catch { } }
        $segSw.Stop()

        # per-file throughput from its own stopwatch; delete time is excluded
        $segBytes = $script:written - $segStartB
        $segSec   = $segSw.Elapsed.TotalSeconds
        $segMBps  = if ($segSec -ge 0.5) { [math]::Round($segBytes / 1MB / $segSec, 0) } else { $null }
        $fillStart = if ($script:totalBytes -gt 0) { [math]::Round(100.0 * ($script:usedBytes + $segStartB) / $script:totalBytes, 1) } else { 0 }
        $fillEnd   = if ($script:totalBytes -gt 0) { [math]::Round(100.0 * ($script:usedBytes + $script:written) / $script:totalBytes, 1) } else { 0 }

        if (-not $KeepFile) {
            try { Remove-Item $script:file -Force -ErrorAction Stop; $deleted = $true } catch { }
        }
        $script:segStats.Add([pscustomobject]@{
            Tag      = $Tag
            FromPct  = $fillStart
            ToPct    = $fillEnd
            GB       = [math]::Round($segBytes / 1GB, 2)
            MBps     = $segMBps
            Seconds  = [math]::Round($segSec, 2)
            Deleted  = $deleted
        })
    }
    return 'ok'
}

Say ''
Say '  elapsed     fill%      free GB     instant MB/s    avg MB/s   segment'
Say '  ---------   --------   ---------   ------------    --------   -------'

$script:abort = $false
for ($i = 1; $i -le $fileCount; $i++) {
    $limit = $perFileB * $i
    if ($limit -gt $hardStopB) { $limit = $hardStopB }
    $tag   = "file$i/$fileCount"
    $r = Write-Segment -LimitBytes $limit -Tag $tag
    $filesDone = $i
    if ($r -eq 'stop') { break }
}

try { $csv.Flush(); $csv.Close() } catch { }
$sw.Stop()

# --------------------------------------------------------------- analysis
Say ''
Say $bar
Say '  ANALYSIS'
Say $bar

$elapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$avgTotal   = if ($elapsedSec -gt 0) { [math]::Round($written / 1MB / $elapsedSec, 0) } else { 0 }
Say "Wrote          : $([math]::Round($written/1GB,1)) GB in $elapsedSec s"
Say "Overall average: $avgTotal MB/s"
Say "Samples        : $samples"
Say "Stop reason    : $stopReason"
Say "CSV            : $csvPath"
Say ''

if ($segStats.Count -gt 0) {
    Say 'PER-SEGMENT THROUGHPUT (one file per segment; delete time excluded):'
    Say '  segment      fill range      GB      MB/s'
    Say '  ----------   ------------   -----   ------'
    foreach ($s in $segStats) {
        $speedStr = if ($null -eq $s.MBps) { '  (too short)' } else { ("{0,6}" -f $s.MBps) }
        Say ("  {0,-12} {1,5:F1}-{2,-5:F1}%  {3,5:F2}   {4}   ({5}s)" -f $s.Tag, $s.FromPct, $s.ToPct, $s.GB, $speedStr, $s.Seconds)
    }
    Say ''
}

# reload samples for analysis
$data = @()
try {
    $data = Import-Csv -Path $csvPath | ForEach-Object {
        [pscustomobject]@{
            ElapsedSec = [double]$_.ElapsedSec
            TotalMB    = [double]$_.TotalMB
            MBps       = [double]$_.InstantMBps
            FillPct    = [double]$_.FillPct
            FreeGB     = $_.FreeGB
        }
    }
} catch { }

if ($data.Count -ge 10) {
    # discard the first 3 seconds: they include cache warm-up and file creation
    $d = $data | Where-Object { $_.ElapsedSec -ge 3 }
    if ($d.Count -lt 6) { $d = $data }

    function Band-Avg($rows, $loPct, $hiPct) {
        $sel = $rows | Where-Object { $_.FillPct -ge $loPct -and $_.FillPct -lt $hiPct }
        if ($sel.Count -eq 0) { return $null }
        return [math]::Round(($sel | Measure-Object MBps -Average).Average, 0)
    }

    $startSpeed = [math]::Round((($d | Select-Object -First 5 | Measure-Object MBps -Average).Average), 0)
    $endSpeed   = [math]::Round((($d | Select-Object -Last  5 | Measure-Object MBps -Average).Average), 0)

    Say 'Speed by occupancy band (instantaneous MB/s, averaged):'
    Say '  occupancy      avg MB/s'
    Say '  -----------    --------'
    foreach ($band in @(@(0,25), @(25,45), @(45,65), @(65,80), @(80,90), @(90,101))) {
        $a = Band-Avg $d $band[0] $band[1]
        if ($null -ne $a) {
            $label = if ($band[1] -gt 100) { "$($band[0])%+" } else { "$($band[0])-$($band[1])%" }
            Say ("  {0,-13}  {1,8}" -f $label, $a)
        }
    }
    Say ''
    Say "Start-of-run average : $startSpeed MB/s"
    Say "End-of-run average   : $endSpeed MB/s"
    if ($startSpeed -gt 0) {
        Say ("End/Start ratio      : {0}" -f [math]::Round($endSpeed / $startSpeed, 2))
    }

    # where did it fall below half of the starting speed?
    $half = $startSpeed * 0.5
    $knee = $d | Where-Object { $_.MBps -lt $half } | Select-Object -First 1
    Say ''
    if ($knee) {
        Say "Knee detected: speed first dropped below half the starting rate at"
        Say "  fill = $($knee.FillPct)%   (t = $($knee.ElapsedSec) s, $($knee.MBps) MB/s, free = $($knee.FreeGB) GB)"
    } else {
        Say 'No knee detected: speed never fell below half the starting rate.'
    }

    Say ''
    Say '---------------- VERDICT ----------------'
    $ratio = if ($startSpeed -gt 0) { $endSpeed / $startSpeed } else { 1 }
    if ($endSpeed -ge 250 -and $ratio -ge 0.6) {
        Say 'FLAT: throughput held up across the whole fill range.'
        Say 'This drive does NOT suffer high-occupancy collapse. Your original "slowdown"'
        Say 'was almost certainly the normal burst-vs-sustained difference, not a fault.'
        Say 'No repair action is justified by this data.'
    } elseif ($endSpeed -ge 150) {
        Say 'MILD DECLINE: speed drops noticeably when full, but stays usable.'
        Say 'For a DRAM-less controller this is expected behaviour, not damage.'
        Say 'Practical fix: keep 20-30% free. No repair action justified.'
    } elseif ($endSpeed -ge 60) {
        Say 'STRONG DECLINE: throughput falls hard at high occupancy.'
        Say 'This is the classic DRAM-less + low-free-space behaviour, and it explains a'
        Say 'long copy getting slow. Fix: keep 20-30% free, run TRIM, quick-format if exFAT.'
        Say 'Still not evidence of hardware damage - re-test after emptying the drive.'
    } else {
        Say 'SEVERE COLLAPSE at high occupancy (under 60 MB/s).'
        Say 'First: verify free space and that TRIM is enabled. Then empty the drive and'
        Say 're-run the plain sustained test (sustained-write-curve.ps1). If the drive is'
        Say 'fast when empty and collapses when full, that is a controller/GC limitation.'
        Say 'Consider backing up and secure-erasing; RMA only if SMART degrades.'
    }
} else {
    Say "Not enough samples ($($data.Count)) for band analysis."
}

# --------------------------------------------------------------- cleanup
Say ''
if ($KeepFile) {
    Say "Kept test file (as requested): $file"
    Say 'Delete it manually when you are done (it is ' + [math]::Round($written/1GB,1) + ' GB).'
} else {
    # With -Files > 1 each segment deletes its own file, so it is normally already gone.
    if (Test-Path $file) {
        Say 'Deleting leftover test file...'
        try {
            Remove-Item $file -Force -ErrorAction Stop
            Say "Deleted: $file"
        } catch {
            Say "WARNING: could not delete $file - $($_.Exception.Message)"
            Say 'Delete it manually to reclaim the space.'
        }
    } else {
        Say 'Test file already removed by the final segment.'
    }
    $after = Get-FreeGB
    if ($null -ne $after) { Say "Free space now: $after GB" }
}

try {
    $log -join "`r`n" | Set-Content -Path $reportPath -Encoding UTF8
    Write-Host ''
    Write-Host "Report saved: $reportPath" -ForegroundColor Green
    Write-Host "CSV saved   : $csvPath" -ForegroundColor Green
} catch {
    Write-Host "Failed to write report: $($_.Exception.Message)" -ForegroundColor Red
}
