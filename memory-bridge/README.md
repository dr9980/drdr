# DSH 记忆层（RAGFlow 后端）

把 RAGFlow 改造成**记忆插件级**的效果：自动捕获 DSH 会话 → 用 LLM 提炼成结构化记忆
→ 存入 RAGFlow 知识库 → 每次提问自动检索并注入相关记忆。

## 为什么不是 claude-mem

claude-mem 在本机不可行，两个硬障碍（均已实测确认）：

1. **provider 白名单**：只认 `claude` / `gemini` / `openrouter`。DeepSeek 命中 0 次。
   尝试把 `CLAUDE_MEM_OPENROUTER_BASE_URL` 指向 `api.deepseek.com/v1` 失败——
   该构建把 OpenRouter 路由绑在 Pro 试用状态上，实测回落 Claude SDK。
   Gemini 也走不通：AI Studio 必须绑定 GCP 项目，大陆账号建不了。
2. **读不到 DSH 会话**：官方桥接层明确 `transcript_path` 永远为空字符串，
   而 claude-mem 整套流程建立在读 transcript 之上。

本方案自己实现这两环，因此可用。

## 架构

```
~/.dsh/sessions/**/session.v3.jsonl.zstd      (zstd 多帧拼接，682 帧/文件)
        │  capturer.mjs    逐帧解压 + 解析事件信封
        ▼
标准化对话 { sessionId, cwd, turns[] }
        │  distiller.mjs    DeepSeek 提炼（每回合一次调用）
        ▼
<notes>/<project-slug>/<date>-<sessionId>.md   结构化记忆（问/做/结论/产出/要点）
        │  store.mjs       按回合切成文档，上传 RAGFlow + 触发解析
        ▼
RAGFlow dataset "dsh-memory"  (embedding: qwen3-embedding:8b@Ollama)
        │  inject.mjs      检索
        ▼
DSH hook 桥 UserPromptSubmit → additionalContext 自动注入
```

## 关键技术细节（踩过的坑）

| 坑 | 真相 |
|---|---|
| zstd 只解出 200 字节 | DSH 是**多帧拼接**存储，`zstdDecompressSync` 和 `createZstdDecompress` **都只解第一帧**。必须按魔数 `28 B5 2F FD` 定位每一帧单独解压 |
| `user/message` 里有系统注入 | `source.kind` 为 `user` 才是真人提问；`plugin` 是运行时上下文快照，必须过滤，否则记忆全是样板文字 |
| RAGFlow 建库参数 | `embedding_model` 必须是 `<model>@<provider>` 格式，如 `qwen3-embedding:8b@Ollama` |
| RAGFlow 分页 | `page_size` **上限 100**，超过报 `code=100` |
| 按 `---` 切回合会全丢 | 生成的文档以 `# H1` 开头，第一段不以 `###` 开头。必须**在 `### ` 前切分** |
| PowerShell 写文件带 BOM | `Set-Content -Encoding UTF8` 在 PS 5.1 下会写 BOM，破坏 `.mjs` 的 shebang。用 `[IO.File]::WriteAllText(..., [Text.UTF8Encoding]::new($false))` |

## 组件

| 文件 | 作用 | 验证状态 |
|---|---|---|
| `capturer.mjs` | DSH 会话 → 标准化对话 | ✅ 10/10 会话解析，0 坏帧 0 坏行 |
| `distiller.mjs` | 标准化对话 → 结构化记忆（DeepSeek） | ✅ 真实产出，含根因/决定/产出/要点 |
| `store.mjs` | 记忆 → RAGFlow（上传+解析） | ✅ 已建库，chunks 生成，检索命中 0.64 |
| `inject.mjs` | 检索 → 注入上下文 | ✅ 三种模式通过（独立/hook/短提示静默） |
| `run.mjs` | 编排全流程 | ✅ 端到端跑通 |
| `rebuild.mjs` | 清库重建（改动过滤规则后用） | ✅ 删库→重提炼→重存库→探针 |

## 一个已修复的质量缺陷（值得记录）

**现象**：查询"手机传文件掉速的原因"，返回的却是"确认中文交流并说明 token 消耗规则"
和"会话开场问候，无实质任务"，相似度 **0.92**；而真正相关的记忆只有 **0.40**，被挤出 top-k。

**根因**：**短而语义泛化的分块，其 embedding 几乎和任何问题都接近，得分反而虚高**。
"问候/无实质任务"这类回合压成一句话后只有几十字符，向量不被稀释，于是压过了内容丰富的长分块。

**尝试过但无效的**：调高 `similarity_threshold`（0.2→0.45）、加大关键词权重
（`vector_similarity_weight` 0.3→0.7）—— 因为问题不在阈值，而在**排序本身被污染**。

**实际修正（两层）**：
1. `distiller.mjs` —— **建库阶段就丢弃空洞回合**（判据：提问 <40 字符 且 既无交付物、
   工具调用 <2 次）。本次实测丢弃了 2 个空洞文档。
2. `inject.mjs` —— **注入阶段丢弃过短分块**（<120 字符），兜住历史遗留数据和未来回归。

**注意**：文档名是幂等键而非更新触发器，所以**改动过滤规则后必须用 `rebuild.mjs` 清库重建**，
否则旧文档会保留旧内容。

## 用法

```powershell
cd D:\deepseek-Harness\memory-bridge

# 全流程：捕获 → 提炼 → 存库（--skip 排除正在写入的当前会话）
node run.mjs --all --skip <当前会话ID> --probe "这个项目做过什么决定"

# 只看不写
node run.mjs --all --dry-run

# 已有笔记，只重新存库
node run.mjs --store-only --dir notes\<时间戳>

# 单独检索（测试记忆质量）
node inject.mjs --query "git 代理问题怎么修的"

# 检查知识库内容
node store.mjs --list
```

## 凭据处理

不硬编码任何密钥，按以下顺序解析：

- **RAGFlow**：`$env:RAGFLOW_API_KEY` → `$DSH_HOME/.env`
- **DeepSeek**：`$env:DEEPSEEK_API_KEY` → `$DSH_HOME/.env` → `$DSH_HOME/.credentials.yaml`

密钥**从不打印**（只输出长度或"present"）。

## 接入 DSH 钩子（第二步，尚未执行）

注入器已验证，但**尚未接入** `cordis.patch.yml`——因为 hook 作用于**每个会话的每次提问**，
一旦出错会影响所有对话。接入方式（经 `@deepseek-ai/dsh-hooks-claude-code` 桥）：

```yaml
- insert:
    - id: memory-inject
      name: '@deepseek-ai/dsh-hooks-claude-code'
      config:
        configPath: D:/deepseek-Harness/memory-bridge/hooks.json
        projectDir: D:/deepseek-Harness
```

配套 `hooks.json` 把 `UserPromptSubmit` 指向 `node D:/deepseek-Harness/memory-bridge/inject.mjs`。
`inject.mjs` 已按"失败即静默"设计（超时、异常、空结果都不输出，绝不影响对话）。

## 已知限制

- 蒸馏是唯一花钱的步骤（实测约 8.2K prompt + 1.1K completion tokens / 回合）。
- 压缩后的记忆是**有损**的：原始会话仍在 `~/.dsh/sessions`，可随时重新提炼。
- 检索质量取决于 embedding 模型；当前用本地 `qwen3-embedding:8b`，无需联网。
- `~/.claude-mem` 与 claude-mem 的 worker 仍在本机（可清理）。
