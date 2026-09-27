#!/usr/bin/env node
/**
 * rebuild.mjs — wipe the memory dataset and rebuild it with the current filters.
 *
 * Needed after the distiller's contentless-turn filter changed: documents that
 * were already stored keep their old content (the naming scheme is an
 * idempotency key, not an update trigger), so a rebuild is the honest way to
 * apply a filtering change.
 *
 * Steps: delete every document in the dataset -> re-distill -> re-store -> probe.
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';

const HERE = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const DSH_HOME = process.env.DSH_HOME ?? path.join(os.homedir(), '.dsh');
const BASE = process.env.RAGFLOW_BASE_URL ?? 'http://127.0.0.1:19380';
const NAME = process.env.MEMORY_DATASET ?? 'dsh-memory';

function key() {
  if (process.env.RAGFLOW_API_KEY) return process.env.RAGFLOW_API_KEY;
  const f = path.join(DSH_HOME, '.env');
  for (const l of fs.readFileSync(f, 'utf8').split(/\r?\n/)) {
    const m = /^\s*RAGFLOW_API_KEY\s*=\s*(.+?)\s*$/.exec(l);
    if (m) return m[1];
  }
  throw new Error('RAGFLOW_API_KEY not found');
}

const H = { Authorization: `Bearer ${key()}`, 'Content-Type': 'application/json' };

async function api(method, ep, body) {
  const res = await fetch(`${BASE}${ep}`, {
    method,
    headers: H,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const j = await res.json();
  if (j.code !== 0) throw new Error(`${ep} -> code=${j.code} ${j.message ?? ''}`);
  return j.data;
}

const ds = (await api('GET', `/api/v1/datasets?name=${encodeURIComponent(NAME)}`)).find((d) => d.name === NAME);
if (!ds) throw new Error(`dataset ${NAME} not found`);
console.log(`dataset : ${ds.id}  docs=${ds.document_count}  chunks=${ds.chunk_count}`);

// ---- 1. delete all documents
const all = [];
for (let page = 1; ; page++) {
  const r = await api('GET', `/api/v1/datasets/${ds.id}/documents?page=${page}&page_size=100`);
  const docs = r.docs ?? r ?? [];
  all.push(...docs);
  if (docs.length < 100) break;
}
console.log(`deleting ${all.length} document(s)...`);
if (all.length) {
  await api('DELETE', `/api/v1/datasets/${ds.id}/documents`, { ids: all.map((d) => d.id) });
}
const after = await api('GET', `/api/v1/datasets/${ds.id}/documents?page=1&page_size=100`);
console.log(`after wipe: docs=${(after.docs ?? after ?? []).length}\n`);

// ---- 2. re-distill into a fresh notes dir
const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const notesDir = path.join(HERE, 'notes', `rebuild-${stamp}`);
console.log(`re-distilling into ${notesDir}`);
const skip = process.argv[2] ?? '';
const args = ['--all', '--out-dir', notesDir, '--force'];
if (skip) args.push('--skip', skip);
const d = spawnSync(process.execPath, [path.join(HERE, 'distiller.mjs'), ...args], { stdio: 'inherit', cwd: HERE });
console.log(`distiller exit=${d.status}\n`);

// ---- 3. re-store
const s = spawnSync(
  process.execPath,
  [path.join(HERE, 'store.mjs'), '--dir', notesDir, '--probe', 'dsh 插件安装失败怎么修的'],
  { stdio: 'inherit', cwd: HERE },
);
console.log(`\nstore exit=${s.status}`);
console.log(`notes: ${notesDir}`);
