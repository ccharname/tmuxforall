# tmuxforall — Multi-Agent Collaboration OS on tmux

A framework that turns tmux into a multi-agent operating system. One command bootstraps a project team: a **Commander** makes decisions, a **PM** plans, and specialized **engineer agents** execute in parallel — each in its own tmux window with an isolated git worktree.

## Why this architecture?

Single-agent Claude hits walls on complex projects: context overflows, sequential bottlenecks, conflicting file edits. tmuxforall solves this by giving each agent its own window, worktree, and role — then coordinating them through a pull-based mailbox system that prevents agents from interrupting each other mid-thought.

---

## Quick Start

```bash
SKILL="${CLAUDE_SKILL_DIR:-~/.claude/skills/tmuxforall}"

# 1. Bootstrap a project (creates session, Board, and Commander agent)
bash $SKILL/bootstrap.sh my-app --dir /path/to/project --budget 5 --goal "构建电商系统"

# 2. Switch to the session
tmux switch-client -t my-app   # or Prefix + w to pick from tree

# 3. Commander auto-starts: reads Board, plans tasks, spawns agents
#    If --goal is omitted, Commander will ask you for the project goal
```

The `--budget N` parameter sets how many agent windows the Commander can open. It has autonomy within [⌈0.5N⌉, ⌊1.5N⌋] — enough flexibility to adapt without runaway resource usage.

### Standalone role aliases (no tmux needed)

For single-agent work without Commander coordination, use shell aliases:

```bash
cl-be                              # Backend engineer (isolated, own worktree)
cl-fe                              # Frontend engineer (isolated, own worktree)
cl-qa                              # QA engineer (isolated, read-only)
cl-pm                              # Product manager (retains MCP tools)
claude-as backend-engineer myapp   # Specify project name
claude-as db-migrator --archetype executor  # Dynamic role
cl-be -- -p "修复登录bug"           # Pass args to claude (one-shot mode)
```

These launch Claude Code with role-specific system prompts and **full identity isolation** — executor/inspector roles run with `CLAUDE_CODE_SIMPLE=1` (no global CLAUDE.md, no MCP, no hooks). Each executor gets its own worktree via worktrunk (`wt`).

### Session navigation

- **F1–F9**: Jump to session by number (sessions get numbered prefixes like `3-xxx`)
- **C-a w**: Tree view of all sessions/windows (recommended for overview)
- **C-a ( / C-a )**: Previous/next session
- **M-0**: Jump to Commander window within a session

Note: `Ctrl+1~9` does NOT work — most terminals don't send Ctrl+digit escape sequences.

---

## Roles

### Archetypes (project-agnostic)

| Archetype | Worktree | File Access | Use for |
|-----------|----------|-------------|---------|
| `executor` | Yes | Write | Coding tasks — each gets its own branch |
| `inspector` | No | Read-only | Testing, review, validation |
| `thinker` | No | None | Research, planning, analysis |

### Predefined roles (convenience shortcuts for common projects)

| Window | Role | Archetype | What it does | Memory |
|--------|------|-----------|-------------|--------|
| CM | Commander | — | Sole decision-maker. Plans, dispatches, tracks. Never writes code. | — |
| PM | Product Manager | thinker | Research & planning. Run via `claude -p` (no window). | ✓ |
| FE | Frontend | executor | UI, components, styles. Own worktree. | ✓ |
| BE | Backend | executor | API, services, models. Own worktree. | ✓ |
| QA | QA Engineer | inspector | Testing & validation. Read-only code access. | ✓ |
| RS | Researcher | thinker | Temporary investigation. No persistent memory. | — |

### Dynamic roles (recommended for non-web projects)

The Commander should create roles that fit the project, not force-fit FE/BE/QA:

```bash
# Data engineering project
bash $SKILL/spawn-role.sh data-cleaner $PROJECT --archetype executor --scope "data/" --parent CM
bash $SKILL/spawn-role.sh crawler-dev $PROJECT --archetype executor --scope "spiders/" --parent CM

# CLI tool project
bash $SKILL/spawn-role.sh parser-dev $PROJECT --archetype executor --scope "src/parser/" --parent CM
bash $SKILL/spawn-role.sh cli-dev $PROJECT --archetype executor --scope "src/cli/" --parent CM
```

Multiple agents of the same role? Add a suffix: `BE2`, `BE3`. Each gets its own worktree and branch (auto-numbered by spawn-role.sh).

---

## Command Reference

```bash
SKILL="${CLAUDE_SKILL_DIR:-~/.claude/skills/tmuxforall}"
PROJECT=my-app
SESSION=${PROJECT}

# === Lifecycle ===
bash $SKILL/spawn-role.sh frontend-engineer $PROJECT --parent CM
bash $SKILL/spawn-role.sh backend-engineer $PROJECT --parent CM --timeout 30
bash $SKILL/restart-agent.sh "${SESSION}:FE" $PROJECT
# spawn auto-registers to Board, creates worktree, injects memory
# --timeout sets idle-based safety net: monitors pane output hash every 60s,
# only terminates after N consecutive minutes of no output change

# === Communication ===
bash $SKILL/dispatch-task.sh "${SESSION}:FE" "Build login page" "Responsive" "Form validation"
bash $SKILL/send-msg.sh "${SESSION}:PM" "Research competitor auth flows"
bash $SKILL/check-mail.sh CM
bash $SKILL/broadcast.sh $PROJECT "Priority shift: focus on core features"
# dispatch-task writes to a file — survives context compaction
# send-msg uses mailbox + bell — never interrupts a focused agent

# === PM (background, no window) ===
bash $SKILL/invoke-pm.sh $PROJECT /tmp/pm-task.md

# === Monitoring ===
bash $SKILL/dashboard.sh $PROJECT
bash $SKILL/babysit-session.sh $PROJECT          # 健康巡检（只报告，不修改）
bash $SKILL/babysit-session.sh $PROJECT --fix    # 巡检 + 自动修复（仅修复 idle 状态的问题，busy 进程永不触碰）
bash $SKILL/checkin.sh schedule 10 "Status report" "${SESSION}:FE"
# Commander can also inspect agents directly:
# tmux capture-pane -t "${SESSION}:FE" -p -S -10

# === Git (Commander only) ===
bash $SKILL/merge-to-main.sh $PROJECT FE

# === Learning ===
bash $SKILL/grow-agent.sh frontend-engineer $PROJECT "component-dev" "Lesson learned"
```

---

## Communication Protocol

### Why pull-based mailbox?

Agents doing deep work (writing code, debugging) lose significant context when interrupted mid-thought. The mailbox model solves this: messages go to a file, a bell rings, and the agent reads when ready. This is the single most important design decision — it keeps agent quality high.

- **send-msg.sh**: Writes to mailbox + bell. Use `--direct` only when the target is idle and waiting for input.
- **dispatch-task.sh**: Writes a task file with title + acceptance criteria. The agent gets a one-liner `cat` command. Task files persist through context compaction — agents can re-read them anytime.
- **check-mail.sh**: Reads and clears mailbox. Agents should call this after completing each work unit.
- **report-up.sh**: Sends summary to parent + updates Board + fires `tmux wait-for` signal for script-level synchronization. Supports `--wip` flag to save intermediate progress without sending completion signal.

### STATUS format

Every report from an agent follows this structure so the Commander can scan quickly:

```
STATUS [window-name] [HH:MM]
已完成: ...
当前: ...
阻塞: ...（无则写"无"）
预计: ...
```

End with `printf '\a'` to bell-notify the Commander.

---

## Three Constraints

These keep the system from devolving into chaos as agents multiply:

1. **Registration**: Every agent spawned via `spawn-role.sh --parent` is auto-registered in COMMANDER-BOARD.md. No untracked agents.
2. **Report chain**: Results flow upward as summaries, not raw dumps. The Commander sees the big picture, not every line of code.
3. **Budget**: MAX_AGENTS tracked in the Board. The Commander can't silently exceed the budget — resource discipline is enforced through visibility.

---

## Battle-Tested Lessons

These patterns emerged from real multi-agent sessions. They are already encoded into the role YAML files, but understanding them helps you guide the user and diagnose problems.

### Three-layer execution model

The Commander has three execution layers, lightest first:

1. **Layer 1 — Inline**: Read/Grep/Edit directly in CM's context. For Board updates, file searches, status checks.
2. **Layer 2 — Agent tool**: Claude Code's native subagent. For research, code review, one-shot analysis. Zero budget cost, no tmux window, results return directly. Replaces most `invoke-intern.sh` and `invoke-pm.sh` use cases.
3. **Layer 3 — spawn-role.sh**: Full tmux window + worktree + persistent agent. For coding tasks >10min, multi-step iteration, tasks needing human interaction.

The Commander should always try the lightest layer first and only escalate when needed. Parallel Agent tool calls are especially powerful for multi-direction research.

### Commander must never execute, and must never block

The #1 failure mode: the Commander starts running tests, checking servers, or writing code — while 6 agents sit idle. The #2 failure mode: the Commander spends 10 minutes exploring the codebase and doing research before spawning any agents.

The Commander is a dispatcher, not a thinker. Every action must complete in <1 minute. Need research? Spawn a thinker. Need code understanding? The executor agent will read the code itself — it's an adult, give it a goal and working directory. If a message can't be delivered, respawn the agent rather than doing it yourself.

### Long tasks need background execution

Any task that might run longer than 5 minutes (eval suites, builds, large test runs) must use `nohup cmd > /tmp/output.log 2>&1 &`. Claude Code's Bash tool times out at 10 minutes — if a process runs foreground and times out, the agent loses connection to the output even though the process keeps running.

### No sleep-polling

Agents must never `sleep N` to wait for dependencies. An agent that finishes its work should report up and go idle. The Commander notifies downstream agents when dependencies are ready. `sleep 600` = 10 minutes of wasted resources.

### Context compaction kills memory

When Claude's context gets compressed, agents lose track of their tasks and reporting chains. Each role prompt reminds agents to do a **memoryFlush** before compaction — writing current task state, progress, and blockers to a file they can `cat` back after compression.

### Worktree isolation prevents conflicts

Multiple agents editing the same file without worktree isolation causes git stash/checkout collisions. Each engineering agent works in `worktrees/{window-name}/` with its own branch. The Commander is the only one who merges.

### invoke-intern/invoke-pm cannot run inside Claude Code

`claude -p` cannot be called from within an existing Claude Code process (nesting limitation). The Commander must use **Agent tool** (Layer 2) instead of `invoke-intern.sh` or `invoke-pm.sh` for inline research and one-shot tasks. These scripts are only valid when called from a non-Claude environment (e.g., pure bash orchestration).

### merge-to-main.sh safety checks

Before merging, `merge-to-main.sh` checks whether the target agent window is still running. If the agent is busy, the merge is **blocked** — merging deletes the worktree, which would orphan the agent's working directory and make all its Bash commands fail. If the agent is idle, the merge proceeds and the window is automatically closed afterward.

### babysit-session.sh: observe first, fix only when safe

`babysit-session.sh --fix` will only auto-repair **idle** processes. A busy CM or agent is never restarted, even if it appears anomalous (e.g., role keywords scrolled off screen). Detection uses a three-layer approach: (1) prompt file existence, (2) pane keyword matching, (3) idle/busy state — all three must align before taking corrective action. Default usage without `--fix` is purely observational.

### Identity isolation (SIMPLE mode)

Executor and inspector agents run with `CLAUDE_CODE_SIMPLE=1`, which disables global CLAUDE.md, MCP tools, and hooks. This makes each agent a truly independent entity — it only knows its role prompt, not the user's personal system. Thinker agents (PM, Researcher) keep full mode because they need MCP tools (WebSearch, WebFetch) for research.

---

## L0 Safety — Meta-Commander Operating Rules

L0 (the human or supervisory session managing CM sessions) has **more power than CM but also more blast radius**. These rules prevent L0 from causing the very damage it's meant to prevent. Full details in `references/safety-manual.md`.

### Three architectural axioms

1. **Session names are mutable** — session manager adds numeric prefixes (`myapp` → `3-myapp`). Always use `tf_find_session()` for matching, never `tmux has-session -t`.
2. **Namespace isolation is mandatory** — all temp files (mailbox/task/prompt/wip) must include session name prefix to prevent cross-session message leaks.
3. **Busy processes are sacred** — never kill, restart, or `--fix` a busy CM/agent, even if diagnostics look wrong.

### L0 checklist (before destructive operations)

**Before kill-session:** List all sessions → identify target by window contents (not just name) → confirm no busy agents → execute.

**Before bootstrap:** Verify no existing session matches the project name (fuzzy) → verify `--dir` points to intended directory → execute.

**Before babysit --fix:** Run without `--fix` first → review report → confirm all flagged processes are idle → execute with `--fix`.

### Known pitfalls

| ID | Pitfall | Root Cause |
|----|---------|-----------|
| P-001 | Bootstrap creates duplicate session | Session name prefix mismatch |
| P-002 | Cross-session mailbox leak | Temp files keyed by window name only |
| P-003 | babysit --fix kills working CM | Role keywords scrolled off screen + no busy guard |
| P-004 | Merge deletes worktree under busy agent | No agent-state check before merge |

---

## Growth Memory

Agents accumulate cross-project lessons in `memory/{role-id}.md`. When a new agent of the same role spawns, the last 60 lines of memory are injected into its system prompt — it starts with the wisdom of its predecessors.

When memory exceeds 50 entries, `compact-memory.sh` automatically compresses it using `claude -p`, distilling ~30 high-value lessons. This prevents memory bloat while preserving the most useful patterns.

---

## Git Isolation (via worktrunk)

Each engineering agent gets an exclusive worktree (`{workdir}/worktrees/{window-name}/`) with its own branch (`feature/{window-name}`). This prevents the merge conflicts that plague multi-agent file editing.

Worktree management uses **worktrunk (`wt`)** as the primary tool, with raw `git worktree` as fallback:
- **Create**: `wt switch --create feature/BE --no-cd`
- **List/query**: `wt list --format=json` (structured worktree metadata)
- **Merge**: `wt merge --yes` (commit→squash→rebase→push→cleanup)
- **Cleanup**: `wt remove` (removes worktree + branch in one step), `wt step prune` (bulk cleanup)

Only the Commander can merge branches back to main via `merge-to-main.sh`.

---

## Configuration

All paths are centralized in `config.sh` and overridable via environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `TMUXFORALL_LOG_DIR` | `~/.local/share/tmuxforall/logs` | Agent output logs |
| `TMUXFORALL_STATE_DIR` | `~/.local/share/tmuxforall/checkins` | Check-in state files |
| `TMUXFORALL_TMP` | `$TMPDIR` or `/tmp` | Mailbox, prompt, task temp files |
| `TMUXFORALL_CLAUDE_CMD` | `claude` | Claude CLI command |

---

## Agent Tracker Integration

tmuxforall integrates with [agent-tracker](https://github.com/theniceboy) (niceboy's Go tool) for real-time task state tracking across all windows.

### How it works

- **spawn-role.sh** → `start_task` when agent window is created
- **dispatch-task.sh** → `start_task` when task is dispatched
- **report-up.sh** → `finish_task` when agent reports completion
- **tmux hooks** → `acknowledge` on pane-focus-in (clears notification), `delete_task` on pane-died

### tmux Keybindings

| Key | Action |
|-----|--------|
| `M-t` | Open Tracker TUI (interactive task overview) |
| `M-m` | Jump to the window with latest notification |
| `M-M` | Jump back to previous window |

### Window Icons

Each window tab shows task state icons:
- ⏳ = `@watching` (task in progress, polling for completion)
- 🔔 = `@unread` (task completed, needs attention)

### Dashboard

`dashboard.sh` queries `tracker-client state --json` for real-time task status instead of stale cache files.

---

## File Structure

```
tmuxforall/
├── SKILL.md              # This file — Claude reads it on trigger
├── config.sh             # Configurable paths (env var overrides)
├── bootstrap.sh          # One-command project setup
├── claude-as             # Standalone role launcher (cl-be/cl-fe/cl-qa/cl-pm aliases)
├── build-prompt.sh       # Prompt generator (used by claude-as, invoke-pm, invoke-intern)
├── spawn-role.sh         # Agent lifecycle (spawn + worktree + memory + tracker + SIMPLE mode)
├── restart-agent.sh      # Lightweight respawn (preserves window position)
├── send-msg.sh           # Mailbox messaging
├── dispatch-task.sh      # File-based task assignment (+ tracker start_task)
├── check-mail.sh         # Read & clear mailbox
├── invoke-pm.sh          # One-command PM invocation (wraps claude -p)
├── invoke-intern.sh      # One-command intern/researcher invocation
├── report-up.sh          # Upward reporting + Board + tracker finish_task + --wip mode
├── register-agent.sh     # Board registration
├── broadcast.sh          # Message all agents
├── babysit-session.sh    # Session health check + auto-fix (CM alive, role prompt, Board consistency)
├── dashboard.sh          # Status snapshot (uses tracker-client state)
├── live-board.sh         # Real-time streaming status
├── checkin.sh            # Scheduled check-ins
├── grow-agent.sh         # Record lessons
├── compact-memory.sh     # Memory compression
├── merge-to-main.sh      # Git merge via wt merge (Commander only)
├── _session_name.sh      # Session naming utility
├── mcp_server.py         # MCP message bus (Agent-to-Agent communication via MCP tools)
├── roles/                # Role definitions (YAML) — read by spawn-role.sh
├── archetypes/           # Archetype definitions (executor/inspector/thinker)
├── templates/            # Board template + activation hook
├── memory/               # Cross-project growth memory (auto-accumulated)
└── references/           # Commander framework + tmux reference + safety manual
```
