# API Security Findings — local services

**Suite**: `run-tests.ps1` (same directory)
**Latest run**: 2026-09-18 20:55 → PASS 15 / FAIL 0 / WARN 0 / SKIP 2
**Previous run**: 2026-09-18 20:50 → PASS 14 / FAIL 0 / WARN 1 / SKIP 2 (F-01 open)
**Scope**: services bound to this machine only — `127.0.0.1:19380` (RAGFlow),
`127.0.0.1:3080` (DSH web), `127.0.0.1:11434` (Ollama).

> **Authorization boundary.** This suite targets **only** services on this host.
> The `api-security-tester` skill's own example uses `https://example.com/redirect`
> as a placeholder; testing a domain you do not own is unauthorized and was
> deliberately **not** performed.

---

## Findings

### F-01 — Ollama binds to all interfaces, and it is an explicit setting (RESOLVED)

**Severity**: Low as measured — was not exploitable given the firewall.
**Status**: **Resolved 2026-09-18 20:55** — see *Resolution* at the end of this finding.
**Residual**: `Machine`-scope `OLLAMA_HOST` still reads `:11434` (needs admin to change).

**What was observed**

- `Get-NetTCPConnection` shows Ollama listening on `::` (every interface), not loopback.
- An unauthenticated `GET /api/tags` from the host's own WLAN address
  (`10.39.123.4`) returned **HTTP 200** and disclosed the installed models
  (`qwen3-embedding:8b`, `deepseek-r1:8b`). `/api/version` and `/api/ps` also 200.
- **`OLLAMA_HOST` is set to `:11434` at BOTH `User` and `Machine` scope.**
  A bare `:11434` means "all interfaces", so this is a deliberate configuration,
  not a default. Someone chose to expose Ollama to the network.

**Why it is only a WARN**

The 200 above was measured **host-to-its-own-LAN-IP**, which does not traverse the
Windows Firewall's inbound filtering. It therefore proves the *bind*, not external
*reachability*. The actual external controls were then checked:

| Control | State |
|---|---|
| Firewall profiles | Domain / Private / Public all **Enabled** |
| `DefaultInboundAction` | `NotConfigured` → Windows default = **Block** |
| Inbound allow rule for Ollama or TCP 11434 | **none exists** |

So no remote host can currently reach it. The finding is about **defence in depth**:
Ollama has no authentication by design, so with a wildcard bind the host firewall
is the *only* thing standing between the LAN and the API. Any future allow rule,
a prompt the user clicks "Allow" on, or a profile change removes that single layer
and the exposure becomes immediate.

**Blast radius if it ever becomes reachable** (Ollama's API is unauthenticated):

- `/api/chat`, `/api/generate`, `/api/embed` — free inference on this machine
- `/api/pull` — download arbitrary models; disk exhaustion
- `DELETE /api/delete` — delete local models (multi-GB re-downloads)
- `/api/ps` — leak which models are loaded

**Reproduction**

```powershell
Get-NetTCPConnection -State Listen | Where-Object LocalPort -eq 11434
curl.exe -s http://10.39.123.4:11434/api/tags          # 200, no Authorization sent
Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow |
  ForEach-Object { $_ | Get-NetFirewallPortFilter } | Where-Object LocalPort -contains '11434'
```

**Remediation** — two options, pick by intent:

*If remote access was never intended* (recommended, and nothing here needs it —
the DSH local-AI bridge connects to `http://127.0.0.1:11434`, so this is free):

```powershell
[Environment]::SetEnvironmentVariable('OLLAMA_HOST','127.0.0.1:11434','User')
[Environment]::SetEnvironmentVariable('OLLAMA_HOST','127.0.0.1:11434','Machine')  # needs admin
```

Then quit Ollama from the tray and relaunch it (it runs as a user app —
`D:\ollama\ollama.exe`, no Windows service, with a Startup entry).

*If remote access IS wanted*: leave the bind, but then the firewall is the only
control — add an explicit scoped allow rule (specific source subnet, never `Any`)
and understand that anything on that subnet gets unauthenticated model access.

**Resolution** (remote access was not needed — the DSH local-AI bridge targets
`http://127.0.0.1:11434`, so loopback-only costs nothing):

1. `[Environment]::SetEnvironmentVariable('OLLAMA_HOST','127.0.0.1:11434','User')`
   — User scope is sufficient: Windows composes a process's environment with
   **User overriding Machine** for duplicate names, and Ollama launches from this
   user's Startup folder (`ollama app.exe` → `ollama.exe serve`), never as a service.
2. Restart Ollama.

**Operational gotcha hit while doing this — worth remembering.** The first restart
appeared to do nothing: Ollama came back still bound to `::`. Cause: `Start-Process`
hands the child **the calling process's environment block**, not a fresh one built
from the registry. The launching shell still held the stale `OLLAMA_HOST=:11434`
inherited from the DSH host, which had started before the registry change. Setting
`$env:OLLAMA_HOST` in the launching process before `Start-Process` fixed it. Any
registry env-var change needs a launching context that does not carry the old value.

**Verified after the change**

| Check | Before | After |
|---|---|---|
| `Get-NetTCPConnection -LocalPort 11434` | `::` | `127.0.0.1` |
| `GET http://127.0.0.1:11434/api/tags` | 200 | 200 (unchanged) |
| `GET http://10.39.123.4:11434/api/tags` | 200 | **000** (no longer bound) |
| Suite check C2 | WARN | **PASS** |
| DSH MCP bridge `ollama_list_models` | works | works (2 models) |

**Residual item — needs an elevated shell.** `Machine`-scope `OLLAMA_HOST` is still
`:11434`. It does not affect Ollama today (User wins for this user) but it would
apply to any process started under a *different* account or as a service:

```powershell
# from an Administrator shell
[Environment]::SetEnvironmentVariable('OLLAMA_HOST','127.0.0.1:11434','Machine')
```

---

### F-02 — RAGFlow stack was down; MCP bridge tools were failing (RESOLVED)

**Severity**: Operational, not a vulnerability. **Status**: Resolved.

Docker Desktop was not running (no process, no `dockerDesktopLinuxEngine` pipe),
so RAGFlow + MySQL + Elasticsearch + MinIO + Redis were all down. The DSH MCP
bridge process stayed alive but its `ragflow_*` tools necessarily failed.

Cause could not be attributed with evidence: the engine was verified healthy with
5 containers up earlier in the same session, and nothing Docker-related ran
between that check and the discovery.

Resolved by starting Docker Desktop; all 5 containers are healthy and
`GET /api/v1/datasets` returns 200.

**Note**: this is why the suite reports `SKIP` (exit 0) rather than `FAIL` when a
target is unreachable — an outage is not a security regression.

---

## Positive controls (verified, no action needed)

| Check | Result |
|---|---|
| RAGFlow rejects missing / empty / forged / wrong-scheme credentials | 401 on all four |
| RAGFlow does **not** honour a token supplied via query string | 401 (A5) |
| RAGFlow accepts a valid token | 200 (A6, control) |
| RAGFlow returns no 5xx on `page_size=abc` / `-1` / `999999999999` | 200, input clamped |
| RAGFlow rejects path traversal in a dataset id | 404 |
| **DSH web UI is loopback-only** | `127.0.0.1` only, unreachable via either LAN IP |
| **Ollama is now loopback-only** (after the F-01 fix) | `127.0.0.1` only; LAN IP returns 000 |
| No inbound allow rule for the unauthenticated port | none |
| Firewall enabled on all three profiles | yes |

---

## Not covered, by design

| Item | Why |
|---|---|
| DSH web API authorization | Not REST — it is RPC-over-stream (`connection.rpc.call('/api', endpoint, …)`) behind a `claimsEndpoint` interceptor. Plain GETs prove nothing. Also: it is the server hosting the session, so probing carries session-disruption risk. |
| Ollama `/api/delete`, `/api/pull`, `/api/generate`, `/api/chat` | Mutating or resource-consuming. Out of scope for a non-destructive suite; never called. |
| Rate limiting | Not tested — deliberately. Flooding a live service is disruptive, and no target here is internet-exposed. |
| Redirect header preservation (the skill's headline example) | No local endpoint issues a redirect, so there is nothing to observe. RAGFlow and Ollama answer directly. |

## Tooling deviations (recorded because they affect reproducibility)

- The skill designates `web_fetch`, but it returns only decoded body text and
  exposes **no status code or response headers** — insufficient for the skill's own
  example, which reads `response.request.headers.authorization`. `curl` is used instead.
- The shell on this machine is **Windows PowerShell 5.1**, not 7:
  `-SkipHttpErrorCheck` does not exist, there is no ternary operator, and a
  `foreach` statement block cannot be piped directly. The suite is written to 5.1.

## Disclosure

The skill's private-first / 30-day / publish-after-fix process targets
**third-party** systems. Every finding here is on the operator's own machine, so
that process does not apply — there is no vendor to notify.

## Re-running

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run-tests.ps1
```

Exit code 0 = no FAIL (WARN/SKIP allowed). Exit code 1 = at least one FAIL.
Each run writes a timestamped record to `.\findings\`.
