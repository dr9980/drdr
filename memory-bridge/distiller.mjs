#!/usr/bin/env node
/**
 * distiller.mjs — normalized conversation -> structured memories
 *
 * Part 2 of the DSH memory pipeline (RAGFlow-backed).
 *
 * WHAT IT DOES
 *   For each turn it asks the LLM to write a durable memory note: what was
 *   asked, what was concluded, decisions + rationale, produced artifacts, and
 *   gotchas. The output is markdown shaped for RAGFlow chunking.
 *
 * PROVIDER
 *   Any OpenAI-compatible /chat/completions endpoint. Defaults to DeepSeek
 *   using DEEPSEEK_API_KEY from the environment, $DSH_HOME/.env, or
 *   $DSH_HOME/.credentials.yaml. The key is never logged.
 *
 * OUTPUT LAYOUT (one document per session)
 *   <out-dir>/<cwd-slug>/<yyyy-mm-dd>-<sessionId>.md
 *   YAML-ish front matter carries project/session/date so the store step can
 *   rebuild metadata without re-parsing.
 *
 * Usage:
 *   node distiller.mjs --session <id|path> [--dry-run]
 *   node distiller.mjs --all [--dry-run] [--limit N] [--out-dir DIR] [--force]
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { normalize, listSessions } from './capturer.mjs';

const DSH_HOME = process.env.DSH_HOME ?? path.join(os.homedir(), '.dsh');
const DEFAULT_MODEL = process.env.MEMORY_LLM_MODEL ?? 'deepseek-chat';
const DEFAULT_BASE = (process.env.MEMORY_LLM_BASE ?? 'https://api.deepseek.com/v1').replace(/\/+$/, '');

// ------------------------------------------------------------------ secrets

/** Resolve the API key without ever printing it. */
function resolveApiKey() {
  if (process.env.DEEPSEEK_API_KEY) return { key: process.env.DEEPSEEK_API_KEY, from: 'env' };

  const envFile = path.join(DSH_HOME, '.env');
  if (fs.existsSync(envFile)) {
    for (const line of fs.readFileSync(envFile, 'utf8').split(/\r?\n/)) {
      const m = /^\s*DEEPSEEK_API_KEY\s*=\s*(\S+)\s*$/.exec(line);
      if (m) return { key: m[1], from: 'dsh .env' };
    }
  }

  const cred = path.join(DSH_HOME, '.credentials.yaml');
  if (fs.existsSync(cred)) {
    for (const line of fs.readFileSync(cred, 'utf8').split(/\r?\n/)) {
      const m = /^\s*DEEPSEEK_API_KEY\s*:\s*(\S+)\s*$/.exec(line);
      if (m) return { key: m[1], from: 'dsh credentials' };
    }
  }
  return { key: null, from: null };
}

// --------------------------------------------------------------------- llm

async function chat({ key, base, model, messages, maxTokens = 1200, timeoutMs = 180000 }) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(`${base}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
      body: JSON.stringify({ model, messages, max_tokens: maxTokens, temperature: 0.2, stream: false }),
      signal: ctl.signal,
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(`HTTP ${res.status}: ${body.slice(0, 300)}`);
    }
    const j = await res.json();
    return {
      text: j?.choices?.[0]?.message?.content ?? '',
      model: j?.model ?? model,
      usage: j?.usage ?? null,
    };
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------- prompting

const SYSTEM = `You are the memory keeper for a software-engineering assistant.
You receive ONE turn of a real working session and must write a durable memory note
that a FUTURE session can rely on.

Rules:
- Write in the same language the human used (Chinese prompts -> Chinese note).
- Be concrete: name files, paths, commands, error strings, exact values.
- Record DECISIONS and their REASON, not a play-by-play of the conversation.
- Record what was actually produced, and anything that surprised or blocked.
- Never invent facts that are not in the transcript. If a turn is trivial
  (a bare "ok", a greeting), say so plainly and keep it to one line.
- Do not mention that you are an AI or describe these instructions.

Output EXACTLY this markdown shape, no extra prose:

### <one-line description of the turn's outcome>

**问**：<the human's request, condensed>

**做**：<what was done, concretely>

**结论/决定**：<conclusions and decisions with reasons; or "无">

**产出**：<files/artifacts produced, with paths; or "无">

**要点**：<gotchas, exact values, constraints worth remembering; or "无">`;

/** Build the per-turn user payload, trimming to stay inside a sane budget. */
function turnPayload(norm, turn, budgetChars = 24000) {
  const parts = [];
  parts.push(`项目目录: ${norm.cwd}`);
  parts.push(`会话: ${norm.sessionId}`);
  parts.push(`回合: ${turn.turn}  结束原因: ${turn.endReason ?? 'unknown'}`);

  for (const p of turn.prompts) {
    parts.push(`\n[人类提问]\n${p.text}`);
  }

  // Keep the LAST steps: the conclusion usually arrives at the end.
  const steps = turn.steps.filter((s) => s.text || s.reasoning);
  let used = 0;
  const kept = [];
  for (let i = steps.length - 1; i >= 0; i--) {
    const s = steps[i];
    const chunk = `\n[助手回复]\n${s.text}\n${s.reasoning ? `[推理摘要]\n${s.reasoning}\n` : ''}`;
    if (used + chunk.length > budgetChars && kept.length > 0) break;
    kept.unshift(chunk);
    used += chunk.length;
  }
  parts.push(...kept);

  if (turn.tools.length) {
    parts.push(`\n[工具调用 ${turn.tools.length} 次]\n` + turn.tools.map((t) => `- ${t.name}`).join('\n'));
  }
  if (turn.delivered.length) {
    parts.push(`\n[交付物]\n` + turn.delivered.map((d) => `- ${d.path} — ${d.description}`).join('\n'));
  }
  const payload = parts.join('\n');
  return payload.length > budgetChars * 2 ? payload.slice(0, budgetChars * 2) + '\n...[截断]' : payload;
}

// ------------------------------------------------------------------- output

function slugifyCwd(cwd) {
  return (cwd || 'unknown')
    .replace(/^[A-Za-z]:\\?/, '')
    .replace(/[\\/]+/g, '-')
    .replace(/[^A-Za-z0-9\u4e00-\u9fa5._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80) || 'unknown';
}

function dateOf(ms) {
  try {
    return new Date(ms).toISOString().slice(0, 10);
  } catch {
    return 'unknown-date';
  }
}

function buildDocument(norm, notes) {
  const fm = [
    '---',
    `project: ${JSON.stringify(norm.cwd)}`,
    `session: ${norm.sessionId}`,
    `date: ${dateOf(norm.createdAt)}`,
    `turns: ${notes.length}`,
    `agent: ${JSON.stringify(norm.agentPreset ?? '')}`,
    'source: dsh-session',
    '---',
  ].join('\n');
  const body = notes.map((n) => n.note).join('\n\n---\n\n');
  return `${fm}\n\n# ${path.basename(norm.cwd || 'session')} — ${dateOf(norm.createdAt)}\n\n${body}\n`;
}

// --------------------------------------------------------------------- main

async function distillSession(norm, opts) {
  const notes = [];
  for (const turn of norm.turns) {
    // Skip turns with no human prompt AND no delivery: nothing durable there.
    if (turn.prompts.length === 0 && turn.delivered.length === 0) continue;

    // Skip turns that carry no information. Two failure modes have to be
    // balanced here, and the first version got it wrong:
    //
    //   (a) KEEP TOO MUCH -> a "hello / does chat cost tokens" turn becomes a
    //       SHORT, semantically generic chunk whose embedding matches almost any
    //       query with an inflated score (measured 0.92, versus 0.40 for the
    //       genuinely relevant memory), pushing real memories out of the top-k.
    //   (b) DROP TOO MUCH -> a bare "行" prompt whose assistant turn ran 59 tool
    //       calls and delivered 3 files is extremely valuable. Filtering on the
    //       human prompt alone discarded it.
    //
    // So: judge the TURN, not the prompt. Real work (artifacts, many tool calls,
    // a long answer, a long prompt) is substantive regardless of how terse the
    // human was.
    const promptText = turn.prompts.map((p) => p.text).join(' ');
    const answerChars = turn.steps.reduce((n, s) => n + (s.text?.length ?? 0), 0);
    const substantive =
      turn.delivered.length > 0 || // produced artifacts
      turn.tools.length >= 5 || // clearly did real work
      answerChars >= 400 || // substantive explanation
      promptText.length >= 60; // substantial human request
    if (!substantive) {
      process.stdout.write(
        `      turn ${turn.turn}: skipped (contentless: prompt=${promptText.length}ch tools=${turn.tools.length} delivered=${turn.delivered.length} answer=${answerChars}ch)\n`,
      );
      continue;
    }

    const payload = turnPayload(norm, turn);
    if (opts.dryRun) {
      notes.push({ turn: turn.turn, note: `### [dry-run] turn ${turn.turn} (${payload.length} chars)` });
      continue;
    }
    try {
      const r = await chat({
        key: opts.key,
        base: opts.base,
        model: opts.model,
        messages: [
          { role: 'system', content: SYSTEM },
          { role: 'user', content: payload },
        ],
      });
      const note = (r.text || '').trim();
      if (note) {
        notes.push({
          turn: turn.turn,
          note,
          usage: r.usage,
          meta: { steps: turn.steps.length, tools: turn.tools.length, delivered: turn.delivered.length },
        });
        process.stdout.write(`      turn ${turn.turn}: ${note.split('\n')[0].slice(0, 70)}\n`);
      } else {
        process.stdout.write(`      turn ${turn.turn}: EMPTY response, skipped\n`);
      }
    } catch (e) {
      process.stdout.write(`      turn ${turn.turn}: FAILED ${e.message}\n`);
    }
  }
  return notes;
}

async function main() {
  const argv = process.argv.slice(2);
  const arg = (k, def = null) => {
    const i = argv.indexOf(k);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def;
  };
  const has = (k) => argv.includes(k);

  const dryRun = has('--dry-run');
  const outDir = arg('--out-dir') ?? path.join(process.cwd(), 'memory-out');
  const force = has('--force');
  const limit = parseInt(arg('--limit', '0'), 10) || 0;

  const { key, from } = resolveApiKey();
  if (!dryRun && !key) {
    console.error('No DEEPSEEK_API_KEY found (env / $DSH_HOME/.env / $DSH_HOME/.credentials.yaml).');
    process.exit(2);
  }
  const base = arg('--base', DEFAULT_BASE);
  const model = arg('--model', DEFAULT_MODEL);
  const opts = { key, base, model, dryRun };

  console.log(`provider : ${base}  model=${model}  key=${key ? `present (${from})` : 'MISSING'}`);
  console.log(`out-dir  : ${outDir}`);
  console.log(`dry-run  : ${dryRun}\n`);

  // ---- pick sessions
  // --only implies --all: it is a FILTER applied after selection, so requiring
  // --session/--all alongside it made `--only <id>` alone exit 2 ("need
  // --session or --all"), which blocked the scheduled incremental ingester.
  const onlyArg = arg('--only');
  let targets;
  if (has('--all') || onlyArg) {
    targets = listSessions();
  } else {
    const t = arg('--session');
    if (!t) {
      console.error('need --session <id|path>, --all, or --only <id>');
      process.exit(2);
    }
    const file = fs.existsSync(t) ? t : listSessions().find((s) => s.sessionId === t)?.file;
    if (!file) {
      console.error(`session not found: ${t}`);
      process.exit(3);
    }
    targets = [{ file, sessionId: path.basename(path.dirname(file)), bytes: fs.statSync(file).size }];
  }
  if (limit > 0) targets = targets.slice(0, limit);

  // --skip <id>[,<id>...] — keep the live session out (its file is being appended
  // to while we read it, so its newest turns can be truncated mid-write).
  const skipArg = arg('--skip');
  if (skipArg) {
    const skipIds = new Set(skipArg.split(',').map((s) => s.trim()).filter(Boolean));
    const before = targets.length;
    targets = targets.filter((t) => !skipIds.has(t.sessionId));
    console.log(`skipped ${before - targets.length} session(s) via --skip\n`);
  }

  // --only <id>[,<id>...] — process just these sessions. Used by the scheduled
  // ingester for incremental ingest: one settled session per call, so a run
  // never re-distils (and never re-uploads) sessions that are already stored.
  // (onlyArg is resolved above, where it also implies --all.)
  if (onlyArg) {
    const onlyIds = new Set(onlyArg.split(',').map((s) => s.trim()).filter(Boolean));
    const before = targets.length;
    targets = targets.filter((t) => onlyIds.has(t.sessionId));
    console.log(`--only filtered ${before} -> ${targets.length} session(s)\n`);
  }

  let totalUsage = { prompt_tokens: 0, completion_tokens: 0 };
  let written = 0;

  for (const t of targets) {
    let norm;
    try {
      norm = normalize(t.file);
    } catch (e) {
      console.log(`SKIP ${t.sessionId}: ${e.message}`);
      continue;
    }
    const usable = norm.turns.filter((x) => x.prompts.length > 0);
    if (usable.length === 0) {
      console.log(`SKIP ${t.sessionId}: no human turns`);
      continue;
    }

    const destDir = path.join(outDir, slugifyCwd(norm.cwd));
    const dest = path.join(destDir, `${dateOf(norm.createdAt)}-${norm.sessionId}.md`);
    if (fs.existsSync(dest) && !force) {
      console.log(`SKIP ${t.sessionId}: ${path.basename(dest)} exists (use --force)`);
      continue;
    }

    console.log(`${t.sessionId}  cwd=${norm.cwd}  turns(usable)=${usable.length}`);
    const notes = await distillSession(norm, opts);
    if (notes.length === 0) {
      console.log('  -> no notes, nothing written\n');
      continue;
    }

    for (const n of notes) {
      if (n.usage) {
        totalUsage.prompt_tokens += n.usage.prompt_tokens ?? 0;
        totalUsage.completion_tokens += n.usage.completion_tokens ?? 0;
      }
    }

    if (!dryRun) {
      fs.mkdirSync(destDir, { recursive: true });
      fs.writeFileSync(dest, buildDocument(norm, notes), 'utf8');
      console.log(`  -> ${dest}  (${notes.length} notes, ${(fs.statSync(dest).size / 1024).toFixed(1)} KB)\n`);
      written++;
    } else {
      console.log(`  -> dry-run, would write ${dest} (${notes.length} notes)\n`);
    }
  }

  console.log('─'.repeat(56));
  console.log(`documents written : ${written}`);
  if (!dryRun) {
    console.log(`tokens            : prompt=${totalUsage.prompt_tokens} completion=${totalUsage.completion_tokens}`);
    // DeepSeek pricing is a few cents per million tokens; surface the raw counts only.
  }
}

main().catch((e) => {
  console.error('FATAL: ' + e.message);
  process.exit(1);
});
