# tmuxforall

Turn tmux into a multi-agent operating system for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

One command bootstraps a project team: a **Commander** makes decisions, a **PM** plans, and specialized **engineer agents** execute in parallel — each in its own tmux window with an isolated git worktree.

## Why?

Single-agent Claude hits walls on complex projects: context overflows, sequential bottlenecks, conflicting file edits. tmuxforall solves this by giving each agent its own window, worktree, and role — then coordinating them through a pull-based mailbox system.

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

## Architecture

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

### Roles

| Window | Role | Type | What it does |
|--------|------|------|-------------|
| CM | Commander | — | Sole decision-maker. Plans, dispatches, tracks. Never writes code. |
| PM | Product Manager | thinker | Research & planning. |
| FE | Frontend | executor | UI, components, styles. Own worktree. |
| BE | Backend | executor | API, services, models. Own worktree. |
| QA | QA Engineer | inspector | Testing & validation. Read-only. |
| RS | Researcher | thinker | Temporary investigation. |

Roles are customizable — create any role with any archetype:

```bash
# Data pipeline project
bash $SKILL/spawn-role.sh data-cleaner $PROJECT --archetype executor --scope "data/"
bash $SKILL/spawn-role.sh crawler-dev $PROJECT --archetype executor --scope "spiders/"
```

### Three Archetypes

| Archetype | Worktree | File Access | Use for |
|-----------|----------|-------------|---------|
| `executor` | Yes | Write | Coding tasks — each gets its own branch |
| `inspector` | No | Read-only | Testing, review, validation |
| `thinker` | No | None | Research, planning, analysis |

## Communication

Messages use a **pull-based mailbox** — agents are never interrupted mid-thought.

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

## Monitoring

```bash
# Dashboard snapshot
bash $SKILL/dashboard.sh $PROJECT

# Health check (observe only)
bash $SKILL/babysit-session.sh $PROJECT

# Health check + auto-fix (only fixes idle processes, never touches busy ones)
bash $SKILL/babysit-session.sh $PROJECT --fix
```

## Standalone Roles (no Commander needed)

For single-agent work:

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

## Requirements

**Required:**
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (the `claude` CLI)
- tmux 3.0+
- git

**Optional (recommended):**
- [worktrunk (`wt`)](https://github.com/theniceboy/worktrunk) — enhanced worktree management
- [agent-tracker](https://github.com/theniceboy/agent-tracker) — real-time task tracking TUI

## Configuration

All paths are centralized in `config.sh` and overridable via environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `TMUXFORALL_LOG_DIR` | `~/.local/share/tmuxforall/logs` | Agent output logs |
| `TMUXFORALL_STATE_DIR` | `~/.local/share/tmuxforall/checkins` | Check-in state files |
| `TMUXFORALL_TMP` | `$TMPDIR` or `/tmp` | Mailbox, prompt, task temp files |
| `TMUXFORALL_CLAUDE_CMD` | `claude` | Claude CLI command |

See `tmux.conf.example` for recommended tmux settings.

## Key Design Decisions

- **Pull-based mailbox**: Agents read messages when ready, never interrupted mid-thought
- **Worktree isolation**: Each executor gets its own branch — no merge conflicts between agents
- **Budget enforcement**: Commander tracks agent count in COMMANDER-BOARD.md
- **Growth memory**: Agents accumulate lessons in `memory/` — new agents inherit wisdom
- **Three-layer execution**: Commander tries inline → Agent tool → spawn-role.sh (lightest first)
- **Idle-based timeout**: Monitors output hash every 60s, only kills truly idle agents
- **Observe-first babysit**: Health checks default to reporting only; `--fix` only touches idle processes

## License

MIT
