#!/usr/bin/env node
/**
 * run.mjs — orchestrator for the DSH memory pipeline
 *
 *   capture (DSH sessions) -> distill (DeepSeek) -> store (RAGFlow)
 *
 * Design notes:
 *  - One notes directory per run keeps the temp output inspectable and lets
 *    `--dry-run` / `--limit` be meaningful.
 *  - `--skip <sessionId>` avoids re-distilling the session that is currently
 *    running (its own file is being appended to while we read it).
 *  - Distillation is the only paid step, so it can be skipped entirely with
 *    `--store-only` when notes already exist.
 *
 * Usage:
 *   node run.mjs --all --limit 3 --dry-run
 *   node run.mjs --all --skip session-61faa498-b01e-4ef1-86f9-0e21f981e87b
 *   node run.mjs --store-only --dir <notes-dir>
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const HERE = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));

const argv = process.argv.slice(2);
const arg = (k, def = null) => {
  const i = argv.indexOf(k);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : def;
};
const has = (k) => argv.includes(k);

const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const notesDir = arg('--dir') ?? path.join(HERE, 'notes', stamp);
const skip = arg('--skip');
const limit = arg('--limit');
const dryRun = has('--dry-run');
const storeOnly = has('--store-only');
const probe = arg('--probe', '这个项目里做过什么决定，为什么');

function run(script, args) {
  const r = spawnSync(process.execPath, [path.join(HERE, script), ...args], {
    stdio: 'inherit',
    cwd: HERE,
  });
  return r.status ?? 1;
}

console.log('='.repeat(64));
console.log('  DSH MEMORY PIPELINE');
console.log('='.repeat(64));
console.log(`notes dir : ${notesDir}`);
console.log(`dry-run   : ${dryRun}`);
console.log(`store-only: ${storeOnly}`);
console.log('');

if (!storeOnly) {
  // ---- 1. capture + 2. distill (distiller includes the capturer)
  const args = ['--all', '--out-dir', notesDir];
  if (limit) args.push('--limit', String(limit));
  if (dryRun) args.push('--dry-run');
  if (has('--force')) args.push('--force');
  // NOTE: the live session is still being appended to while we read it, so its
  // last turns can be truncated. --skip keeps it out of this run.
  if (skip) args.push('--skip', skip);

  console.log(`[1/3] capture + distill -> ${notesDir}`);
  if (skip) console.log(`      skipping live session: ${skip}`);
  const code = run('distiller.mjs', args);
  if (code !== 0) {
    console.log(`\ndistiller exited ${code}; continuing to store step anyway.`);
  }
  console.log('');
} else {
  console.log('[1/3] capture + distill : SKIPPED (--store-only)\n');
}

// ---- 3. store
console.log('[3/3] store -> RAGFlow');
const storeArgs = ['--dir', notesDir, '--probe', probe];
const storeCode = run('store.mjs', storeArgs);

console.log('');
console.log('='.repeat(64));
console.log(`pipeline finished (store exit=${storeCode})`);
console.log(`notes kept at: ${notesDir}`);
console.log('='.repeat(64));
