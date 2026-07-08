# Claude Code + llama.cpp

在本地 llama.cpp 服务（Qwen GGUF）上运行 Claude Code。

## 安装 / 卸载 Claude Code

Claude Code 本身是独立 CLI（与 llama.cpp 无关），下面两种方式任选其一。

> 安全提示：官方脚本会从远端下载并执行安装程序。如需自行审阅，可先
> `curl -fsSL https://claude.ai/install.sh -o install.sh` 下载后查看再运行。

### 方式 A：官方脚本（推荐，自带后台自动更新）

安装：

```bash
# macOS / Linux / WSL
curl -fsSL https://claude.ai/install.sh | bash
```

```powershell
# Windows PowerShell
irm https://claude.ai/install.ps1 | iex
# or
powershell -ExecutionPolicy ByPass -c "irm https://claude.ai/install.ps1 | iex"
```

卸载：

```bash
# macOS / Linux / WSL
rm -f ~/.local/bin/claude
rm -rf ~/.local/share/claude

# remove config dir if needed
rm -rf ~/.claude
```

```powershell
# Windows PowerShell
Remove-Item "$env:USERPROFILE\.local\bin\claude.exe" -Force
Remove-Item "$env:USERPROFILE\.local\share\claude" -Recurse -Force

# remove config dir if needed
Remove-Item "$env:USERPROFILE\.claude" -Recurse -Force
```

### 方式 B：pnpm 全局安装（需 Node.js ≥ 22）

1. 安装 pnpm（独立版，才能用 pnpm 管理 Node）：

   ```powershell
   # Windows：scoop
   scoop install pnpm
   ```

   ```bash
   # macOS：Homebrew
   brew install pnpm

   # Linux / WSL：官方独立脚本
   curl -fsSL https://get.pnpm.io/install.sh | sh -
   ```

2. 用 pnpm 安装 Node.js（LTS，≥ 22）：

   ```bash
   pnpm env use --global lts
   ```

3. 安装 / 卸载 Claude Code：

   ```bash
   pnpm add -g --allow-build=@anthropic-ai/claude-code @anthropic-ai/claude-code
   ```

4. 卸载 Claude Code：

   ```bash
   pnpm remove -g @anthropic-ai/claude-code
   pnpm store prune

   # remove config dir if needed
   # Linux/macOS/WSL
   rm -rf ~/.claude
   rm ~/.claude.json
   # Windows PowerShell
   Remove-Item "$env:USERPROFILE\.claude" -Recurse -Force
   Remove-Item "$env:USERPROFILE\.claude.json" -Force
   ```

> 验证：`claude --version`。pnpm 包内实际是原生二进制，运行时不依赖 Node。

> 报错 `claude native binary not installed`？pnpm ≥ 10 默认**拦截依赖的 postinstall 脚本**
> （与 `ignore-scripts` 无关，即使它是 undefined 也会被拦），导致原生二进制没被链接。二选一修复：
> - 放行构建脚本重装（推荐）：`pnpm add -g --allow-build=@anthropic-ai/claude-code @anthropic-ai/claude-code`
>   （全局包不支持 `pnpm approve-builds -g`，必须用 `--allow-build`）；
> - 或手动补跑 postinstall：`node "$(pnpm root -g)/@anthropic-ai/claude-code/install.cjs"`。

## 为什么需要代理

Claude Code 会发送大量工具，其 JSON Schema 带有很重的约束
（`minimum`/`maximum`、`minItems`/`maxItems`、`minLength`/`maxLength`、`pattern` 等）。
开启 `--jinja` 后，llama.cpp 会把这些 schema 编译成 GBNF 语法并导致爆炸：

```
error parsing grammar: number of repetitions exceeds sane defaults
```

`../schema-proxy.js` 里的 **schema-proxy** 会在转发前剥离这些约束关键字，
让语法保持精简，同时工具调用仍可正常工作。

## 安装步骤

1. 启动 llama-server 并加载 chat 模板（端口 9999）：

   ```powershell
   cd .\llama.cpp
   .\start-llama.ps1        # 出现提示时选择 chat_template.jinja
   ```

2. 启动 schema 代理（端口 9998 -> 9999）：

   ```powershell
   .\agents\start-proxy.ps1
   ```

3. 安装配置：把 `settings.json` 复制到 Claude Code 的配置位置
   （`~/.claude/settings.json`，Windows 上为 `%USERPROFILE%\.claude\settings.json`），
   或把其中的 `env` 块合并到你现有的配置里。

   关键点：`ANTHROPIC_BASE_URL` 指向**代理**（`:9998`），不是 llama-server。

4. 运行 `claude`。把模型名改成你实际加载的 GGUF alias
   （见 `start-llama.ps1` 打印的 `Alias` 行）。

## 配置说明（`settings.json`）

| 字段 | 含义 |
|------|------|
| `ANTHROPIC_BASE_URL` | 必须是代理地址：`http://localhost:9998` |
| `ANTHROPIC_API_KEY` | 任意非空字符串（llama.cpp 会忽略） |
| `ANTHROPIC_DEFAULT_*_MODEL` | llama.cpp 提供的模型 alias |
| `model` | 使用哪个档位（`haiku` / `sonnet` / `opus`） |

## 状态栏（statusLine，需要 jq）

Claude Code 的状态栏是一个**自定义命令**：Claude 会把一段 JSON 通过 stdin 传给
你的脚本，脚本打印一行文本作为状态栏。因为要解析 JSON，需要先安装 `jq`。

1. 安装 `jq`：
   - Windows：`scoop install jq`（或 `winget install jqlang.jq` / `choco install jq`）
   - macOS：`brew install jq`
   - Linux/WSL：`sudo apt install jq`

2. 把本目录下已有的 `statusline.sh` 复制到 Claude Code 的配置位置（`~/.claude/statusline.sh`，Windows 上为 `%USERPROFILE%\.claude\statusline.sh`）：

   ```bash
   # Linux/macOS/WSL 中增加可执行权限
   chmod +x ~/.claude/statusline.sh   # Linux/macOS/WSL
   ```

   该脚本会显示：耗时、`model`、项目目录、会话 token、上下文占用 %、
   成本（本次 / 今日 / 7 天 / 累计）、速率限制（5h/7d）等。
   其中成本的历史聚合需额外安装 `ccusage`（可选）。

3. 在 `settings.json` 里加上 `statusLine`：

   ```json
   "statusLine": {
     "type": "command",
     "command": "bash ~/.claude/statusline.sh",
     "refreshInterval": 60
   }
   ```

4. 重启 `claude`，底部就会显示 `模型 | 目录 | 分支`。

> Claude 传入的 JSON 还包含 `session_id`、`cost`、`output_style` 等字段，可用 `jq` 自行取用扩展。

## 常见问题

- **仍然报 "failed to parse grammar"**：某个工具的 `enum` 可能过大。把 `enum`
  加进 `../schema-proxy.js` 的 `STRIP_KEYS`，然后重启代理。
- **返回空 / None**：确认 llama-server 启动时带了
  `--chat-template-file templates/chat_template.jinja`。
- **:9998 连接被拒**：代理没在运行 —— 执行 `start-proxy.ps1`。
