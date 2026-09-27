#!/usr/bin/env node
/**
 * inject.mjs — auto-inject relevant memories into the live session
 *
 * Part 4 (the "memory" half) of the DSH memory pipeline.
 *
 * This is what turns the store into a memory system: without it, retrieval only
 * happens when the model chooses to call a tool. Wired to the DSH hook bridge's
 * UserPromptSubmit seam, relevant memories from previous sessions are appended
 * to the prompt context automatically.
 *
 * HOOK CONTRACT (Claude Code dialect, implemented by @deepseek-ai/dsh-hooks-claude-code)
 *   stdin : JSON with at least { session_id, cwd, hook_event_name, prompt }
 *   stdout: a JSON object whose additionalContext is folded into the prompt
 *   Exit non-zero or print nothing -> the hook is a no-op and the turn proceeds.
 *
 * Junk-in-the-prompt risk: a hook that throws or emits malformed output can break
 * every turn, so this script is written to fail silently and cheaply. It also
 * timeboxes the retrieval call.
 *
 * Usage (standalone, for testing):
 *   echo '{"prompt":"git ssh 插件安装失败","cwd":"D:\\deepseek-Harness"}' | node inject.mjs
 *   node inject.mjs --query "怎么做代理" [--top 5]
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const DSH_HOME = process.env.DSH_HOME ?? path.join(os.homedir(), '.dsh');
const BASE = (process.env.RAGFLOW_BASE_URL ?? 'http://127.0.0.1:19380').replace(/\/+$/, '');
const DATASET_NAME = process.env.MEMORY_DATASET ?? 'dsh-memory';
const TOP = parseInt(process.env.MEMORY_TOP ?? '4', 10) || 4;
const MIN_SIM = parseFloat(process.env.MEMORY_MIN_SIM ?? '0.35') || 0.35;
const TIMEOUT_MS = parseInt(process.env.MEMORY_TIMEOUT_MS ?? '8000', 10) || 8000;
const MAX_CHARS_PER_HIT = 700;

function apiKey() {
  if (process.env.RAGFLOW_API_KEY) return process.env.RAGFLOW_API_KEY;
  const envFile = path.join(DSH_HOME, '.env');
  if (fs.existsSync(envFile)) {
    for (const l of fs.readFileSync(envFile, 'utf8').split(/\r?\n/)) {
      const m = /^\s*RAGFLOW_API_KEY\s*=\s*(.+?)\s*$/.exec(l);
      if (m) return m[1];
    }
  }
  return null;
}

async function datasetId(key, signal) {
  const res = await fetch(`${BASE}/api/v1/datasets?name=${encodeURIComponent(DATASET_NAME)}`, {
    headers: { Authorization: `Bearer ${key}` },
    signal,
  });
  const j = await res.json();
  const hit = (j?.data ?? []).find((d) => d.name === DATASET_NAME);
  return hit?.id ?? null;
}

async function retrieve(key, id, question, signal) {
  const res = await fetch(`${BASE}/api/v1/retrieval`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      question,
      dataset_ids: [id],
      page_size: TOP,
      similarity_threshold: MIN_SIM,
      vector_similarity_weight: 0.3,
    }),
    signal,
  });
  const j = await res.json();
  return j?.data?.chunks ?? [];
}

/** Trim a retrieved chunk down to its most informative lines. */
function condense(text) {
  let t = (text ?? '').replace(/\r/g, '');
  // Drop the front-matter noise the store adds; the model does not need it.
  t = t.replace(/^---[\s\S]*?\n---\n?/, '');
  t = t.replace(/\n{3,}/g, '\n\n').trim();
  if (t.length > MAX_CHARS_PER_HIT) t = t.slice(0, MAX_CHARS_PER_HIT) + ' …';
  return t;
}

function render(chunks) {
  if (!chunks.length) return null;
  // A very short chunk is semantically generic, so its embedding scores high
  // against almost any query while carrying no information ("greeting, no real
  // task"). Measured: such a chunk scored 0.92 for a phone-transfer question
  // while the genuinely relevant memory scored 0.40. Require real substance.
  const MIN_CHUNK_CHARS = 120;
  const seen = new Set();
  const blocks = [];
  for (const c of chunks) {
    const body = condense(c.content);
    if (!body || body.length < MIN_CHUNK_CHARS) continue;
    const fingerprint = body.slice(0, 80);
    if (seen.has(fingerprint)) continue;
    seen.add(fingerprint);
    const date = /date:\s*([\d-]+)/.exec(c.content ?? '')?.[1] ?? '';
    const proj = /project:\s*"?([^"\n]+)"?/.exec(c.content ?? '')?.[1] ?? '';
    const head = [date, proj ? path.basename(proj) : ''].filter(Boolean).join(' · ');
    blocks.push(`- ${head ? `[${head}] ` : ''}${body}`);
  }
  if (!blocks.length) return null;
  return [
    'Relevant memories from earlier sessions on this machine (retrieved automatically;',
    'treat as background context, verify against the current code before relying on it):',
    ...blocks,
  ].join('\n');
}

async function main() {
  const argv = process.argv.slice(2);
  const arg = (k, def = null) => {
    const i = argv.indexOf(k);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def;
  };

  let payload = null;
  let query = arg('--query');

  // Hook mode: read stdin (it may be empty when run manually).
  if (!query && !process.stdin.isTTY) {
    const raw = await new Promise((resolve) => {
      let buf = '';
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', (d) => (buf += d));
      process.stdin.on('end', () => resolve(buf));
      process.stdin.on('error', () => resolve(buf));
      setTimeout(() => resolve(buf), 3000);
    }).catch(() => '');
    if (raw && raw.trim()) {
      try {
        payload = JSON.parse(raw);
        query = payload.prompt ?? payload.user_prompt ?? payload.message ?? '';
      } catch {
        // Not JSON: tolerate a raw prompt string.
        query = raw.trim();
      }
    }
  }

  if (!query || !query.trim()) return; // nothing to search -> silent no-op

  // Very short prompts ("ok", "continue") have no retrievable intent.
  if (query.trim().length < 6) return;

  const key = apiKey();
  if (!key) return;

  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS);
  let chunks = [];
  try {
    const id = await datasetId(key, ctl.signal);
    if (id) chunks = await retrieve(key, id, query, ctl.signal);
  } catch {
    return; // never break a turn because memory lookup failed
  } finally {
    clearTimeout(timer);
  }

  const context = render(chunks);
  if (!context) return;

  if (payload) {
    // Hook mode: emit the contract the bridge understands.
    process.stdout.write(JSON.stringify({ additionalContext: context }));
  } else {
    process.stdout.write(context + '\n');
  }
}

main().catch(() => {
  // Swallow everything: a failing memory hook must never block the agent.
  process.exit(0);
});
