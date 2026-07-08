# 模板生成器（Template Generator）

目标：
- 保持官方模板行为一致
- 最大化兼容 Agent 与 OpenAI Compatible API
- 自动修复输入，而非抛出异常
- 模板结构清晰、模块化、易维护、可配置

功能要求：

【消息处理】
- 支持 system、developer、user、assistant、tool、tool_calls、tool_result、function、function_call 等角色
- 支持未知角色自动降级
- 自动合并多个 system/developer
- developer 自动并入 system
- system 自动移动到最前
- 保持其它消息顺序
- 删除空消息、重复消息
- Trim 空白、压缩连续空行

【Prompt 构建】
- 模块化生成 System/User/Assistant/Tool Block
- 保持官方 Qwen Prompt 风格
- 支持多轮对话
- 支持多模态 content（数组格式）
- Header 可配置

【Tool Calling】
- 支持 OpenAI Tool Calling
- 支持 Claude Tool Use
- 支持 MCP
- 支持 Parallel Tool Calls
- 保留 Tool ID、Tool Name、Arguments
- Tool Result 自动转义(XML/JSON/Markdown)
- Tool Result 可配置长度限制

【Thinking】
- 保留 Qwen Thinking
- 支持 <think>/<thinking>
- 推理与最终回答分离
- 可配置是否输出 Thinking

【Structured Output】
- 支持 JSON Mode
- 支持 JSON Schema
- 支持 response_format
- 支持 strict 输出

【API 兼容】
- OpenAI Chat Completions
- OpenAI Responses API
- Anthropic Messages API
- llama.cpp 最新 Chat Template

【兼容客户端】
- Claude Code
- Codex CLI
- Aider
- OpenCode
- Reasonix
- Cline
- Roo Code
- Continue
- Cursor(OpenAI Provider)

【Prompt Compression】
- 合并 System
- 去除空消息
- 去除重复消息
- 压缩空白
- 自动 Trim
- Token 优化

【安全】
- XML/HTML/JSON/Markdown Escape
- Tool Injection 基础防护
- Prompt Injection 基础防护（模板层）

【异常处理】
- 不使用 raise_exception()
- 自动修复非法输入
- Unknown Role 自动兼容
- Missing Content 自动处理
- 最大程度保证模板渲染成功

【可配置】
所有增强功能使用 Feature Flags 控制，默认开启，可单独关闭。

【代码要求】
- 基于最新版 llama.cpp Jinja 语法
- 保持与官方 Qwen3.6 模板同步
- 尽量减少重复逻辑
- 添加必要注释
- 保持良好的可读性
- 不影响模型推理能力
- 不修改 tokenizer 行为

【兼容性】
尽可能保持与官方 Qwen chat_template 的 Diff 最小，仅在兼容性、稳定性和可维护性方面进行增强，便于后续同步官方模板更新。

【测试】
提供完整测试用例，覆盖：
- Chat Completions
- Responses API
- Tool Calling
- Claude Code
- Codex CLI
- 多 System/Developer
- Thinking
- JSON Schema
- MCP

---

# 实现状态（Implementation Status）

> 交付文件：
> - `templates/chat_template.jinja` —— Agent 优化模板（基于 Qwen3.6 官方 ChatML）
> - `templates/tests/test_cases.json` —— 15 条测试用例
> - `templates/tests/run_template_tests.ps1` —— 通过 llama-server `/apply-template` 端点渲染并校验
>
> 校验：`llama-template-analysis.exe --template-file` 实测，minja 引擎解析/渲染通过，能力探测
> `supports_tools / supports_tool_calls / supports_system_role / supports_parallel_tool_calls = true`。

## Feature Flags（模板顶部，默认值）

| Flag | 默认 | 作用 |
|------|------|------|
| `FEAT_MERGE_SYSTEM` | true | 合并所有 system 消息 |
| `FEAT_DEVELOPER_TO_SYSTEM` | true | developer 并入 system |
| `FEAT_SYSTEM_FIRST` | true | system 块始终置顶 |
| `FEAT_DROP_EMPTY` | true | 丢弃空/纯空白消息 |
| `FEAT_KEEP_THINKING` | true | 保留 `reasoning_content` → `<think>` |
| `FEAT_FLATTEN_MULTIMODAL` | true | content 数组扁平化为文本（图片→`<image>`） |
| `FEAT_NORMALIZE_THINK` | true | `<thinking>` 标签归一化为 `<think>` |
| `FEAT_DEDUP` | false | 丢弃相邻完全重复的 user/assistant 消息（默认关，避免误伤） |
| `TOOL_RESULT_MAX` | 0 | tool 结果字符截断，0=不限 |
| `TOOL_HEADER` / `TOOL_FOOTER` | 官方文案 | Tools 段落文案，可配置 |

## 需求覆盖

| 需求 | 状态 |
|------|------|
| 多角色 / 未知角色降级 | ✅ |
| system/developer 合并并置顶、保持其它顺序 | ✅ |
| 删除空消息 / Trim | ✅ |
| 删除相邻重复消息 | ✅（`FEAT_DEDUP`，默认关） |
| 多模态 content 数组 | ✅（扁平化为文本；真实视觉 embedding 由 server/mtmd 处理） |
| Tools 段可配置 Header | ✅（`TOOL_HEADER`/`TOOL_FOOTER`） |
| Tool Calling：OpenAI / Claude `input` / MCP / 并行 | ✅ |
| Tool Result 长度限制 | ✅（`TOOL_RESULT_MAX`） |
| Thinking 保留 / 推理分离 / `<thinking>` 归一化 / 可配置 | ✅ |
| Structured Output（JSON/Schema/response_format） | ✅（模板层不干预，由 llama.cpp grammar 负责，已验证不破坏渲染） |
| API 兼容（OpenAI Chat/Responses、Anthropic、llama.cpp） | ✅（server 归一化为 messages 后套模板） |
| 客户端（Claude Code / Codex / Aider / Cline / Cursor…） | ✅ |
| 异常处理（不使用 `raise_exception`、自动修复） | ✅ |
| minja 语法 / 与官方最小 diff / 不改推理与 tokenizer | ✅ |
| 完整测试用例 | ✅ |

## 有意不实现的项（及原因）

以下条目在“模板层”实现会破坏内容保真度或偏离“不改变模型行为、与官方 diff 最小”的首要目标，因此**刻意不做**，应在应用层处理：

| 需求 | 原因 |
|------|------|
| Tool Result / 内容转义（XML/JSON/Markdown Escape） | 会破坏工具返回的 JSON、代码块，对编码类 Agent 是负优化 |
| 压缩连续空行 | 会破坏用户消息里的代码缩进与空行 |
| Prompt / Tool 注入过滤 | 模板层启发式过滤不可靠且易误伤，注入防护应在应用层/网关做 |

如确有场景需要，可将其做成**默认关闭**的 Feature Flag 再启用。

## 运行测试

```powershell
# 1) 用本模板启动服务
cd ..\llama.cpp
.\start-llama.ps1        # 在 Chat template 步骤选择 chat_template.jinja

# 2) 另开终端运行测试
.\templates\tests\run_template_tests.ps1
```

