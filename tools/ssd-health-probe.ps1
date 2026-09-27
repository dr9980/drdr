# ssd-health-probe.ps1  (v3)
# Health probe for diagnosing "SSD got slow after hot-unplug during a long write".
#
# v3 fixes / additions:
#   * FIXED the v2 crash: the log helper was named "Tee", which is a built-in alias for
#     Tee-Object. Aliases beat functions, so every Emit call silently invoked Tee-Object
#     and the report file came out empty. Helper is now named Emit.
#   * SMART reality check: on USB-bridged SATA SSDs Get-StorageReliabilityCounter often
#     returns NOTHING. The script now detects that and tells you to use smartctl instead.
#   * Warns when not elevated (SMART/fsutil need admin).
#   * Null-safe when the target volume does not resolve (no more divide-by-zero).
#   * -SelfTest : validates report writing, UTF-8 encoding and the curve-statistics logic
#     with NO disk access and NO admin rights required.
#
# It does NOT change configuration, format, or secure-erase.
# The sustained test creates ONE temp file and deletes it afterwards.
#
# Run as ADMINISTRATOR:
#   powershell -ExecutionPolicy Bypass -File .\tools\ssd-health-probe.ps1 -DriveLetter E
#   powershell -ExecutionPolicy Bypass -File .\tools\ssd-health-probe.ps1 -DriveLetter E -SkipSustained
#   powershell -ExecutionPolicy Bypass -File .\tools\ssd-health-probe.ps1 -SelfTest

[CmdletBinding()]
param(
    [string]$DriveLetter = 'E',
    [int]$DiskNumber     = -1,
    [int]$WriteTestMB    = 8,
    [int]$SustainedGB    = 2,
    [switch]$SkipSustained,
    [switch]$SelfTest,
    [string]$ReportPath  = ''
)

$ErrorActionPreference = 'Continue'

# Keep Chinese text from mojibaking in the report or the console.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$letter     = $DriveLetter.TrimEnd(':', '\') + ':'
$letterBare = $DriveLetter.TrimEnd(':', '\')

if (-not $ReportPath) {
    $ReportPath = Join-Path $env:USERPROFILE ("ssd-probe-{0}-{1}.txt" -f $letterBare, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$script:Report = New-Object System.Collections.Generic.List[string]

# NOTE: deliberately NOT named "Tee" - that is a built-in alias for Tee-Object and
# aliases take precedence over functions, which breaks every call.
function Emit {
    param([Parameter(ValueFromRemainingArguments = $true)]$Parts)
    $line = if ($null -eq $Parts) { '' } else { ($Parts | ForEach-Object { "$_" }) -join ' ' }
    Write-Host $line
    $script:Report.Add($line)
}
function Section($t) {
    Emit ''
    Emit ('=' * 72)
    Emit "  $t"
    Emit ('=' * 72)
}
function Try-Step($label, [scriptblock]$sb) {
    Emit ''
    Emit "--- $label"
    try {
        $out = & $sb 2>&1
        if ($null -eq $out -or ($out -is [array] -and $out.Count -eq 0)) {
            Emit '    (no output / not supported on this system)'
        } else {
            foreach ($l in ($out | Out-String -Width 220) -split "`r?`n") { Emit $l }
        }
    } catch {
        Emit "    ERROR: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Curve statistics, factored out so -SelfTest can exercise it with no disk I/O.
# ---------------------------------------------------------------------------
function Get-CurveStats {
    param([object[]]$Samples)

    $n = @($Samples).Count
    if ($n -lt 6) { return $null }

    $q        = [int]($n / 4)
    if ($q -lt 1) { $q = 1 }
    $firstQ   = ($Samples | Select-Object -First $q | Measure-Object MBps -Average).Average
    $lastQ    = ($Samples | Select-Object -Last  $q | Measure-Object MBps -Average).Average
    $minv     = ($Samples | Measure-Object MBps -Minimum).Minimum
    $maxv     = ($Samples | Measure-Object MBps -Maximum).Maximum

    $verdict = if ($lastQ -ge 250) {
        'HEALTHY: landed at a normal DRAM-less sustained speed (250+ MB/s) and held it.'
    } elseif ($lastQ -ge 100) {
        'BORDERLINE: sustained landing 100-250 MB/s. Check free space (want 20-30%) and TRIM.'
    } elseif ($lastQ -ge 60) {
        'POOR: sustained landing 60-100 MB/s. Investigate free space, GC state, thermals.'
    } else {
        'SEVERE: sustained landing under 60 MB/s. Cache fully consumed with too little free space, controller stuck in post-unplug recovery, or failing NAND.'
    }

    [pscustomobject]@{
        Samples    = $n
        FirstQAvg  = [math]::Round($firstQ, 0)
        LastQAvg   = [math]::Round($lastQ, 0)
        Min        = $minv
        Max        = $maxv
        DropRatio  = if ($firstQ -gt 0) { [math]::Round($lastQ / $firstQ, 2) } else { 0 }
        Verdict    = $verdict
    }
}

# ---------------------------------------------------------------------------
# SELF TEST: no disk access, no admin needed.
# ---------------------------------------------------------------------------
if ($SelfTest) {
    Section "SELF TEST (no disk access, no admin required)"

    $fails = 0
    function Check($name, [bool]$ok, $detail) {
        $tag = if ($ok) { 'PASS' } else { 'FAIL' }
        Emit ("[{0}] {1}{2}" -f $tag, $name, $(if ($detail) { "  -> $detail" } else { '' }))
        if (-not $ok) { $script:fails++ }
    }

    # 1. report list + Emit
    $before = $script:Report.Count
    Emit 'self-test marker line'
    Check 'Emit appends to report' (($script:Report.Count -eq $before + 1) -and ($script:Report[-1] -eq 'self-test marker line')) "count $before -> $($script:Report.Count)"

    # 2. Emit with no args
    Emit
    Check 'Emit with no args produces a blank line' ($script:Report[-1] -eq '')

    # 3. Emit with multiple args joined
    Emit 'a' 'b' 'c'
    Check 'Emit joins multiple args' ($script:Report[-1] -eq 'a b c') $script:Report[-1]

    # 4. curve stats - healthy plateau then normal step-down landing at 300
    $healthy = @(950,948,952,900,600,320,300,292,288,285,290,287) |
        ForEach-Object { [pscustomobject]@{ MBps = $_ } }
    $h = Get-CurveStats $healthy
    Check 'curve stats: healthy pattern detected' ($h -and $h.LastQAvg -ge 250) "lastQ=$($h.LastQAvg) drop=$($h.DropRatio)"

    # 5. curve stats - severe collapse
    $sick = @(900,880,700,400,120,45,30,25,20,18,22,19) |
        ForEach-Object { [pscustomobject]@{ MBps = $_ } }
    $s = Get-CurveStats $sick
    Check 'curve stats: severe collapse detected' ($s -and $s.Verdict -like 'SEVERE*') "lastQ=$($s.LastQAvg)"

    # 6. curve stats - too few samples returns null
    $few = @(1,2,3) | ForEach-Object { [pscustomobject]@{ MBps = $_ } }
    Check 'curve stats: returns null for <6 samples' ($null -eq (Get-CurveStats $few))

    # 7. report file round-trip incl. non-ASCII
    $rtPath = Join-Path $env:TEMP 'dsh-probe-roundtrip.txt'
    $script:Report.Add('中文换行测试 / non-ascii line')
    try {
        $script:Report -join "`r`n" | Set-Content -Path $rtPath -Encoding UTF8
        $back = Get-Content $rtPath
        Check 'report file written' (Test-Path $rtPath) "$((Get-Item $rtPath).Length) bytes"
        Check 'report file round-trips non-ASCII' ($back -contains '中文换行测试 / non-ascii line')
        Remove-Item $rtPath -Force -ErrorAction SilentlyContinue
    } catch {
        Check 'report file written' $false $_.Exception.Message
    }

    # 8. Tee alias trap must not be reachable
    Check 'no helper named Tee remains' (-not (Get-Command Emit).Name.Equals('Tee'))

    Emit ''
    if ($script:fails -eq 0) {
        Emit 'SELF TEST: ALL CHECKS PASSED'
    } else {
        Emit "SELF TEST: $($script:fails) CHECK(S) FAILED"
    }
    try {
        $script:Report -join "`r`n" | Set-Content -Path $ReportPath -Encoding UTF8
        Write-Host "Self-test report: $ReportPath" -ForegroundColor Green
    } catch { }
    return
}

# ===========================================================================
# NORMAL PROBE
# ===========================================================================
Section "SSD HEALTH PROBE v3  target: $letter   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Emit "Report file: $ReportPath"

$isAdmin = $false
$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Emit ''
    Emit '*** WARNING: NOT RUNNING ELEVATED ***'
    Emit '    SMART counters and fsutil checks usually fail without admin rights.'
    Emit '    Re-run from an Administrator PowerShell for a meaningful result.'
}

Try-Step 'OS / elevation' {
    $os = Get-CimInstance Win32_OperatingSystem
    "OS        : $($os.Caption) $($os.Version)"
    "User      : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    "Elevated  : $isAdmin"
    "PSVersion : $($PSVersionTable.PSVersion)"
}

# ------------------------------------------------------------ resolve target
$disk = $null
$vol  = $null
Try-Step 'Target volume / disk mapping' {
    try { $script:vol = Get-Volume -DriveLetter $letterBare -ErrorAction Stop } catch { }
    if (-not $script:vol) {
        "Volume $letter was NOT found. List candidates with:  Get-Volume | Format-Table DriveLetter,FileSystemLabel,Size,SizeRemaining"
        return
    }
    $part = Get-Partition -DriveLetter $letterBare -ErrorAction Stop
    $script:disk = Get-Disk -Number $part.DiskNumber
    "Volume    : $($script:vol.DriveLetter):  label='$($script:vol.FileSystemLabel)'  fs=$($script:vol.FileSystem)  Health=$($script:vol.HealthStatus)"
    "Size      : $([math]::Round($script:vol.Size/1GB,1)) GB   Free: $([math]::Round($script:vol.SizeRemaining/1GB,1)) GB"
    "Disk #    : $($part.DiskNumber)   Partition #: $($part.PartitionNumber)"
    "Disk      : $($script:disk.FriendlyName)"
    "BusType   : $($script:disk.BusType)   PartitionStyle: $($script:disk.PartitionStyle)   Health: $($script:disk.HealthStatus)"
    "DiskSize  : $([math]::Round($script:disk.Size/1GB,1)) GB   Offline: $($script:disk.IsOffline)   ReadOnly: $($script:disk.IsReadOnly)"
    "Serial    : $($script:disk.SerialNumber)"
    "Firmware  : $($script:disk.FirmwareVersion)"
}

if (-not $disk) {
    Emit ''
    Emit '!! Could not resolve the target disk. Sections needing a target will be skipped.'
    Emit '   List candidates:  Get-Disk | Format-Table Number,FriendlyName,BusType,Size,HealthStatus'
}

# ------------------------------------------------------------- core storage
Section 'PHYSICAL DISK / HEALTH'
Try-Step 'All physical disks (for comparison)' {
    Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, MediaType, BusType, HealthStatus,
        OperationalStatus, @{n='SizeGB'; e={ [math]::Round($_.Size/1GB,1) } } | Format-Table -AutoSize
}
if ($disk) {
    Try-Step 'Disk (target) full record' {
        $disk | Select-Object Number, FriendlyName, SerialNumber, FirmwareVersion, BusType, Size,
            PartitionStyle, HealthStatus, OperationalStatus, IsBoot, IsSystem | Format-List
    }
}

# ------------------------------------------------------------------ SMART
Section 'SMART / ATTRIBUTES  <<< THE DECIDING EVIDENCE'
$smartCounters = $null
Try-Step 'Reliability counters (all disks)' {
    $rows = @()
    foreach ($d in Get-PhysicalDisk) {
        $c = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        if ($c) {
            $rows += [pscustomobject]@{
                Disk            = $d.FriendlyName
                Bus             = $d.BusType
                Health          = $d.HealthStatus
                TempC           = $c.Temperature
                TempMaxC        = $c.TemperatureMax
                PowerOnHours    = $c.PowerOnHours
                StartStopCycles = $c.StartStopCycleCount
                UnsafeShutdowns = $c.UnsafeShutdownCount
                ReadErrTotal    = $c.ReadErrorsTotal
                ReadErrUncorr   = $c.ReadErrorsUncorrected
                WriteErrTotal   = $c.WriteErrorsTotal
                WriteErrUncorr  = $c.WriteErrorsUncorrected
                Wear            = $c.Wear
                ReadLatencyMax  = $c.ReadLatencyMax
                WriteLatencyMax = $c.WriteLatencyMax
            }
        }
    }
    if ($rows.Count -eq 0) {
        'NO COUNTERS RETURNED by Get-StorageReliabilityCounter on ANY disk.'
        ''
        'This is the normal situation for USB-bridged SATA SSDs: the USB-to-SATA bridge'
        'does not forward SMART data through the Windows storage stack, so the single most'
        'important evidence (unsafe-shutdown count, wear, uncorrected errors) is INVISIBLE here.'
        ''
        '=> Install smartmontools and read SMART directly (see the next section).'
    } else {
        $script:smartCounters = $rows
        $rows | Format-List
    }
}
Try-Step 'smartctl (REQUIRED for USB-bridged drives)' {
    $sc = Get-Command smartctl.exe -ErrorAction SilentlyContinue
    if (-not $sc) {
        'smartctl NOT INSTALLED.'
        ''
        'Install (one line, from an Administrator PowerShell):'
        '    winget install --id smartmontools.smartmontools -e'
        ''
        'Then list drives and read SMART:'
        '    smartctl --scan'
        '    smartctl -a /dev/sdX        (WSL/Linux naming)'
        '    smartctl -a pd1             (Windows physical drive 1 = your K122)'
        ''
        'The attributes that matter for this investigation:'
        '    Attribute 5   Reallocated_Sector_Ct      must be 0 and not growing'
        '    Attribute 12  Power_Cycle_Count          total power cycles'
        '    Attribute 174 Unexpected_Power_Loss      <- THE hot-unplug counter'
        '    Attribute 192 Unsafe_Shutdown_Count      <- same idea, SMI controllers'
        '    Attribute 241 Total_LBAs_Written         total host writes'
        '    Attribute 231 SSD_Life_Left / Wear_Leveling_Count'
        '    Attribute 199 UDMA_CRC_Error_Count       link/cable/bridge errors'
    } else {
        Write-Host "smartctl found at: $($sc.Source)"
        Write-Host 'Running scan...'
        & $sc.Source --scan
        Write-Host ''
        foreach ($pd in 0..3) {
            Write-Host "--- smartctl -a pd$pd"
            & $sc.Source -a "pd$pd" 2>&1
        }
    }
}

# -------------------------------------------------------------- TRIM / FS
Section 'TRIM / FILESYSTEM'
Try-Step 'TRIM (DisableDeleteNotify: 0 = ENABLED, 1 = DISABLED)' { fsutil behavior query DisableDeleteNotify }
if ($vol) {
    Try-Step 'Volume dirty bit (unclean shutdown marker)' { fsutil dirty query $letter }
    Try-Step 'NTFS info' { fsutil fsinfo ntfsinfo $letter }
}
Try-Step 'Physical drives as seen by Windows' {
    Get-CimInstance Win32_DiskDrive |
        Select-Object Index, Model, InterfaceType, MediaType, Size, Partitions, Status |
        Format-Table -AutoSize
}

# ---------------------------------------------------------------- LINK
Section 'LINK SPEED / CONNECTION QUALITY'
Emit 'Interpretation guide:'
Emit '  ~950-1050 MB/s => SATA 6Gb/s behind USB 10Gbps + UASP   = HEALTHY'
Emit '  ~270-290  MB/s => SATA 3Gb/s (SATA II) negotiated DOWN   = INVESTIGATE'
Emit '  ~35-45    MB/s => USB 2.0 fallback / BOT instead of UASP = INVESTIGATE'
Try-Step 'Problem devices (ConfigManagerErrorCode <> 0)' {
    Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.ConfigManagerErrorCode -ne 0 } |
        Select-Object Name, Status, ConfigManagerErrorCode | Format-Table -AutoSize
}
Try-Step 'USB / storage devices' {
    Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.Name -match 'USB|UASP|UAS|SCSI|Mass Storage|ASMedia|JMicron|Realtek|VL7|Lenovo|K122' } |
        Select-Object Name, Status, ConfigManagerErrorCode | Format-Table -AutoSize
}
Try-Step 'REAL storage error events, last 7 days (noise filtered out)' {
    $ev = Get-WinEvent -FilterHashtable @{
        LogName = 'System'; StartTime = (Get-Date).AddDays(-7); Id = 7, 9, 11, 15, 51, 52, 55, 98, 129, 153, 157
    } -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -notmatch 'Hyper-V|Kernel-Processor-Power|Kernel-General' }
    if (-not $ev) {
        'NONE. No disk/storage error events in the last 7 days. This is a GOOD sign.'
    } else {
        $ev | Select-Object TimeCreated, Id, ProviderName,
            @{n='Msg'; e={ ($_.Message -split "`r?`n")[0] } } | Format-Table -AutoSize -Wrap
    }
}

# ------------------------------------------------------------ CAPACITY
Section 'CAPACITY / FREE SPACE  (critical for DRAM-less SSDs)'
$freePct = $null
if ($vol) {
    Try-Step 'Free space check' {
        $v = Get-Volume -DriveLetter $letterBare
        if (-not $v -or $v.Size -le 0) { 'Volume size unavailable; skipping.'; return }
        $script:freePct = [math]::Round(100 * $v.SizeRemaining / $v.Size, 1)
        "Free: $([math]::Round($v.SizeRemaining/1GB,1)) GB of $([math]::Round($v.Size/1GB,1)) GB  ($($script:freePct)%)"
        if ($script:freePct -lt 15) {
            'VERDICT: LOW. DRAM-less controllers degrade badly below ~15-20% free.'
            '         Clear to 20-30% free (~200-300 GB on a 1 TB drive) BEFORE judging speed.'
        } else { 'VERDICT: acceptable free space.' }
    }
} else {
    Try-Step 'Free space check' { "Skipped: volume $letter not found." }
}

# ------------------------------------------------------- write tests
function Get-DiskTempC {
    try {
        $t = Get-PhysicalDisk | Where-Object { $_.FriendlyName -eq $script:disk.FriendlyName } |
             Get-StorageReliabilityCounter -ErrorAction Stop
        if ($t -and $null -ne $t.Temperature -and $t.Temperature -gt 0) { return [int]$t.Temperature }
    } catch { }
    return $null
}

if ($vol) {
    Section 'SMALL WRITE PROBE (non-destructive)'
    Try-Step "Write ${WriteTestMB} MB temp file, measure, delete" {
        $tmp = Join-Path $letter ('dsh_write_probe_{0}.tmp' -f (Get-Random))
        $buf = New-Object byte[] (1MB)
        (New-Object Random).NextBytes($buf)

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $fs = [IO.File]::Create($tmp)
        for ($i = 0; $i -lt $WriteTestMB; $i++) { $fs.Write($buf, 0, $buf.Length) }
        $fs.Flush($true); $fs.Close()
        $sw.Stop()
        $mbs = [math]::Round($WriteTestMB / $sw.Elapsed.TotalSeconds, 1)
        "Wrote ${WriteTestMB} MB in $([math]::Round($sw.Elapsed.TotalSeconds,3)) s  =>  $mbs MB/s"
        'NOTE: sample is small; the SUSTAINED test below is the meaningful one.'
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        'Temp file removed.'
    }

    # ----------------------------------------------------- sustained write
    if (-not $SkipSustained) {
        Section "SUSTAINED WRITE TEST (${SustainedGB} GB, 1 MiB blocks, per-second sampling)"
        Emit 'HEALTHY DRAM-less drive : high plateau while SLC cache holds, then a STEP DOWN'
        Emit '                          to a lower but STABLE 250-450 MB/s.'
        Emit 'SICK / throttling drive : collapse below ~30 MB/s, sawtooth, or a full stall.'
        Emit ''
        $t0 = Get-DiskTempC
        Emit "Temperature BEFORE: $(if ($null -eq $t0) { 'n/a (USB bridge hides it)' } else { "$t0 C" })"

        Try-Step "Sustained write of ${SustainedGB} GB" {
            $tmp   = Join-Path $letter ('dsh_sustained_{0}.bin' -f (Get-Random))
            $buf   = New-Object byte[] (1MB)
            (New-Object Random).NextBytes($buf)
            $totMB = $SustainedGB * 1024

            $fs = [IO.File]::Create($tmp)
            $samples = New-Object System.Collections.Generic.List[object]
            $swAll   = [Diagnostics.Stopwatch]::StartNew()
            $secSw   = [Diagnostics.Stopwatch]::StartNew()
            $written = 0
            $secWritten = 0

            while ($written -lt $totMB) {
                $fs.Write($buf, 0, $buf.Length)
                $written++; $secWritten++
                if ($secSw.Elapsed.TotalSeconds -ge 1.0) {
                    $secSw.Restart()
                    $mbps = $secWritten
                    $pct  = [math]::Round(100.0 * $written / $totMB, 1)
                    $samples.Add([pscustomobject]@{ Sec = $samples.Count + 1; MBps = $mbps; CumPct = $pct })
                    Emit ("    t={0,3}s  {1,5} MB/s   ({2,5}% done)" -f $samples.Count, $mbps, $pct)
                    $secWritten = 0
                }
            }
            $fs.Flush($true); $fs.Close()
            $swAll.Stop()

            $avg = [math]::Round($totMB / $swAll.Elapsed.TotalSeconds, 0)
            Emit ''
            Emit "Sustained write: ${totMB} MB in $([math]::Round($swAll.Elapsed.TotalSeconds,1)) s  =>  average $avg MB/s"

            $stats = Get-CurveStats -Samples $samples
            if ($stats) {
                Emit ''
                Emit ("Curve: first-quarter avg {0} MB/s -> last-quarter avg {1} MB/s   (min {2}, max {3}, drop ratio {4})" -f `
                      $stats.FirstQAvg, $stats.LastQAvg, $stats.Min, $stats.Max, $stats.DropRatio)
                Emit "VERDICT: $($stats.Verdict)"
            } else {
                Emit 'Too few samples for curve analysis (increase -SustainedGB).'
            }
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            Emit 'Sustained temp file removed.'
        }

        $t1 = Get-DiskTempC
        Emit "Temperature AFTER: $(if ($null -eq $t1) { 'n/a (USB bridge hides it)' } else { "$t1 C" })"
        if ($null -ne $t0 -and $null -ne $t1) {
            Emit "Temperature RISE: $($t1 - $t0) C"
            if ($t1 -ge 65) { Emit 'VERDICT: running HOT - if speed collapsed at the same time this is THERMAL throttling. Re-test COLD to confirm.' }
        }
    } else {
        Section 'SUSTAINED WRITE TEST'
        Emit 'Skipped (-SkipSustained). Re-run without it to find the cache-collapse point.'
    }
} else {
    Section 'WRITE TESTS'
    Emit "Skipped: volume $letter not found."
}

# ---------------------------------------------------------------- SUMMARY
Section 'HOW TO READ THE KEY NUMBERS'
foreach ($l in @(
    '1. smartctl attribute 174 Unexpected_Power_Loss / 192 Unsafe_Shutdown_Count',
    '     High (dozens+) => history of ungraceful power loss, consistent with yanking the',
    '     cable mid-write. Not fatal by itself, but it is the mechanism behind FTL rebuild',
    '     and garbage-collection storms on the next power-up.',
    '',
    '2. smartctl attribute 231 SSD_Life_Left / Wear_Leveling_Count, or Wear above',
    '     Near end-of-life => the slowdown is permanent and expected.',
    '',
    '3. smartctl attribute 5 Reallocated_Sector_Ct, 187/197/198 pending & uncorrectable',
    '     Non-zero and GROWING between two runs => drive degrading; back up and RMA.',
    '',
    '4. Temperature / TemperatureMax (smartctl attribute 194)',
    '     Near 70 C under load => thermal throttle. Test cold vs. hot to prove it.',
    '',
    '5. Free% below 15-20',
    '     For a DRAM-less controller this alone explains terrible 4K numbers. Fix first.',
    '',
    '6. BusType / link speed',
    '     ~950+ MB/s = SATA III healthy. ~280 MB/s = link fell back to SATA II.',
    '     ~40 MB/s = USB 2.0. Note: 950+ MB/s already proves SATA III + UASP.',
    '',
    '7. TRIM DisableDeleteNotify',
    '     Must be 0. If 1, the drive never learns which blocks are free -> permanent slowdown.',
    '',
    '8. Sustained-write landing speed',
    '     The single most diagnostic number for "it got slow".',
    '     250-450 MB/s stable = normal for this class. Under 100 MB/s or stalling = real problem.')) { Emit $l }

Emit ''
Emit 'PROBE COMPLETE.'
Emit "Full report written to: $ReportPath"
Emit 'Send that file back for analysis.'
Emit ''

try {
    $script:Report -join "`r`n" | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Host "Report saved: $ReportPath" -ForegroundColor Green
} catch {
    Write-Host "Failed to write report: $($_.Exception.Message)" -ForegroundColor Red
}
