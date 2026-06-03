<div align="center">

# AgentBench

### 把同一个任务，交给多个编码 Agent 并排开跑——谁更强，一眼看见。

原生 macOS App · 实时对话流对比 · 真实指标 · 自动裁判 · 一键导出

[![Release](https://img.shields.io/github/v/release/mhplala/agentbench?color=111&label=download)](https://github.com/mhplala/agentbench/releases/latest)
[![Platform](https://img.shields.io/badge/macOS-14%2B-111)](https://github.com/mhplala/agentbench/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-111)](LICENSE)
[![Signed](https://img.shields.io/badge/Developer%20ID-notarized-111)](#安装)

**[⬇️ 下载最新版 DMG](https://github.com/mhplala/agentbench/releases/latest)** ·  签名公证，双击直开，无 Gatekeeper 警告

<!-- 截图占位：把 docs/hero.png 放进来 -->
<!-- ![AgentBench](docs/hero.png) -->

</div>

---

## 为什么用它

挑编码 agent，不该靠感觉。Claude Code、Codex、OpenCode、Gemini…… 哪个在**你的真实任务、你的真实仓库**上更快、更省、改得更对？

AgentBench 把它们**放在同一起跑线**：同一个 prompt、各自隔离的仓库副本、同时开跑，实时并排看它们怎么思考、调什么工具、改了哪些文件——再用第三个模型自动打分，你来拍板。

> **零假数据。** agent 是真子进程在真跑，指标、diff、裁判、历史全部来自真实运行。没有 mock，没有演示动画。

---

## 核心能力

🏁 **2–4 路并排竞速**
同一任务交给最多 4 个 agent，各自在工作目录的隔离副本里并行跑，互不干扰、**绝不碰你的真实仓库**。

🌊 **实时对话流**
推理、工具调用（读/写/执行）、最终回答，逐条流式呈现——看清每个 agent 的「干活过程」，而不只是结果。

📊 **真实指标，一眼分高下**
延迟 / 成本 / Tokens / 改动行数并排对比，更优的一侧自动标绿。token 与成本优先取 CLI 上报真值。

🔍 **预览 · 代码 · Diff**
产出物可切「预览 / 代码」，代码模式 git 风格红删绿增；`Esc` 进全屏并排放大对比。

⚖️ **自动裁判 + 人工投票**
跑完由一个独立「裁判模型」结构化评分（五维明细 + 总分 + 理由），你再投票定胜负，写入历史。

🗂️ **历史存档 · 可重看 · 可导出**
每次对比只读存档、随时回看完整转录与产出物；一键**导出整个 trace + 原始日志 + 指标 + 裁判**到文件夹，继续离线分析。

🔌 **接任意 CLI 与中转**
内置 Claude Code / Codex / OpenCode / Gemini / Cursor / Aider；用 `agents.json` 声明任意新 CLI 或第三方中转（火山豆包、小米 MiMo…）。**内置 Responses→chat 本地代理**，让只会 Responses 协议的 codex 也能直连 chat-only 中转——无需 cc-switch、无需手改配置。

---

## 安装

1. **[下载最新 DMG](https://github.com/mhplala/agentbench/releases/latest)**
2. 拖入「应用程序」，双击打开（已 Developer ID 签名 + Apple 公证，**不会有 Gatekeeper 拦截**）
3. 首次进入会自动探测本机已安装的 agent CLI——装了哪个就能跑哪个

> 要求 **macOS 14+**。运行某个 agent 需要其 CLI 已安装并登录/可用；未安装的会在界面提示安装方式。

---

## 60 秒上手

1. **写任务** —— 一句话或一段需求，选工作目录（留空=空白沙盒）
2. **选 agent** —— 左右各选一个（点「添加 agent」最多到 4 路），各选模型
3. **运行对比** —— `⌘↵`，看它们实时并排干活
4. **看裁判 + 投票** —— 自动评分出来后，你定胜负
5. **存档 / 导出** —— 结果进历史，需要时一键导出全部 trace

---

## 真实集成（不是 mock）

| 能力 | 实现 |
|---|---|
| 跑 agent | `Process` 启动真实 CLI 子进程，流式读取 stdout/stderr |
| Claude Code | `claude -p --output-format stream-json` → 解析真实 turn / tool_use / token / cost / 耗时 |
| Codex | `codex exec --json` → 解析事件流；chat-only 中转走内置 Responses→chat 代理 |
| OpenCode | `opencode run --format json` → 解析事件流 |
| 其它 / 自定义 | `agents.json` 声明命令模板 + 解析器；通用文本适配器兜底 |
| 隔离 | 工作目录 APFS 克隆到临时副本；git 仓库打 baseline commit，运行后 `git diff` 取**仅 agent 的改动** |
| 指标 | 延迟=真实墙钟/上报耗时；token/cost 优先用 CLI 上报值，否则按字符估算并标 `≈` |
| 裁判 | 独立「元 Agent」结构化评分（`--json-schema`），与参赛 agent 身份/额度隔离，避免「自己评自己」 |
| 持久化 | `~/Library/Application Support/AgentBench/`（历史 + 大日志外置为独立 `.log`） |

---

## 从源码构建

```bash
# 直接跑（开发）
swift run

# 打包成可双击的 .app（无需 Xcode）
./build-app.sh && open build/AgentBench.app

# 出签名 + 公证的分发 DMG（需 Developer ID + notarytool 配置）
./release.sh
```

构建需 **Swift 6.x / Xcode 26**；产物运行于 macOS 14+。

---

## 安全说明

AgentBench 是一个会**启动任意 CLI、访问你指定仓库**的开发者工具，因此：

- App **不开启 macOS sandbox**（否则无法启动 agent CLI）。
- 每次运行默认在**隔离副本**中进行；可在设置里开启「沙盒运行」进一步限制写入范围（codex 用其原生 workspace-write 沙盒，其余用 `sandbox-exec` 包裹）。
- agent 产出的 HTML 预览**默认不自动运行脚本**，需在每个预览上手动点「信任并运行」。
- 中转凭证等只写在本机 `agents.json` / 设置里，**不进仓库**。

---

## 许可

[MIT](LICENSE) © 2026 Stev Wang
