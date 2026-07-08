# Codex CLI + llama.cpp

在本地 llama.cpp 服务（Qwen GGUF）上运行 Codex CLI。

## 安装步骤

1. 启动 llama-server 并加载 chat 模板（端口 9999）：

   ```powershell
   cd .\llama.cpp
   .\start-llama.ps1        # 出现提示时选择 chat_template.jinja
   ```

2. 安装配置：把 `config.toml` 复制到 `~/.codex/config.toml`
   （Windows：`%USERPROFILE%\.codex\config.toml`；WSL/Linux：`/home/<用户>/.codex/config.toml`），
   然后把模型 `slug` 改成你实际加载的 GGUF alias。

3. 运行 `codex`。

> Codex **直连** llama-server（`:9999`）。与 Claude Code 不同，Codex 自带工具少且简单，
> 不会撞爆 llama.cpp 的语法生成 —— 默认不需要代理。

## 说明

- **metadata 警告**：`Model metadata for ... not found` 是因为该模型不在 Codex 内置目录里。
  设置 `model_context_window`（这里唯一有效的元数据键，保持和 llama-server 的 `-c` 一致）。
  **没有** `model_max_output_tokens` 这个键 —— Codex 会忽略它。
- **`/model` 选择器**：Codex **没有 `[[models]]` 配置** —— 这类块会被静默忽略，
  所以选择器仍显示官方列表。Codex 只会用你 `model = "..."` 指定的模型。要把本地模型
  加进选择器，用 `model_catalog_json` 指向一个 JSON 模型目录文件（见下）。
- **`wire_api = "responses"`** 是当前唯一支持的取值，而且这个 llama.cpp build 实现了
  `/v1/responses`，所以保持不变。
- **代理（仅在需要时）**：如果你挂了带重 JSON-Schema 的 MCP 服务并报 `failed to parse grammar`，
  启动代理（`.\agents\start-proxy.ps1`）并把 `base_url` 改成 `http://localhost:9998/v1`。

## 模型目录（让本地模型出现在 `/model`）

Codex 的 `/model` 选择器来自它的**模型目录（model catalog）**，而不是普通配置键。
`model_catalog_json` 允许你用自己的目录替换它。

步骤：
1. 把本目录下的 `models.json` 复制到 Codex 主目录（和 `config.toml` 同一个文件夹：
   Linux/WSL 为 `~/.codex/`，Windows 为 `%USERPROFILE%\.codex\`）。
2. `config.toml` 里已启用相对路径（相对 Codex 主目录解析）：
   ```toml
   model_catalog_json = "./models.json"
   ```
3. 重启 `codex`，你的模型就会出现在 `/model` 里。

按需修改 `models.json`，让 `slug`、上下文窗口、量化和你实际加载的 GGUF alias 一致。
已预置 `Qwen3.6-35B-A3B-Q4_K_P`、`IQ4_NL`、`IQ4_XS`、`IQ3_M`、`IQ2_M`。

权衡 / 注意事项：
- 该目录会**完全替换** Codex 内置目录 —— 只显示这里列出的模型
  （官方 GPT 模型会从 `/model` 消失）。
- 目录里必须**至少有一个**模型，否则配置加载失败。
- 字段针对 llama.cpp 后端做了保守设置（关闭 verbosity/websockets）。schema 与 Codex 版本相关
  （按 0.142.x 构造）；若将来的 Codex 拒绝它，从 Codex 内置的 `models.json` 重新派生。
- 如果你只想消掉 metadata 警告，其实**不需要**这个 —— `model_context_window` 已经搞定了。
  目录仅用于自定义 `/model` 列表。

## 状态栏（status line）

Codex **自带**状态栏，不需要脚本，也**不需要 jq**（这点和 Claude 不同）。
它由 `config.toml` 里 `[tui]` 的 `status_line` 控制——填一组内置条目 ID 即可。
为对齐 claude 的 `statusline.sh`（模型 / 上下文 / 目录），建议：

```toml
[tui]
status_line = ["model-with-reasoning", "context-remaining", "current-dir", "git-branch"]
```

常用条目 ID：`model`、`model-with-reasoning`、`context-remaining`、`current-dir`、`git-branch`。
- 不设置时默认：`["model-with-reasoning", "context-remaining", "current-dir"]`
- 设为 `status_line = []` 或 `null` 可隐藏状态栏。

> 对照：statusline.sh 里的 `model` → `model`/`model-with-reasoning`，上下文占用 % → `context-remaining`，
> 项目目录 → `current-dir`。而成本/耗时/会话 token 那些是 statusline.sh 基于 Claude 传入 JSON + `ccusage`
> 自算的，Codex 内置状态栏无对应条目、也无法用自定义脚本替换，因此无需 `jq`。

## 常见问题
- **"failed to parse grammar"**：只有在工具 schema 很重时才会出现（如来自 MCP 服务）。
  走代理（`:9998`），它会剥离撞爆 llama.cpp 语法生成的约束关键字。
- **401 / 鉴权错误**：llama.cpp 会忽略 API key，任意占位符即可。如果 Codex 坚持要 env key，
  把 `OPENAI_API_KEY` 设成任意值。
