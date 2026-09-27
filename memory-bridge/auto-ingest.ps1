# auto-ingest.ps1 — scheduled, unattended, INCREMENTAL DSH ingestion into RAGFlow
#
# Run by Windows Task Scheduler. Never touches the chat path: it only reads
# session files and writes memory documents, so a failure here cannot break a
# conversation.
#
# INCREMENTAL BY DESIGN
#   An earlier version re-distilled and re-uploaded every session on every run
#   (a second run took the library from 42 to 84 documents — pure duplicates,
#   and duplicated DeepSeek spend). The cause: the distiller's skip check is
#   per notes DIRECTORY, and each run used a fresh timestamped directory, so it
#   never saw its own previous output.
#
#   This version keeps a state file (logs/.ingest-state.json) mapping
#   sessionId -> { mtime, ingestedAt } and processes a session only when its
#   file is newer than the recorded mtime. Sessions whose file is old but that
#   have no state entry are picked up once (first run / new session).
#
# Per run:
#   1. single-instance lock
#   2. find settled sessions (quiet for $ActiveWindowMin); skip ones still being written
#   3. keep only those whose mtime advanced since the last ingest
#   4. per changed session: distiller (DeepSeek) -> notes dir, then one store pass
#   5. update state, append a result line to logs/ingest.log
#
# Exit codes: 0 = ok (including "nothing new"), 1 = pipeline error, 2 = already running.

[CmdletBinding()]
param(
    [int]$ActiveWindowMin = 10,
    [int]$MaxSessionsPerRun = 6,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$logDir = Join-Path $here 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$logFile = Join-Path $logDir 'ingest.log'
$lockFile = Join-Path $logDir '.ingest.lock'
$stateFile = Join-Path $logDir '.ingest-state.json'

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# ---------------------------------------------------------------- lock guard
if (Test-Path $lockFile) {
    $age = (Get-Date) - (Get-Item $lockFile).LastWriteTime
    if ($age.TotalHours -lt 2) {
        Write-Log 'SKIP' ("another run is in progress (lock age {0:N1} min)" -f $age.TotalMinutes)
        exit 2
    }
    Write-Log 'WARN' ("stale lock ({0:N1} h) — overriding" -f $age.TotalHours)
}
New-Item -ItemType File -Path $lockFile -Force | Out-Null

try {
    $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $nodeExe) { $nodeExe = 'D:\node\node.exe' }
    if (-not (Test-Path $nodeExe)) { Write-Log 'ERROR' 'node not found'; exit 1 }

    # ------------------------------------------------------------- state load
    $state = @{}
    if (Test-Path $stateFile) {
        try {
            (Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
                ForEach-Object { $state[$_.Name] = $_.Value }
        } catch { Write-Log 'WARN' "state file unreadable, starting fresh: $($_.Exception.Message)" }
    }

    # -------------------------------------------------- settle-time accounting
    $sessionsRoot = Join-Path $env:USERPROFILE '.dsh\sessions'
    $cutoff = (Get-Date).AddMinutes(-$ActiveWindowMin)
    $all = @(Get-ChildItem $sessionsRoot -Recurse -File -Filter '*.zstd' -ErrorAction SilentlyContinue)
    $active = @($all | Where-Object { $_.LastWriteTime -gt $cutoff })
    $settled = @($all | Where-Object { $_.LastWriteTime -le $cutoff })

    Write-Log 'INFO' ("sessions: total={0} settled={1} active(skipped)={2}" -f $all.Count, $settled.Count, $active.Count)

    # --------------------------------------------------- incremental filtering
    $todo = @()
    foreach ($s in $settled) {
        $id = $s.Directory.Name
        $mtime = $s.LastWriteTime.ToString('o')
        $prev = $null
        if ($state.ContainsKey($id)) { $prev = $state[$id].mtime }
        if ($Force -or $null -eq $prev -or $prev -ne $mtime) {
            $todo += [pscustomobject]@{ Id = $id; File = $s.FullName; Mtime = $mtime; Bytes = $s.Length }
        }
    }

    Write-Log 'INFO' ("changed since last ingest: {0}" -f $todo.Count)
    if ($todo.Count -eq 0) {
        Write-Log 'OK' 'nothing new; library already up to date'
        exit 0
    }
    if ($todo.Count -gt $MaxSessionsPerRun) {
        Write-Log 'INFO' ("capping at {0} session(s) this run; the rest go next run" -f $MaxSessionsPerRun)
        $todo = $todo | Select-Object -First $MaxSessionsPerRun
    }
    $todo | ForEach-Object { Write-Log 'INFO' ("  -> {0} ({1:N1} KB)" -f $_.Id, ($_.Bytes/1KB)) }

    # ---------------------------------------------- per-session distill + store
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $notesDir = Join-Path $here ("notes\auto-" + $stamp)
    New-Item -ItemType Directory -Path $notesDir -Force | Out-Null

    $succeeded = @()
    $failed = @()
    $empty = @()
    $totalSec = 0

    foreach ($item in $todo) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $dOut = & $nodeExe (Join-Path $here 'distiller.mjs') '--only' $item.Id '--out-dir' $notesDir '--force' 2>&1
        $dCode = $LASTEXITCODE
        $sw.Stop()
        $totalSec += $sw.Elapsed.TotalSeconds

        # A session with no human turns (a bare session header, or a fully
        # contentless session) yields no notes. That is a normal terminal state,
        # NOT a failure: treating it as one made every run retry the same empty
        # session forever and never advance the state file. Accept it and record
        # it so the run moves on.
        $producedNothing = ($dOut | Select-String -Pattern 'no human turns|no notes, nothing written' | Measure-Object).Count -gt 0

        if ($dCode -eq 0 -and -not $producedNothing) {
            Write-Log 'INFO' ("distilled {0} in {1:N1}s" -f $item.Id, $sw.Elapsed.TotalSeconds)
            $succeeded += $item
        }
        elseif ($dCode -eq 0 -and $producedNothing) {
            Write-Log 'INFO' ("{0}: no ingestible content (recorded, will not retry)" -f $item.Id)
            $succeeded += $item          # record it so we stop revisiting it
            $empty += $item
        }
        else {
            $failed += $item
            Write-Log 'ERROR' ("distill failed for {0} (exit {1})" -f $item.Id, $dCode)
            ($dOut | Select-Object -Last 4) | ForEach-Object { Add-Content $logFile ("    " + $_) -Encoding UTF8 }
        }
    }

    # One store pass covers every note written this run. Skip the pass entirely
    # when this run produced only "no content" sessions — there is nothing to
    # upload, and an empty store pass would just burn an API round-trip.
    $toStore = @($succeeded | Where-Object { $empty -notcontains $_ })
    if ($toStore.Count -gt 0) {
        $sOut = & $nodeExe (Join-Path $here 'store.mjs') '--dir' $notesDir 2>&1
        $sCode = $LASTEXITCODE
        $uploaded = ($sOut | Select-String -Pattern 'uploaded (\d+) document' | Select-Object -Last 1)
        $count = if ($uploaded) { $uploaded.Matches[0].Groups[1].Value } else { '?' }
        if ($sCode -eq 0) {
            Write-Log 'OK' ("stored {0} document(s) from {1} session(s) in {2:N1}s total" -f $count, $toStore.Count, $totalSec)
        } else {
            Write-Log 'ERROR' ("store exited {0}" -f $sCode)
            ($sOut | Select-Object -Last 6) | ForEach-Object { Add-Content $logFile ("    " + $_) -Encoding UTF8 }
            $failed += $toStore
            $succeeded = @($succeeded | Where-Object { $empty -contains $_ })   # keep only the empty ones as "done"
        }
    } elseif ($succeeded.Count -gt 0) {
        Write-Log 'INFO' ("nothing to store ({0} session(s) had no ingestible content)" -f $succeeded.Count)
    }

    # ------------------------------------------------------------ state update
    # Only mark sessions whose distill AND store both succeeded.
    if ($succeeded.Count -gt 0) {
        $newState = @{}
        foreach ($k in $state.Keys) { $newState[$k] = $state[$k] }
        foreach ($ok in $succeeded) {
            $newState[$ok.Id] = [pscustomobject]@{ mtime = $ok.Mtime; ingestedAt = (Get-Date).ToString('o') }
        }
        $newState | ConvertTo-Json -Depth 4 | Set-Content $stateFile -Encoding UTF8
        Write-Log 'INFO' ("state updated ({0} session(s) tracked)" -f $newState.Count)
    }

    if ($failed.Count -gt 0) { exit 1 }
    exit 0
}
finally {
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    if (Test-Path $logFile) {
        if ((Get-Item $logFile).Length -gt 1MB) {
            $old = Join-Path $logDir ("ingest-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item $logFile $old -Force
            Add-Content -Path $logFile -Value ("{0} [INFO] log rotated (previous: {1})" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $old) -Encoding UTF8
        }
    }
}
