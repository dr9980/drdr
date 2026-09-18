#!/usr/bin/env node
/**
 * DSH local-AI bridge (MCP, stdio).
 *
 * Exposes two local capabilities to DeepSeek Harness as MCP tools:
 *   - Ollama: list local models, chat with one, compute embeddings.
 *   - RAGFlow: list knowledge bases, list their documents, retrieve chunks.
 *
 * Endpoints come from ./config.json, overridable by the OLLAMA_BASE_URL /
 * RAGFLOW_BASE_URL environment variables. The RAGFlow key is read from the
 * RAGFLOW_API_KEY environment variable, the harness-home .env layer, or
 * config.json, in that order.
 *
 * @module dsh-local-ai-bridge
 */
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

/** An empty or blank value means "not configured", never a present-but-blank secret. */
const orAbsent = (value) => (typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined);

/**
 * Read one value out of the harness-home `.env` layer.
 *
 * The dsh launcher materializes `$DSH_HOME/.env` into its own `process.env`, but
 * the MCP client deliberately scrubs credential-shaped names (KEY/TOKEN/SECRET/
 * PASSWORD) and every `DSH_*` name off the parent environment before spawning a
 * stdio server, so those values never reach this process. Reading the file here
 * is the bridge's own fallback, and it is what lets the RAGFlow key live outside
 * every workspace instead of in a file the agent's own working directory exposes.
 *
 * @param name - the variable to look up.
 * @returns the value, or undefined when the file, the name, or the value is absent.
 */
function readDshEnv(name) {
  const home = orAbsent(process.env.DSH_HOME) ?? join(homedir(), '.dsh');
  let content;
  try {
    content = readFileSync(join(home, '.env'), 'utf8');
  } catch {
    return undefined;
  }
  for (const line of content.split(/\r?\n/)) {
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (match === null || match[1] !== name) continue;
    return orAbsent(match[2].replace(/^(['"])(.*)\1$/, '$2'));
  }
  return undefined;
}

function loadConfig() {
  let file = {};
  try {
    file = JSON.parse(readFileSync(join(HERE, 'config.json'), 'utf8'));
  } catch {
    /* a missing or malformed config falls back to the defaults below */
  }
  return {
    ollama: {
      baseUrl: (process.env.OLLAMA_BASE_URL ?? file.ollama?.baseUrl ?? 'http://127.0.0.1:11434').replace(/\/+$/, ''),
      chatModel: process.env.OLLAMA_CHAT_MODEL ?? file.ollama?.chatModel ?? 'deepseek-r1:8b',
      embedModel: process.env.OLLAMA_EMBED_MODEL ?? file.ollama?.embedModel ?? 'qwen3-embedding:8b',
    },
    ragflow: {
      baseUrl: (process.env.RAGFLOW_BASE_URL ?? file.ragflow?.baseUrl ?? 'http://127.0.0.1:19380').replace(/\/+$/, ''),
      // Resolution order: this process's environment, then the harness-home
      // `.env` layer, then config.json. The key is expected to live in `.env` —
      // outside every workspace — while config.json stays a supported override.
      apiKey: orAbsent(process.env.RAGFLOW_API_KEY) ?? readDshEnv('RAGFLOW_API_KEY') ?? orAbsent(file.ragflow?.apiKey) ?? '',
    },
  };
}

/** Re-read config.json on every call so a rotated key or endpoint needs no restart. */
let config = loadConfig();

/** Signals a caller-facing failure; the message becomes the tool's error text. */
class ToolError extends Error {}

async function fetchJson(url, init = {}, timeoutMs = 120000) {
  const response = await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
  const text = await response.text();
  let body;
  try {
    body = text === '' ? undefined : JSON.parse(text);
  } catch {
    throw new ToolError(`${url} returned non-JSON (HTTP ${response.status}): ${text.slice(0, 300)}`);
  }
  if (!response.ok) {
    const detail = body?.message ?? body?.error ?? text.slice(0, 300);
    throw new ToolError(`${url} failed with HTTP ${response.status}: ${detail}`);
  }
  return body;
}

/** RAGFlow wraps every REST answer in `{ code, data, message }`. */
async function ragflow(path, { method = 'GET', body, timeoutMs } = {}) {
  if (config.ragflow.apiKey === '') {
    throw new ToolError(
      'No RAGFlow API key is configured. Put RAGFLOW_API_KEY in the harness-home .env layer ' +
        '($DSH_HOME/.env, i.e. ~/.dsh/.env) — or export it, or set ragflow.apiKey in config.json — ' +
        'to a key created in RAGFlow under Settings → API. RAGFlow is reachable, but every dataset call needs a key.',
    );
  }
  const result = await fetchJson(
    `${config.ragflow.baseUrl}/api/v1${path}`,
    {
      method,
      headers: { Authorization: `Bearer ${config.ragflow.apiKey}`, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    },
    timeoutMs ?? 120000,
  );
  if (result?.code !== 0) throw new ToolError(`RAGFlow ${path} returned code ${result?.code}: ${result?.message ?? 'unknown error'}`);
  return result.data;
}

const text = (value) => ({ content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }] });
/** Like {@link text} but without pretty-printing: a bulk result pays no indentation tokens. */
const compact = (value) => ({ content: [{ type: 'text', text: JSON.stringify(value) }] });

const TOOLS = [
  {
    name: 'ollama_list_models',
    description: 'List the models installed in the local Ollama runtime, with parameter size and capabilities.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    handler: async () => {
      const body = await fetchJson(`${config.ollama.baseUrl}/api/tags`, {}, 15000);
      const models = (body?.models ?? []).map((m) => ({
        name: m.name,
        parameterSize: m.details?.parameter_size,
        quantization: m.details?.quantization_level,
        contextLength: m.details?.context_length,
        capabilities: m.capabilities,
      }));
      return text(models);
    },
  },
  {
    name: 'ollama_chat',
    description:
      'Run one non-streaming completion on a local Ollama model. Use it for local-only reasoning, a second opinion, ' +
      'or summarising text without sending it to a remote provider. Returns the answer; the raw reasoning trace is ' +
      'withheld unless include_thinking is set, because it is usually most of the response length.',
    inputSchema: {
      type: 'object',
      properties: {
        model: { type: 'string', description: `Ollama model name; defaults to ${config.ollama.chatModel}.` },
        prompt: { type: 'string', description: 'Single user message. Ignored when messages is given.' },
        messages: {
          type: 'array',
          description: 'Full conversation, each { role: "system"|"user"|"assistant", content: string }.',
          items: {
            type: 'object',
            properties: { role: { type: 'string' }, content: { type: 'string' } },
            required: ['role', 'content'],
          },
        },
        system: { type: 'string', description: 'System prompt, prepended when messages is not given.' },
        temperature: { type: 'number', description: 'Sampling temperature.' },
        max_tokens: { type: 'integer', description: 'Cap on generated tokens (num_predict).' },
        include_thinking: {
          type: 'boolean',
          description:
            "Return the model's raw reasoning trace. Off by default: for reasoning models it is usually most of the " +
            'output, and every character of it becomes conversation context for the calling model.',
        },
      },
      additionalProperties: false,
    },
    handler: async (args) => {
      const messages = args.messages ?? [
        ...(args.system ? [{ role: 'system', content: args.system }] : []),
        { role: 'user', content: args.prompt ?? '' },
      ];
      if (messages.length === 0 || (messages.length === 1 && messages[0].content === '')) {
        throw new ToolError('ollama_chat needs a prompt or messages.');
      }
      const options = {};
      if (args.temperature !== undefined) options.temperature = args.temperature;
      if (args.max_tokens !== undefined) options.num_predict = args.max_tokens;
      const body = await fetchJson(
        `${config.ollama.baseUrl}/api/chat`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ model: args.model ?? config.ollama.chatModel, messages, stream: false, options }),
        },
        600000,
      );
      const thinking = body?.message?.thinking;
      const evalCount = body?.eval_count ?? 0;
      const output = {
        model: body?.model,
        content: body?.message?.content ?? '',
        usage: { promptTokens: body?.prompt_eval_count, completionTokens: body?.eval_count },
      };
      // A reasoning model can spend the whole max_tokens budget on its thinking
      // trace and emit no answer at all. Say so explicitly: without this, an
      // empty `content` reads as a broken call rather than a truncated one.
      if (output.content.trim() === '') {
        output.note =
          body?.done_reason === 'length'
            ? `content is empty because the ${evalCount}-token cap was reached${thinking ? ' before the model finished thinking' : ''}; raise max_tokens to get an answer.`
            : 'content is empty: the model returned no text.';
      }
      if (thinking) {
        if (args.include_thinking === true) output.thinking = thinking;
        else output.thinkingWithheld = `${thinking.length} chars — pass include_thinking: true to read it`;
      }
      return text(output);
    },
  },
  {
    name: 'ollama_embed',
    description: `Compute embeddings with a local Ollama embedding model (default ${config.ollama.embedModel}). Use it for local semantic search or clustering without a remote embedding API.`,
    inputSchema: {
      type: 'object',
      properties: {
        input: { type: 'array', items: { type: 'string' }, description: 'Texts to embed.' },
        model: { type: 'string', description: 'Ollama embedding model name.' },
        include_vectors: { type: 'boolean', description: 'Return the raw vectors; default false returns only their shape.' },
      },
      required: ['input'],
      additionalProperties: false,
    },
    handler: async (args) => {
      if (!Array.isArray(args.input) || args.input.length === 0) throw new ToolError('ollama_embed needs a non-empty input array.');
      const body = await fetchJson(
        `${config.ollama.baseUrl}/api/embed`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ model: args.model ?? config.ollama.embedModel, input: args.input }),
        },
        300000,
      );
      const vectors = body?.embeddings ?? [];
      return text({
        model: body?.model,
        count: vectors.length,
        dimensions: vectors[0]?.length ?? 0,
        ...(args.include_vectors === true ? { vectors } : {}),
      });
    },
  },
  {
    name: 'ragflow_list_datasets',
    description: 'List the knowledge bases in the local RAGFlow instance, with their id, document count and chunk method.',
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Optional name filter.' },
        page_size: { type: 'integer', description: 'Maximum datasets to return; default 30.' },
      },
      additionalProperties: false,
    },
    handler: async (args) => {
      // The API's own `name` filter answers a no-match with a misleading
      // "lacks permission" error, so filter locally instead.
      const params = new URLSearchParams({ page: '1', page_size: String(args.page_size ?? 30) });
      const data = await ragflow(`/datasets?${params.toString()}`);
      const wanted = args.name?.toLowerCase();
      const rows = (data ?? []).filter((d) => wanted === undefined || String(d.name).toLowerCase().includes(wanted));
      return text(
        rows.map((d) => ({
          id: d.id,
          name: d.name,
          documentCount: d.document_count,
          chunkCount: d.chunk_count,
          chunkMethod: d.chunk_method,
          embeddingModel: d.embedding_model,
        })),
      );
    },
  },
  {
    name: 'ragflow_list_documents',
    description: 'List the documents inside one RAGFlow knowledge base.',
    inputSchema: {
      type: 'object',
      properties: {
        dataset_id: { type: 'string', description: 'Knowledge base id from ragflow_list_datasets.' },
        keywords: { type: 'string', description: 'Optional document-name filter.' },
        page_size: { type: 'integer', description: 'Maximum documents to return; default 50.' },
      },
      required: ['dataset_id'],
      additionalProperties: false,
    },
    handler: async (args) => {
      const params = new URLSearchParams({ page: '1', page_size: String(args.page_size ?? 50) });
      if (args.keywords) params.set('keywords', args.keywords);
      const data = await ragflow(`/datasets/${encodeURIComponent(args.dataset_id)}/documents?${params.toString()}`);
      return text(
        (data?.docs ?? []).map((d) => ({
          id: d.id,
          name: d.name,
          size: d.size,
          chunks: d.chunk_count,
          run: d.run,
          status: d.status,
          progress: d.progress,
        })),
      );
    },
  },
  {
    name: 'ragflow_retrieve',
    description:
      'Search the local RAGFlow knowledge bases and return the most relevant chunks. This reads the user\'s own document ' +
      'collection, so prefer it over guessing when a question touches their private material. Duplicate passages are ' +
      'collapsed and per-chunk diagnostic fields are omitted unless verbose is set; neither changes the retrieved text.',
    inputSchema: {
      type: 'object',
      properties: {
        question: { type: 'string', description: 'Natural-language query.' },
        dataset_ids: { type: 'array', items: { type: 'string' }, description: 'Knowledge bases to search; omit to search all of them.' },
        top_k: {
          type: 'integer',
          description:
            'Chunks to return; default 8. This is the real cost lever, but lowering it can drop a passage a broad ' +
            'question needed, so prefer narrowing the question over cutting this.',
        },
        similarity_threshold: { type: 'number', description: 'Minimum similarity, 0-1; default 0.2.' },
        vector_similarity_weight: { type: 'number', description: 'Weight of vector vs term similarity, 0-1; default 0.3.' },
        verbose: {
          type: 'boolean',
          description:
            'Also return per-chunk dataset/document ids and the vector-only score. Off by default: they cost context ' +
            'and rarely change the answer.',
        },
        max_chars_per_chunk: {
          type: 'integer',
          description:
            'Truncate each chunk to this many characters. Off by default: truncation can cut the very sentence that ' +
            'answers the question.',
        },
      },
      required: ['question'],
      additionalProperties: false,
    },
    handler: async (args) => {
      let datasetIds = args.dataset_ids;
      if (datasetIds === undefined) {
        const all = await ragflow('/datasets?page=1&page_size=100');
        datasetIds = (all ?? []).map((d) => d.id);
        if (datasetIds.length === 0) {
          throw new ToolError('This RAGFlow instance has no knowledge base yet, so there is nothing to retrieve from.');
        }
      }
      const data = await ragflow('/retrieval', {
        method: 'POST',
        body: {
          question: args.question,
          dataset_ids: datasetIds,
          page: 1,
          page_size: args.top_k ?? 8,
          similarity_threshold: args.similarity_threshold ?? 0.2,
          vector_similarity_weight: args.vector_similarity_weight ?? 0.3,
        },
      });
      const raw = data?.chunks ?? [];

      // Chunk overlap lets RAGFlow return the same passage more than once, and
      // identical text tells the caller nothing extra — keep its best-scoring copy.
      const byText = new Map();
      for (const chunk of raw) {
        const key = String(chunk.content ?? '').replace(/\s+/g, ' ').trim();
        const prior = byText.get(key);
        if (prior === undefined || (chunk.similarity ?? 0) > (prior.similarity ?? 0)) byText.set(key, chunk);
      }
      const chunks = [...byText.values()];
      const datasets = [...new Set(chunks.map((c) => c.dataset_id))];
      // One dataset searched means one id for the whole answer; several need per-chunk attribution.
      const perChunkDataset = datasets.length > 1;
      const cap = args.max_chars_per_chunk;

      const shaped = chunks.map((chunk) => {
        const content = String(chunk.content ?? '');
        const row = {
          content: cap !== undefined && content.length > cap ? `${content.slice(0, cap)}… [truncated]` : content,
          similarity: Number((chunk.similarity ?? 0).toFixed(3)),
          document: chunk.document_keyword,
        };
        if (perChunkDataset) row.datasetId = chunk.dataset_id;
        if (args.verbose === true) {
          row.vectorSimilarity = chunk.vector_similarity;
          row.documentId = chunk.document_id;
        }
        return row;
      });

      return compact({
        total: data?.total,
        returned: shaped.length,
        ...(perChunkDataset ? {} : { datasetId: datasets[0] }),
        chunks: shaped,
      });
    },
  },
];

const server = new Server(
  { name: 'dsh-local-ai-bridge', version: '1.0.0' },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  config = loadConfig();
  const tool = TOOLS.find((t) => t.name === request.params.name);
  if (tool === undefined) {
    return { content: [{ type: 'text', text: `Unknown tool: ${request.params.name}` }], isError: true };
  }
  try {
    return await tool.handler(request.params.arguments ?? {});
  } catch (error) {
    const detail = error instanceof ToolError ? error.message : `unexpected failure: ${error?.message ?? String(error)}`;
    return { content: [{ type: 'text', text: detail }], isError: true };
  }
});

await server.connect(new StdioServerTransport());
