import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const client = new Client({ name: 'bridge-smoke-test', version: '1.0.0' });
await client.connect(new StdioClientTransport({ command: process.execPath, args: [join(HERE, 'server.mjs')], cwd: HERE }));

// Local 8B models can be slow; DSH's own mcp-client row uses the same 10-minute cap.
const call = (name, args) => client.callTool({ name, arguments: args }, undefined, { timeout: 600000 });

const show = (label, result) => {
  const body = result.content?.[0]?.text ?? '';
  console.log(`\n### ${label}${result.isError ? ' [isError]' : ''}\n${body.slice(0, 600)}`);
};

const tools = await client.listTools();
console.log('tools:', tools.tools.map((t) => t.name).join(', '));

show('ollama_list_models', await call('ollama_list_models', {}));
// 600, not 200: the default chat model is a reasoning model, and a ~200-token
// cap is spent entirely on the thinking trace, leaving `content` empty.
show('ollama_chat', await call('ollama_chat', { prompt: 'Reply with exactly: OK', max_tokens: 600 }));
show('ollama_embed', await call('ollama_embed', { input: ['hello world'] }));

show('ragflow_list_datasets', await call('ragflow_list_datasets', {}));
const datasets = await call('ragflow_list_datasets', {});
const first = JSON.parse(datasets.content[0].text)[0];
if (first) {
  show('ragflow_list_documents', await call('ragflow_list_documents', { dataset_id: first.id }));
  show('ragflow_retrieve', await call('ragflow_retrieve', { question: 'What is the reference codename?' }));
}

await client.close();
