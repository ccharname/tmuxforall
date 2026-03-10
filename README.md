# tmuxforall

Turn tmux into a multi-agent operating system for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

把 tmux 变成 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 的多 Agent 操作系统。

One command bootstraps a project team: a **Commander** makes decisions, a **PM** plans, and specialized **engineer agents** execute in parallel — each in its own tmux window with an isolated git worktree.

一条命令启动一个项目团队：**Commander（指挥官）** 负责决策，**PM** 负责规划，多个**专业工程师 Agent** 在各自的 tmux 窗口中并行执行——每个 Agent 拥有独立的 git worktree，互不干扰。

## Why? / 为什么需要它？

Single-agent Claude hits walls on complex projects: context overflows, sequential bottlenecks, conflicting file edits. tmuxforall solves this by giving each agent its own window, worktree, and role — then coordinating them through a pull-based mailbox system.

单个 Claude Agent 在复杂项目中会遇到瓶颈：上下文溢出、串行阻塞、文件编辑冲突。tmuxforall 给每个 Agent 独立的窗口、worktree 和角色，再通过拉取式邮箱系统协调——Agent 专注工作时永远不会被打断。

## Quick Start

```bash
# Install
git clone https://github.com/zhengma/tmuxforall.git ~/.claude/skills/tmuxforall
bash ~/.claude/skills/tmuxforall/install.sh

# Bootstrap a project
SKILL=~/.claude/skills/tmuxforall
bash $SKILL/bootstrap.sh my-app --dir /path/to/project --budget 5 --goal "Build e-commerce system"

# Switch to the session
tmux switch-client -t my-app
```

The Commander auto-starts: reads the Board, plans tasks, spawns agents.

Commander 自动启动：读取指挥板、规划任务、孵化 Agent。

## Architecture / 架构

```
┌─────────────────────────────────────────────────────┐
│  tmux session: my-app                               │
│                                                     │
│  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐ │
│  │  CM  │  │  BE  │  │  FE  │  │  QA  │  │  RS  │ │
│  │ Cmdr │  │ Back │  │Front │  │ Test │  │Rsrch │ │
│  └──┬───┘  └──┬───┘  └──┬───┘  └──┬───┘  └──┬───┘ │
│     │         │         │         │         │      │
│     │    dispatch-task   │    send-msg       │      │
│     ├────────►│         │         │         │      │
│     │         │         │         │         │      │
│     │    report-up      │    check-mail     │      │
│     │◄────────┤         │         │         │      │
│     │         │         │         │         │      │
│     │    ┌────┴────┐  ┌─┴──────┐  │         │      │
│     │    │worktree │  │worktree│  │         │      │
│     │    │feature/ │  │feature/│  │         │      │
│     │    │  BE     │  │  FE   │  │         │      │
│     │    └─────────┘  └────────┘  │         │      │
└─────┴─────────────────────────────┴─────────┴──────┘
```

### Roles / 角色

| Window | Role / 角色 | Type / 类型 | What it does / 职责 |
|--------|------|------|-------------|
| CM | Commander 指挥官 | — | Sole decision-maker. Plans, dispatches, tracks. Never writes code. 唯一决策者，规划、派发、跟踪，绝不写代码。 |
| PM | Product Manager 产品经理 | thinker | Research & planning. 调研与规划。 |
| FE | Frontend 前端 | executor | UI, components, styles. Own worktree. 界面、组件、样式，独立 worktree。 |
| BE | Backend 后端 | executor | API, services, models. Own worktree. 接口、服务、模型，独立 worktree。 |
| QA | QA 质检 | inspector | Testing & validation. Read-only. 测试与验证，只读权限。 |
| RS | Researcher 研究员 | thinker | Temporary investigation. 临时调研。 |

Roles are customizable — create any role with any archetype:

角色完全可自定义——用任意原型创建任意角色：

```bash
# Data pipeline project
bash $SKILL/spawn-role.sh data-cleaner $PROJECT --archetype executor --scope "data/"
bash $SKILL/spawn-role.sh crawler-dev $PROJECT --archetype executor --scope "spiders/"
```

### Three Archetypes / 三种原型

| Archetype / 原型 | Worktree | File Access / 文件权限 | Use for / 用途 |
|-----------|----------|-------------|---------|
| `executor` 执行者 | Yes | Write 读写 | Coding tasks — each gets its own branch 编码任务，各自独立分支 |
| `inspector` 检查者 | No | Read-only 只读 | Testing, review, validation 测试、审查、验证 |
| `thinker` 思考者 | No | None 无 | Research, planning, analysis 调研、规划、分析 |

## Communication / 通信

Messages use a **pull-based mailbox** — agents are never interrupted mid-thought.

消息采用**拉取式邮箱**——Agent 专注工作时绝不会被打断。

```bash
# Dispatch a task (writes to file, survives context compaction)
bash $SKILL/dispatch-task.sh "${SESSION}:FE" "Build login page" "Responsive" "Form validation"

# Send a message (mailbox + bell notification)
bash $SKILL/send-msg.sh "${SESSION}:PM" "Research competitor auth flows"

# Check mailbox (agent calls this after completing work)
bash $SKILL/check-mail.sh CM

# Broadcast to all agents
bash $SKILL/broadcast.sh $PROJECT "Priority shift: focus on core features"
```

## Monitoring / 监控

```bash
# Dashboard snapshot
bash $SKILL/dashboard.sh $PROJECT

# Health check (observe only)
bash $SKILL/babysit-session.sh $PROJECT

# Health check + auto-fix (only fixes idle processes, never touches busy ones)
bash $SKILL/babysit-session.sh $PROJECT --fix
```

## Standalone Roles / 独立角色（无需 Commander）

For single-agent work: / 单 Agent 使用：

```bash
# Add to ~/.zshrc
alias claude-as="bash ~/.claude/skills/tmuxforall/claude-as"
alias cl-be="claude-as backend-engineer"
alias cl-fe="claude-as frontend-engineer"
alias cl-qa="claude-as qa-engineer"
alias cl-pm="claude-as product-manager"

# Use
cl-be                              # Backend engineer with own worktree
cl-fe -- -p "Fix login bug"       # One-shot mode
claude-as db-migrator --archetype executor  # Dynamic role
```

## Requirements / 依赖

**Required / 必需：**
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude` CLI)
- tmux 3.0+
- git

**Optional (recommended) / 可选（推荐）：**
- [worktrunk (`wt`)](https://github.com/theniceboy/worktrunk) — enhanced worktree management / 增强 worktree 管理
- [agent-tracker](https://github.com/theniceboy/agent-tracker) — real-time task tracking TUI / 实时任务追踪终端界面

## Configuration / 配置

All paths are centralized in `config.sh` and overridable via environment variables:

所有路径集中在 `config.sh`，可通过环境变量覆盖：

| Variable | Default | Purpose |
|----------|---------|---------|
| `TMUXFORALL_LOG_DIR` | `~/.local/share/tmuxforall/logs` | Agent output logs |
| `TMUXFORALL_STATE_DIR` | `~/.local/share/tmuxforall/checkins` | Check-in state files |
| `TMUXFORALL_TMP` | `$TMPDIR` or `/tmp` | Mailbox, prompt, task temp files |
| `TMUXFORALL_CLAUDE_CMD` | `claude` | Claude CLI command |

See `tmux.conf.example` for recommended tmux settings.

## Key Design Decisions / 核心设计决策

- **Pull-based mailbox / 拉取式邮箱**: Agents read messages when ready, never interrupted mid-thought. Agent 准备好了才读消息，专注时绝不打断。
- **Worktree isolation / worktree 隔离**: Each executor gets its own branch — no merge conflicts between agents. 每个执行者独立分支，Agent 间零冲突。
- **Budget enforcement / 预算管控**: Commander tracks agent count in COMMANDER-BOARD.md. 指挥官在指挥板中追踪 Agent 数量。
- **Growth memory / 成长记忆**: Agents accumulate lessons in `memory/` — new agents inherit wisdom. Agent 积累经验教训，新 Agent 继承前辈智慧。
- **Three-layer execution / 三层执行模型**: Commander tries inline → Agent tool → spawn-role.sh (lightest first). 指挥官优先用最轻量方式：内联 → Agent tool → 孵化窗口。
- **Idle-based timeout / 空闲检测超时**: Monitors output hash every 60s, only kills truly idle agents. 每 60 秒检查输出变化，只终止真正空闲的 Agent。
- **Observe-first babysit / 观察优先巡检**: Health checks default to reporting only; `--fix` only touches idle processes. 巡检默认只报告；`--fix` 只修复空闲进程，绝不碰正在工作的。

## License

MIT
