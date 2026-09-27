# extract-video-frames.ps1
# Extract still frames from an MP4 using the WPF MediaPlayer stack (no ffmpeg needed).
# Outputs numbered PNGs into an output directory.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\tools\extract-video-frames.ps1 -Path <video> -OutDir <dir> -AtSeconds 0.5,5,10,20,30,45,60

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$OutDir,
    # Comma-separated STRING, not [double[]]: powershell.exe -File cannot bind arrays.
    [string]$AtSeconds = '0.5,3,6,10,15,20,30,45,60',
    [int]$MaxWidth = 1080
)

$ErrorActionPreference = 'Stop'

$AtSeconds = @($AtSeconds -split '[,;]' | ForEach-Object { [double]$_.Trim() } | Where-Object { $_ -ge 0 })

if (-not (Test-Path $Path)) { throw "video not found: $Path" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$Path  = (Resolve-Path $Path).Path
$OutDir = (Resolve-Path $OutDir).Path

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# A tiny STA pump so MediaPlayer can raise MediaOpened / MediaFailed.
function Wait-For([scriptblock]$Condition, [int]$TimeoutMs, [string]$What) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $frame = New-Object Windows.Threading.DispatcherFrame
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $timer.Add_Tick({
        if ((& $Condition) -or $sw.ElapsedMilliseconds -gt $TimeoutMs) {
            $timer.Stop()
            $frame.Continue = $false
        }
    })
    $timer.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
    return (& $Condition)
}

$player = New-Object Windows.Media.MediaPlayer
$opened = $false
$failed = $null
$player.add_MediaOpened({ $script:opened = $true })
$player.add_MediaFailed({ param($s, $e) $script:failed = $e.ErrorException.Message })
$player.Volume = 0
$player.ScrubbingEnabled = $true

Write-Host "Opening: $Path"
$player.Open([Uri]$Path)

$ok = Wait-For { $script:opened -or $script:failed } 15000 'MediaOpened'
if ($failed) { throw "MediaFailed: $failed" }
if (-not $ok) { throw 'timed out waiting for MediaOpened' }

$w = $player.NaturalVideoWidth
$h = $player.NaturalVideoHeight
$dur = $player.NaturalDuration
$durSec = if ($dur.HasTimeSpan) { [math]::Round($dur.TimeSpan.TotalSeconds, 2) } else { $null }
Write-Host "Opened OK. ${w}x${h}  duration=${durSec}s"
Write-Host ''

$results = @()
foreach ($t in $AtSeconds) {
    if ($null -ne $durSec -and $t -gt $durSec) {
        Write-Host ("  t={0,6}s  SKIP (beyond duration)" -f $t)
        continue
    }

    $player.Position = [TimeSpan]::FromSeconds($t)
    Start-Sleep -Milliseconds 250            # let the frame decode
    $player.Play()
    Start-Sleep -Milliseconds 120
    $player.Pause()
    Start-Sleep -Milliseconds 200

    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawVideo($player, (New-Object Windows.Rect(0, 0, $w, $h)))
    $dc.Close()

    $scale = if ($w -gt $MaxWidth) { $MaxWidth / $w } else { 1.0 }
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap(
        [int]($w * $scale), [int]($h * $scale), 96, 96,
        [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)

    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))

    $file = Join-Path $OutDir ("frame_{0:000.00}s.png" -f $t)
    $fs = [IO.File]::Create($file)
    $enc.Save($fs)
    $fs.Close()

    $size = (Get-Item $file).Length
    $results += [pscustomobject]@{ Seconds = $t; File = $file; Bytes = $size }
    Write-Host ("  t={0,6}s  ->  {1}  ({2:N0} bytes)" -f $t, (Split-Path $file -Leaf), $size)
}

$player.Close()

Write-Host ''
Write-Host "Extracted $($results.Count) frame(s) to: $OutDir"
Write-Host ''
Write-Host 'Frame sizes (a usable screen frame is normally 100 KB - 1 MB;'
Write-Host 'a near-empty/black frame is a few KB - if all are tiny, decoding failed):'
$results | ForEach-Object { Write-Host ("  {0,7:F2}s   {1,10:N0} bytes" -f $_.Seconds, $_.Bytes) }

# report the largest frame as the most likely to contain content
$best = $results | Sort-Object Bytes -Descending | Select-Object -First 1
if ($best) { Write-Host ''; Write-Host "Largest frame (most content): $($best.File)" }
