<#
.SYNOPSIS
  Non-destructive API security test suite for the local services on THIS machine.

.DESCRIPTION
  Scope is deliberately narrow: only services bound to this host. Do not point
  these targets at systems you do not own or have written permission to test.

  Every test is a single GET. No mutating endpoint is ever called — Ollama's
  /api/delete, /api/pull, /api/generate and /api/chat are excluded on purpose,
  because they would change state or download multi-GB models.

  Results are PASS / FAIL / WARN / SKIP:
    PASS  behaves as the security expectation requires
    FAIL  a security expectation is violated        <- exit code 1
    WARN  hardening gap; not exploitable as measured
    SKIP  target not running (suite still exits 0)

  Written for Windows PowerShell 5.1 (no -SkipHttpErrorCheck, no ternary, and a
  foreach statement block cannot be piped directly).

.PARAMETER RagflowBase
  RAGFlow base URL. Default http://127.0.0.1:19380

.PARAMETER DshWebBase
  DSH web base URL. Default http://127.0.0.1:3080

.PARAMETER OllamaBase
  Ollama base URL. Default http://127.0.0.1:11434

.EXAMPLE
  pwsh -File run-tests.ps1

.NOTES
  The RAGFlow API key is read from $DSH_HOME/.env (RAGFLOW_API_KEY) and is never
  printed. See FINDINGS.md for the findings this suite was built from.
#>
[CmdletBinding()]
param(
  [string]$RagflowBase = 'http://127.0.0.1:19380',
  [string]$DshWebBase  = 'http://127.0.0.1:3080',
  [string]$OllamaBase  = 'http://127.0.0.1:11434',
  [string]$FindingsDir
)

# $PSScriptRoot is not populated yet while parameter defaults are evaluated, so
# it is resolved here instead.
if (-not $FindingsDir) {
  $scriptRoot = $PSScriptRoot
  if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
  $FindingsDir = Join-Path $scriptRoot 'findings'
}

$ErrorActionPreference = 'Continue'
$results = New-Object System.Collections.ArrayList

function Add-Result {
  param($Id, $Area, $Test, $Expect, $Actual, $Verdict, $Repro)
  [void]$results.Add([pscustomobject]@{
    Id = $Id; Area = $Area; Test = $Test; Expect = $Expect
    Actual = $Actual; Verdict = $Verdict; Repro = $Repro
  })
}

# --- one HTTP probe: returns the status code as a string ('000' = unreachable) ---
function Get-Status {
  param([string]$Url, [string[]]$Headers)
  $a = @('-s','-o','NUL','-w','%{http_code}','--max-time','10')
  foreach ($h in $Headers) { $a += @('-H', $h) }
  $a += $Url
  $code = (& curl.exe @a 2>$null)
  if ($null -eq $code) { return '000' }
  return ([string]$code).Trim()
}

function Get-Body {
  param([string]$Url, [string[]]$Headers)
  $a = @('-s','--max-time','10')
  foreach ($h in $Headers) { $a += @('-H', $h) }
  $a += $Url
  return ((& curl.exe @a 2>$null) -join '')
}

# --- resolve the RAGFlow key without ever echoing it ---
function Get-RagflowKey {
  $home2 = $env:DSH_HOME
  if (-not $home2) { $home2 = Join-Path $env:USERPROFILE '.dsh' }
  $envFile = Join-Path $home2 '.env'
  if (-not (Test-Path $envFile)) { return $null }
  $m = [regex]::Match((Get-Content $envFile -Raw), '(?m)^\s*RAGFLOW_API_KEY\s*=\s*(.+)$')
  if (-not $m.Success) { return $null }
  return $m.Groups[1].Value.Trim().Trim('"').Trim("'")
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' API security test suite - local services only' -ForegroundColor Cyan
Write-Host (" started {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date)) -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$key = Get-RagflowKey
$auth = @("Authorization: Bearer $key")
$ragflowUp = ((Get-Status "$RagflowBase/api/v1/datasets?page=1&page_size=1" $auth) -eq '200')

# ---------------------------------------------------------------- A. auth enforcement
$areaA = 'A. RAGFlow auth enforcement'
if (-not $ragflowUp) {
  foreach ($i in 1..6) {
    Add-Result "A$i" $areaA 'target not reachable' 'n/a' 'SKIP' 'SKIP' "start the Docker stack, then re-run"
  }
} elseif (-not $key) {
  foreach ($i in 1..6) {
    Add-Result "A$i" $areaA 'RAGFLOW_API_KEY not found' 'n/a' 'SKIP' 'SKIP' "add RAGFLOW_API_KEY to `$DSH_HOME/.env"
  }
} else {
  $base = "$RagflowBase/api/v1/datasets"
  $cases = @(
    @{ id='A1'; t='no Authorization header';      h=@();                                          e='401'; r="curl -i '$base'" },
    @{ id='A2'; t='empty Bearer value';           h=@('Authorization: Bearer ');                 e='401'; r="curl -i -H 'Authorization: Bearer ' '$base'" },
    @{ id='A3'; t='forged token';                 h=@('Authorization: Bearer not-a-real-key');   e='401'; r="curl -i -H 'Authorization: Bearer not-a-real-key' '$base'" },
    @{ id='A4'; t='wrong scheme (Basic)';         h=@('Authorization: Basic cmFnd2xvdzp4');      e='401'; r="curl -i -H 'Authorization: Basic cmFnd2xvdzp4' '$base'" },
    @{ id='A5'; t='token in query, no header';    h=@();                                          e='401'; r="curl -i '$base`?Authorization=Bearer%20<token>'" },
    @{ id='A6'; t='valid token (control)';        h=$auth;                                        e='200'; r="curl -i -H 'Authorization: Bearer <token>' '$base'" }
  )
  foreach ($c in $cases) {
    $url = $base
    if ($c.id -eq 'A5') { $url = "$base`?Authorization=Bearer%20$key" }
    $got = Get-Status $url $c.h
    $ok = ($got -eq $c.e)
    Add-Result $c.id $areaA $c.t "HTTP $($c.e)" "HTTP $got" $(if ($ok) { 'PASS' } else { 'FAIL' }) $c.r
  }
}

# ---------------------------------------------------------------- B. input validation
$areaB = 'B. RAGFlow input validation'
if (-not $ragflowUp -or -not $key) {
  foreach ($i in 1..4) { Add-Result "B$i" $areaB 'target not ready' 'n/a' 'SKIP' 'SKIP' 'start the Docker stack, then re-run' }
} else {
  $b = "$RagflowBase/api/v1/datasets"
  $cases = @(
    @{ id='B1'; t='page_size=abc';            u="$b`?page=1&page_size=abc";            r="curl -i -H 'Authorization: Bearer <token>' `"$b`?page=1&page_size=abc`"" },
    @{ id='B2'; t='page_size=-1';             u="$b`?page=1&page_size=-1";             r="curl -i -H 'Authorization: Bearer <token>' `"$b`?page=1&page_size=-1`"" },
    @{ id='B3'; t='page_size=999999999999';   u="$b`?page=1&page_size=999999999999";   r="curl -i -H 'Authorization: Bearer <token>' `"$b`?page=1&page_size=999999999999`"" },
    @{ id='B4'; t='id path traversal';        u="$b/..%2F..%2Fv1%2Fdatasets/documents"; r="curl -i -H 'Authorization: Bearer <token>' `"$b/..%2F..%2Fv1%2Fdatasets/documents`"" }
  )
  foreach ($c in $cases) {
    $got = Get-Status $c.u $auth
    # An unhandled input shows up as 5xx. 4xx is fine; 2xx is fine if clamped.
    $verdict = 'PASS'
    if ($got -like '5*') { $verdict = 'FAIL' }
    if ($got -eq '000')  { $verdict = 'SKIP' }
    Add-Result $c.id $areaB $c.t 'no 5xx' "HTTP $got" $verdict $c.r
  }
}

# ---------------------------------------------------------------- C. exposure / bind surface
$areaC = 'C. Network exposure'
$listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)

function Get-BindSummary {
  param([int]$Port)
  $hit = @($listeners | Where-Object { $_.LocalPort -eq $Port } | Select-Object -ExpandProperty LocalAddress -Unique)
  if ($hit.Count -eq 0) { return 'not listening' }
  return ($hit -join ',')
}

# C1: the DSH web UI must stay loopback-only
$dshBind = Get-BindSummary 3080
if ($dshBind -eq 'not listening') {
  Add-Result 'C1' $areaC 'DSH web loopback-only' 'all 127.0.0.1' $dshBind 'SKIP' 'netstat -ano | findstr :3080'
} elseif ($dshBind -notmatch '^(127\.0\.0\.1|\[::1\])(,(127\.0\.0\.1|\[::1\]))*$') {
  Add-Result 'C1' $areaC 'DSH web loopback-only' 'all 127.0.0.1' $dshBind 'FAIL' 'Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 3080'
} else {
  Add-Result 'C1' $areaC 'DSH web loopback-only' 'all 127.0.0.1' $dshBind 'PASS' 'Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 3080'
}

# C2: Ollama should be loopback-bound. It has no auth by design, so a wildcard
# bind leaves the host firewall as the only control. Hardening, not a breach.
$ollamaBind = Get-BindSummary 11434
if ($ollamaBind -eq 'not listening') {
  Add-Result 'C2' $areaC 'Ollama loopback-only' 'all 127.0.0.1' $ollamaBind 'SKIP' 'netstat -ano | findstr :11434'
} elseif ($ollamaBind -match '^(0\.0\.0\.0|::)$') {
  Add-Result 'C2' $areaC 'Ollama loopback-only (no auth by design)' 'all 127.0.0.1' $ollamaBind 'WARN' "set OLLAMA_HOST=127.0.0.1:11434 and restart Ollama"
} else {
  Add-Result 'C2' $areaC 'Ollama loopback-only' 'all 127.0.0.1' $ollamaBind 'PASS' 'Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 11434'
}

# C3: no inbound allow rule for the unauthenticated port
$allow11434 = @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue | Where-Object {
  $pf = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
  $pf.LocalPort -contains '11434'
})
if ($allow11434.Count -gt 0) {
  Add-Result 'C3' $areaC 'no inbound allow rule for TCP 11434' 'none' "$($allow11434.Count) rule(s)" 'FAIL' 'Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow | Get-NetFirewallPortFilter'
} else {
  Add-Result 'C3' $areaC 'no inbound allow rule for TCP 11434' 'none' 'none' 'PASS' 'Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow | Get-NetFirewallPortFilter'
}

# C4: firewall must be on for every profile
$profiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
$off = @($profiles | Where-Object { -not $_.Enabled })
if ($off.Count -gt 0) {
  Add-Result 'C4' $areaC 'firewall enabled on all profiles' 'Domain/Private/Public on' (($off | ForEach-Object { $_.Name }) -join ',') + ' off' 'FAIL' 'Get-NetFirewallProfile'
} else {
  Add-Result 'C4' $areaC 'firewall enabled on all profiles' 'Domain/Private/Public on' 'all on' 'PASS' 'Get-NetFirewallProfile'
}

# ---------------------------------------------------------------- D. Ollama reachability
$areaD = 'D. Ollama API'
$oTags = Get-Status "$OllamaBase/api/tags" @()
if ($oTags -eq '000') {
  Add-Result 'D1' $areaD 'loopback unauthenticated read (control)' 'HTTP 200' "HTTP $oTags" 'SKIP' "curl -s $OllamaBase/api/tags"
} else {
  # 200 is expected here: Ollama is unauthenticated by design. Recorded, not failed.
  Add-Result 'D1' $areaD 'loopback unauthenticated read (by design)' 'HTTP 200' "HTTP $oTags" $(if ($oTags -eq '200') { 'PASS' } else { 'WARN' }) "curl -s $OllamaBase/api/tags"
}

# ---------------------------------------------------------------- E. not covered
$areaE = 'E. Not covered by design'
Add-Result 'E1' $areaE 'DSH web API authorization' 'n/a' 'RPC-over-stream, not REST' 'SKIP' 'requires implementing the /api RPC envelope; also carries session-disruption risk'
Add-Result 'E2' $areaE 'Ollama mutating endpoints' 'n/a' 'not called' 'SKIP' '/api/delete and /api/pull change state or download models - out of non-destructive scope'

# ---------------------------------------------------------------- report
Write-Host ''
$results | Format-Table -AutoSize -Property Id, Area, Test, Expect, Actual, Verdict

$fails = @($results | Where-Object { $_.Verdict -eq 'FAIL' })
$warns = @($results | Where-Object { $_.Verdict -eq 'WARN' })
$skips = @($results | Where-Object { $_.Verdict -eq 'SKIP' })
$passes = @($results | Where-Object { $_.Verdict -eq 'PASS' })

Write-Host ("PASS {0}   FAIL {1}   WARN {2}   SKIP {3}" -f $passes.Count, $fails.Count, $warns.Count, $skips.Count) -ForegroundColor $(if ($fails.Count -gt 0) { 'Red' } elseif ($warns.Count -gt 0) { 'Yellow' } else { 'Green' })

foreach ($f in $fails) {
  Write-Host ''
  Write-Host ("FAIL {0} - {1}" -f $f.Id, $f.Test) -ForegroundColor Red
  Write-Host ("  expected : {0}" -f $f.Expect)
  Write-Host ("  actual   : {0}" -f $f.Actual)
  Write-Host ("  repro    : {0}" -f $f.Repro)
}

# ---------------------------------------------------------------- persist
if (-not (Test-Path $FindingsDir)) { New-Item -ItemType Directory -Path $FindingsDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$outFile = Join-Path $FindingsDir "$stamp.md"
$md = New-Object System.Collections.ArrayList
[void]$md.Add("# API security test run - $stamp")
[void]$md.Add('')
[void]$md.Add(("Scope: local services only ({0}, {1}, {2})" -f $RagflowBase, $DshWebBase, $OllamaBase))
[void]$md.Add('')
[void]$md.Add(("Totals: PASS {0} / FAIL {1} / WARN {2} / SKIP {3}" -f $passes.Count, $fails.Count, $warns.Count, $skips.Count))
[void]$md.Add('')
[void]$md.Add('| Id | Area | Test | Expected | Actual | Verdict |')
[void]$md.Add('|---|---|---|---|---|---|')
foreach ($r in $results) {
  [void]$md.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f $r.Id, $r.Area, $r.Test, $r.Expect, $r.Actual, $r.Verdict))
}
[void]$md.Add('')
[void]$md.Add('## Reproduction commands')
[void]$md.Add('')
foreach ($r in $results) { [void]$md.Add(("- **{0}** ``{1}``" -f $r.Id, $r.Repro)) }
Set-Content -Path $outFile -Value ($md -join "`r`n") -Encoding UTF8
Write-Host ''
Write-Host "run recorded: $outFile"

if ($fails.Count -gt 0) { exit 1 }
exit 0
