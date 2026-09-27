#!/usr/bin/env node
/**
 * capturer.mjs — DSH session -> normalized conversation
 *
 * Part 1 of the DSH memory pipeline (RAGFlow-backed).
 *
 * WHY THE DECOMPRESSION IS NON-TRIVIAL
 *   A DSH session file is a CONCATENATION of many independent zstd frames
 *   (one appended per turn — 682 frames in one 1.4 MB file was observed).
 *   zlib.zstdDecompressSync() and createZstdDecompress() both stop after the
 *   FIRST frame, yielding only the 200-byte session header. Frames must be
 *   located by magic (28 B5 2F FD) and inflated one by one.
 *
 * SESSION SCHEMA (v3, verified against real files)
 *   line 1 : {"type":"session","version":3,"id","createdAt","cwd","agentPreset"}
 *   rest   : {"type":"<event>","seq":N,"time":msEpoch,"data":{...}}
 *   events : user/message, assistant/message, tool/call, tool/result,
 *            deliverables/presented, turn/start, turn/end, todo/write, ...
 *
 * NOISE FILTERING
 *   user/message carries source.kind: "user" (a real human turn) vs "plugin"
 *   /"system" (injected runtime context snapshots). Only human turns count as
 *   questions; injected context is recorded nowhere, or memory fills with
 *   boilerplate.
 *
 * Usage:
 *   node capturer.mjs --list
 *   node capturer.mjs --session <id-or-path> [--json out.json]
 *   node capturer.mjs --all [--out-dir DIR]
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import zlib from 'node:zlib';

const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const SESSIONS_ROOT = path.join(os.homedir(), '.dsh', 'sessions');

// ---------------------------------------------------------------- primitives

/** Inflate a whole multi-frame DSH session file. */
export function inflateSession(file) {
  const buf = fs.readFileSync(file);
  const starts = [];
  for (let i = 0; i + 3 < buf.length; i++) {
    if (buf[i] === 0x28 && buf[i + 1] === 0xb5 && buf[i + 2] === 0x2f && buf[i + 3] === 0xfd) {
      starts.push(i);
    }
  }
  if (starts.length === 0) throw new Error('no zstd frame found (not a DSH session file?)');

  const parts = [];
  let failed = 0;
  for (let k = 0; k < starts.length; k++) {
    const end = k + 1 < starts.length ? starts[k + 1] : buf.length;
    try {
      parts.push(zlib.zstdDecompressSync(buf.subarray(starts[k], end)));
    } catch {
      failed++;
    }
  }
  return { text: Buffer.concat(parts).toString('utf8'), frames: starts.length, failed };
}

/** Parse inflated text into session meta + event envelopes. */
export function parseSession(text) {
  const lines = text.split('\n').filter((l) => l.trim() !== '');
  let meta = null;
  const events = [];
  let bad = 0;
  for (const line of lines) {
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      bad++;
      continue;
    }
    if (o.type === 'session' && !meta) {
      meta = o;
    } else if (o.type) {
      events.push(o);
    }
  }
  return { meta, events, badLines: bad };
}

/** Concatenate the text parts of a DSH content array. */
function textOf(content) {
  if (!Array.isArray(content)) return '';
  const out = [];
  for (const c of content) {
    if (typeof c === 'string') out.push(c);
    else if (c && typeof c.text === 'string' && (c.type === 'text' || c.type === undefined)) out.push(c.text);
  }
  return out.join('\n').trim();
}

/** Collect reasoning parts (kept separate from the answer). */
function reasoningOf(message) {
  if (!message || !Array.isArray(message.content)) return '';
  const out = [];
  for (const c of message.content) {
    if (c && c.type === 'reasoning' && typeof c.text === 'string') out.push(c.text);
  }
  return out.join('\n').trim();
}

/** True when a user/message is an actual human turn rather than injected context. */
function isHumanTurn(ev) {
  const kind = ev?.data?.source?.kind;
  if (kind === 'user') return true;
  // Some builds omit source on genuine turns; fall back to "no plugin marker".
  if (kind === undefined && ev?.data?.source?.plugin === undefined) return true;
  return false;
}

/** Strip the large runtime-context snapshot that DSH prepends to prompts. */
function stripRuntimeContext(s) {
  const marker = 'Current runtime context.';
  const idx = s.indexOf(marker);
  return idx > 0 ? s.slice(0, idx).trim() : s;
}

// ------------------------------------------------------------------ mapping

/**
 * Normalize one session into a memory-friendly conversation object.
 * @returns {{
 *   sessionId: string, cwd: string, agentPreset: string,
 *   createdAt: number, events: number, turns: Array<object>
 * }}
 */
export function normalize(file) {
  const { text, frames, failed } = inflateSession(file);
  const { meta, events, badLines } = parseSession(text);
  if (!meta) throw new Error('session header not found');

  const turns = [];
  let cur = null;

  const ensure = (n) => {
    if (!cur || cur.turn !== n) {
      cur = { turn: n, startedAt: null, endedAt: null, endReason: null, prompts: [], steps: [], tools: [], delivered: [] };
      turns.push(cur);
    }
    return cur;
  };

  for (const ev of events) {
    const d = ev.data ?? {};
    switch (ev.type) {
      case 'turn/start':
        cur = null; // force a fresh turn bucket
        ensure(d.turn).startedAt = ev.time;
        break;

      case 'turn/end': {
        const t = ensure(d.turn);
        t.endedAt = ev.time;
        t.endReason = d.reason?.kind ?? null;
        break;
      }

      case 'user/message': {
        if (!isHumanTurn(ev)) break;
        const txt = stripRuntimeContext(textOf(d.content));
        if (txt) ensure(d.turn ?? turns.length).prompts.push({ seq: ev.seq, time: ev.time, text: txt });
        break;
      }

      case 'assistant/message': {
        const t = ensure(d.turn ?? turns.length);
        const answer = textOf(d.message?.content);
        const why = reasoningOf(d.message);
        if (answer || why) {
          t.steps.push({
            seq: ev.seq,
            time: ev.time,
            step: d.step ?? null,
            reasoning: why.length > 1500 ? why.slice(0, 1500) + '\n...[truncated]' : why,
            text: answer.length > 6000 ? answer.slice(0, 6000) + '\n...[truncated]' : answer,
          });
        }
        break;
      }

      case 'tool/call': {
        const t = ensure(d.turn ?? turns.length);
        let args = d.arguments;
        if (typeof args === 'string' && args.length > 400) args = args.slice(0, 400) + '...';
        t.tools.push({ seq: ev.seq, callId: d.callId, name: d.name, arguments: args });
        break;
      }

      case 'deliverables/presented': {
        const t = ensure(d.turn ?? turns.length);
        for (const f of d.files ?? []) {
          t.delivered.push({ path: f.path, description: f.description ?? '' });
        }
        break;
      }

      default:
        break;
    }
  }

  // Drop turns that carry no human prompt and produced nothing delivered.
  const kept = turns.filter((t) => t.prompts.length > 0 || t.delivered.length > 0 || t.steps.length > 0);

  return {
    sessionId: meta.id,
    cwd: meta.cwd,
    agentPreset: meta.agentPreset ?? null,
    createdAt: meta.createdAt,
    file,
    frames,
    failedFrames: failed,
    badLines,
    eventCount: events.length,
    turns: kept,
  };
}

// -------------------------------------------------------------------- listing

function walk(dir, out = []) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.jsonl.zstd')) out.push(p);
  }
  return out;
}

export function listSessions() {
  return walk(SESSIONS_ROOT)
    .map((f) => ({ file: f, sessionId: path.basename(path.dirname(f)), bytes: fs.statSync(f).size }))
    .sort((a, b) => b.bytes - a.bytes);
}

// ----------------------------------------------------------------------- cli

function main() {
  const argv = process.argv.slice(2);
  const arg = (k, def = null) => {
    const i = argv.indexOf(k);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def;
  };
  const has = (k) => argv.includes(k);

  if (has('--list') || argv.length === 0) {
    const all = listSessions();
    console.log(`DSH sessions under ${SESSIONS_ROOT}: ${all.length}`);
    for (const s of all) {
      console.log(`  ${s.sessionId}  ${(s.bytes / 1024).toFixed(1)} KB`);
    }
    return;
  }

  const outDir = arg('--out-dir');

  if (has('--all')) {
    const all = listSessions();
    const dir = outDir ?? path.join(process.cwd(), 'memory-out');
    fs.mkdirSync(dir, { recursive: true });
    let ok = 0;
    for (const s of all) {
      try {
        const n = normalize(s.file);
        const dest = path.join(dir, `${n.sessionId}.json`);
        fs.writeFileSync(dest, JSON.stringify(n, null, 2), 'utf8');
        console.log(`  ${n.sessionId}  turns=${n.turns.length}  -> ${path.basename(dest)}`);
        ok++;
      } catch (e) {
        console.log(`  ${s.sessionId}  FAILED: ${e.message}`);
      }
    }
    console.log(`\nnormalized ${ok}/${all.length} sessions into ${dir}`);
    return;
  }

  const target = arg('--session');
  if (!target) {
    console.error('need --session <id|path>, --all, or --list');
    process.exit(2);
  }
  const file = fs.existsSync(target) ? target : listSessions().find((s) => s.sessionId === target)?.file;
  if (!file) {
    console.error(`session not found: ${target}`);
    process.exit(3);
  }

  const n = normalize(file);
  const dest = arg('--json');
  if (dest) {
    fs.writeFileSync(dest, JSON.stringify(n, null, 2), 'utf8');
    console.log(`wrote ${dest}`);
  } else {
    console.log(JSON.stringify(n, null, 2));
  }
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('capturer.mjs')) {
  main();
}
