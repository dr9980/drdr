# register-ingest-task.ps1 — register the scheduled DSH memory ingestion task
#
# Creates a Windows Task Scheduler entry that runs auto-ingest.ps1 unattended.
#
# DESIGN CHOICES (and why)
#   - Runs only when the user is logged on. A fully unattended "run whether user
#     is logged on or not" task would require storing the account password via
#     -User/-Password, which is worse than the benefit for a desktop machine.
#     Login-only also matches the reality that Docker Desktop (which RAGFlow
#     needs) only runs in an interactive session.
#   - Repetition every 6 hours, indefinitely. The ingestion is incremental, so a
#     run with nothing new costs a few seconds.
#   - Does NOT auto-start Docker. If Docker is stopped the pipeline fails fast
#     and logs the error; starting Docker would fight the user's own choices.
#   - ExecutionTimeLimit 30 min so a hung run cannot linger for days.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File register-ingest-task.ps1            # register
#   powershell -ExecutionPolicy Bypass -File register-ingest-task.ps1 -Remove    # unregister
#   powershell -ExecutionPolicy Bypass -File register-ingest-task.ps1 -Status    # show

[CmdletBinding()]
param(
    [string]$TaskName = 'DSH-Memory-Ingest',
    [int]$EveryHours = 6,
    [switch]$Remove,
    [switch]$Status,
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'auto-ingest.ps1'

if ($Status) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host "task '$TaskName' is NOT registered"; exit 1 }
    Write-Host "task: $TaskName"
    Write-Host "  state    : $($t.State)"
    $i = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host "  last run : $($i.LastRunTime)"
    Write-Host "  last code: $($i.LastTaskResult)"
    Write-Host "  next run : $($i.NextRunTime)"
    Write-Host "  runs     : $($i.NumberOfMissedRuns) missed"
    $t.Triggers | ForEach-Object { Write-Host "  trigger  : every $($_.Repetition.Interval)" }
    exit 0
}

if ($Remove) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host "task '$TaskName' is not registered; nothing to do"; exit 0 }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "unregistered '$TaskName'"
    exit 0
}

if (-not (Test-Path $script)) { throw "auto-ingest.ps1 not found at $script" }

$pwshExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $pwshExe) { $pwshExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

$action = New-ScheduledTaskAction `
    -Execute $pwshExe `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`"" `
    -WorkingDirectory $PSScriptRoot

# Start 5 minutes from now, then repeat every $EveryHours forever.
$startAt = (Get-Date).AddMinutes(5)
$trigger = New-ScheduledTaskTrigger -Once -At $startAt `
    -RepetitionInterval (New-TimeSpan -Hours $EveryHours)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances IgnoreNew

# Run in the current user's interactive context (no stored password).
$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "task '$TaskName' already exists — replacing"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'Incrementally ingests settled DSH sessions into the RAGFlow memory library (memory-bridge). Never touches the chat path.' | Out-Null

Write-Host "registered '$TaskName'"
Write-Host "  script  : $script"
Write-Host "  schedule: every $EveryHours h, first run at $($startAt.ToString('HH:mm'))"
Write-Host "  limits  : 30 min max runtime, overlaps ignored"

if ($RunNow) {
    Write-Host ''
    Write-Host 'starting a run now to verify...'
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 20
    $i = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host "  state: $((Get-ScheduledTask -TaskName $TaskName).State)  last result: $($i.LastTaskResult)"
}
