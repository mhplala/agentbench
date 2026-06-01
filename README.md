# AgentBench · 模型评测工具

一个原生 macOS app（SwiftUI），把**同一个任务**交给两个编码 agent 并排跑，实时对比它们的
对话流、指标、产出物，并用第三个模型自动裁判 + 人工投票，结果存为历史。

> 由 Claude Design 的 HTML 原型（`模型评测工具.html` / AgentBench）落地为真实可运行的原生 app。
> **无任何假数据**——agent 是真跑的，指标、diff、裁判、历史都来自真实运行。

---

## 它做什么

- **配置**：写任务 Prompt，左右各选一个 agent（自动探测本机已安装的 CLI）、模型、工作目录；可开自动裁判。
- **运行**：两个 agent 在**各自隔离的仓库副本**里并行跑，互不干扰、不碰你的真实仓库；对话流（推理 / 工具调用 / 回答）实时流式填充。
- **对比**：底部指标条对比 **延迟 / 成本 / Tokens / 行数**，更优的一侧自动标绿；每个回答卡可切 **预览 / 代码**，代码模式可开 **Diff 高亮**（git 风格红删绿增）。
- **放大对比**：全屏并排看两边产出物（预览 / 代码 / Diff），`Esc` 退出。
- **裁判 + 打分**：跑完由 `claude` 评判优劣，给分数条、五维明细和理由；你再投 A / 平局 / B，写入历史。
- **历史**：左边栏按时间分组列出每次对比；点开为只读存档，可「以此重跑」。

## 真实集成（不是 mock）

| 能力 | 实现 |
|---|---|
| 跑 agent | 通过 `Process` 启动 agent CLI 子进程，流式读取 stdout/stderr |
| Claude Code | `claude -p --output-format stream-json` → 解析真实 turn / tool_use / token / cost / 耗时 |
| Codex | `codex exec --json` → 解析事件流 |
| OpenCode | `opencode run --format json` → 解析事件流 |
| Gemini / Cursor / Aider | 通用文本适配器（捕获输出 + 真实耗时 + 估算 token） |
| 隔离 | 每次运行把工作目录 `cp -Rc`（APFS 克隆）到临时副本；git 仓库会先打一个 baseline commit，运行后 `git diff HEAD` 取**仅 agent 的改动** |
| 指标 | 延迟=真实墙钟/上报耗时；token/cost 优先用 CLI 上报值，否则按字符估算并标注 `≈` |
| Diff | LCS 行级 diff（与原型 `diffLines` 一致） |
| 裁判 | 复用 `claude -p --output-format json --json-schema` 做结构化真实评分 |
| 历史 | JSON 持久化到 `~/Library/Application Support/AgentBench/sessions.json` |

> 未安装的 agent 会在配置页显示安装方式；运行需要对应 CLI 已登录/可用。

## 运行

```bash
# 方式一：命令行直接跑（开发）
swift run

# 方式二：打包成可双击的 .app（无需 Xcode）
./build-app.sh          # → build/AgentBench.app
open build/AgentBench.app

# 方式三：Xcode 工程（GUI 调试 / 签名公证）
xcodegen generate       # 生成 AgentBench.xcodeproj
open AgentBench.xcodeproj   # Cmd+R 运行
```

要求：macOS 14+、Swift 6.x / Xcode 26（构建用）。

## 代码结构

```
Sources/AgentBench/
  AgentBenchApp.swift        @main · 窗口 · 菜单
  Model/
    Models.swift             Session / RunResult / Turn / Metrics / Verdict …
    AgentCatalog.swift       agent 目录（glyph / 模型 / CLI / 安装提示）
  Core/
    ProcessRunner.swift      Process 封装 · PATH 修正 · 流式行回调 · which
    Detector.swift           探测已安装 CLI + 版本
    Adapters.swift           各 agent 命令构建 + 输出解析（Claude/Codex/OpenCode/通用）
    JSON.swift               宽松 JSON 导航
    AgentRunner.swift        单 agent 编排：隔离 → 跑 → 收集改动 → 指标
    Workspace.swift          仓库隔离副本 + git/快照 diff + 预览产物提取
    DiffEngine.swift         LCS 行 diff
    Judge.swift              claude -p 结构化裁判
    Store.swift              历史持久化 + 偏好
  ViewModel/AppState.swift   状态机（compose/running/done）· 并行跑 · 投票 · 历史
  Views/                     Theme / Components / Sidebar / Compose / Workspace /
                             ConvoStream / CodeView / JudgeCard / CompareOverlay /
                             ArchiveView / SettingsView / WebView / RootView
```

## 设计还原

黑白极简（Airbnb-ish），与原型同一套 token：`#f5f5f6` 底、近黑 `#16161a` 文字、功能色仅用于
diff 红绿与更优指标的绿色。边栏管会话 · 双列对话流跑任务 · 工具栏/操作栏放动作 · 全屏对比看产物——
即原型最终落点的 IA。

## 安全

- agent 默认在隔离副本中运行（设置里可关「自动批准」改为更严格权限模式）。
- app 不开启 sandbox（需要启动任意 CLI、访问任意仓库目录）。分发时可在 `build-app.sh` 后接公证。
