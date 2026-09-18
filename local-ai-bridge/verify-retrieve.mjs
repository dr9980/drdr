#!/usr/bin/env node
/**
 * Compare the live ragflow_retrieve output against the shape it used to emit,
 * for one fixed query, and check the new default/verbose/capped paths.
 */
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const config = JSON.parse(readFileSync(join(HERE, 'config.json'), 'utf8'));
const BASE = config.ragflow.baseUrl.replace(/\/+$/, '');
const KEY = config.ragflow.apiKey;

const client = new Client({ name: 'verify-retrieve', version: '1.0.0' });
await client.connect(new StdioClientTransport({ command: process.execPath, args: [join(HERE, 'server.mjs')], cwd: HERE }));
const call = (name, args) => client.callTool({ name, arguments: args }, undefined, { timeout: 600000 });
const QUESTION = 'How does the local integration work, and which ports and models does it use?';

const datasets = JSON.parse((await call('ragflow_list_datasets', {})).content[0].text);
const datasetId = datasets[0].id;

const rawResponse = await fetch(`${BASE}/api/v1/retrieval`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({
    question: QUESTION,
    dataset_ids: [datasetId],
    page: 1,
    page_size: 8,
    similarity_threshold: 0.2,
    vector_similarity_weight: 0.3,
  }),
});
const raw = (await rawResponse.json()).data.chunks ?? [];
const oldFormat = JSON.stringify(
  {
    total: raw.length,
    chunks: raw.map((c) => ({
      content: c.content,
      similarity: c.similarity,
      vectorSimilarity: c.vector_similarity,
      document: c.document_keyword,
      datasetId: c.dataset_id,
      documentId: c.document_id,
    })),
  },
  null,
  2,
);

const plainText = (await call('ragflow_retrieve', { question: QUESTION })).content[0].text;
const verboseText = (await call('ragflow_retrieve', { question: QUESTION, verbose: true })).content[0].text;
const cappedText = (await call('ragflow_retrieve', { question: QUESTION, max_chars_per_chunk: 120 })).content[0].text;

const plain = JSON.parse(plainText);
const capped = JSON.parse(cappedText);
const savedPct = (100 * (1 - plainText.length / oldFormat.length)).toFixed(1);

console.log(`chunks fetched          : ${raw.length}`);
console.log(`old format              : ${oldFormat.length} chars`);
console.log(`new default             : ${plainText.length} chars   (saving ${savedPct}%)`);
console.log(`new verbose             : ${verboseText.length} chars`);
console.log(`new max_chars_per_chunk : ${cappedText.length} chars`);
console.log(`hoisted single datasetId: ${typeof plain.datasetId === 'string'}`);
console.log(`chunk keys (default)    : ${Object.keys(plain.chunks[0]).join(', ')}`);
console.log(`chunk keys (verbose)    : ${Object.keys(JSON.parse(verboseText).chunks[0]).join(', ')}`);
console.log(`truncation applied      : ${capped.chunks.every((c) => c.content.includes('[truncated]'))}`);
console.log(`content unchanged       : ${plain.chunks[0].content === raw.find((c) => c.document_keyword === plain.chunks[0].document)?.content}`);

await client.close();
