# tmuxforall Safety Manual — L0 Operating Rules

> This manual is for L0 Meta-Commander (the supervisory layer above CM). It documents safety rules distilled from real operational incidents.

---

## Three Architectural Axioms

### Axiom 1: Session Names Are Mutable

tmux session managers may add numeric prefixes (e.g., `myapp` → `3-myapp`). **Any logic that relies on exact session name matching is a ticking bomb.**

- `tmux has-session -t "myapp"` — **unreliable**, won't match `3-myapp`
- Correct: `tmux list-sessions | grep -E "^([0-9]+-)?myapp$"`
- Unified function: `tf_find_session()` (defined in `_session_name.sh`)

### Axiom 2: Namespace Isolation Is Mandatory

When running multiple sessions, same-named windows (e.g., `session-a:BE` and `session-b:BE`) must have session-prefixed temp files, or messages will leak.

- Mailbox: `tmuxforall-mailbox-{session}-{window}.txt`
- Task: `tmuxforall-task-{session}-{window}.md`
- Prompt: `tmuxforall-prompt-{session}-{window}.md`
- WIP: `tmuxforall-wip-{session}-{window}.md`

### Axiom 3: Busy Processes Are Sacred

Running processes (CM or Agent) **must never be terminated by automation**, even if diagnostics look wrong.

- `babysit --fix` only repairs idle processes
- Must `tmux capture-pane` to confirm target state before kill
- Anomalous but busy → report only, wait for user confirmation

---

## L0 Checklist (Before Destructive Operations)

### Before kill-session

- [ ] `tmux list-sessions` to list all sessions, identify target
- [ ] If duplicate names exist, use `tmux list-windows -t <session>` to distinguish old vs new
- [ ] `tmux capture-pane -t <session>:CM -p -S -20` to confirm CM state
- [ ] Verify no busy agents in target session (check all windows)
- [ ] **Never kill a busy session** — only kill confirmed empty/new/idle ones

### Before bootstrap

- [ ] Verify no existing session matches the project name (fuzzy match)
- [ ] Verify `--dir` parameter points to the intended directory
- [ ] Verify workdir doesn't conflict with existing sessions

### Before babysit --fix

- [ ] Run without `--fix` first (report-only mode)
- [ ] Review the report
- [ ] Confirm all flagged processes are idle
- [ ] Execute with `--fix`

### Before restart-agent

- [ ] Confirm target pane is idle
- [ ] Confirm prompt file exists and is correct
- [ ] If using `--resume`, verify the resume ID is valid

### Before merge

- [ ] `merge-to-main.sh` auto-checks agent state, but L0 should verify independently
- [ ] After merge, worktree is deleted — confirm agent window is closed or notified

---

## Known Pitfalls

### P-001: Bootstrap Duplicate Session

**Trigger:** Running bootstrap against an existing project's workdir
**Impact:** Creates a second session with the same name; L0 can't tell them apart, may kill the wrong one
**Root cause:** Session manager adds numeric prefix, exact match fails
**Fix:** bootstrap.sh now uses fuzzy matching + hard reject (2026-03-10c)
**Lesson:** Always use `tf_find_session()`, never `tmux has-session -t`

### P-002: Cross-Session Mailbox Leak

**Trigger:** Multiple sessions with same-named windows (e.g., two projects both have BE)
**Impact:** Messages cross-contaminate; project A's CM reads project B's reports
**Root cause:** Temp files keyed by window name only, no session isolation
**Fix:** All temp files now include session name prefix (2026-03-10b)
**Lesson:** Multi-tenant namespace must include all identity dimensions

### P-003: babysit --fix Kills Working CM

**Trigger:** CM's role keywords scroll out of `capture-pane` visible range
**Impact:** babysit judges it as "bare claude" and restarts, killing working CM
**Root cause:** Detection relied only on pane keywords, no prompt file cross-validation
**Fix:** Three-layer detection (prompt file → pane keywords → idle/busy) + busy processes never touched (2026-03-10)
**Lesson:** Automated repair must have a "safety guard"; busy = immunity

### P-004: Merge Deletes Worktree Under Busy Agent

**Trigger:** CM runs merge-to-main while agent is still working
**Impact:** Worktree deleted, all agent Bash commands fail (working directory gone)
**Root cause:** Merge workflow didn't check agent alive state
**Fix:** merge-to-main.sh blocks merge when agent is busy (2026-03-10)
**Lesson:** Before deleting shared resources, confirm no active consumers

---

## Incident Index

| Date | Incident | Impact | Root Cause | Pitfall |
|------|----------|--------|------------|---------|
| 2026-03-10 | babysit --fix restarts working CM | CM context lost | Keyword false negative + no busy guard | P-003 |
| 2026-03-10 | Cross-project message leak | Wrong task executed | Mailbox without session isolation | P-002 |
| 2026-03-10 | Bootstrap creates duplicate session | Original CM killed, WIP lost | Session name exact match | P-001 |
| 2026-03-10 | Merge removes worktree under busy agent | Agent Bash commands fail | No agent-state check before merge | P-004 |

---

## Recovery Playbook

### CM Killed — How to Recover

1. Find resume ID: `tail -3000 ~/.local/share/tmuxforall/logs/{project}/CM-*.log | grep -i "resume"`
2. In new session or existing: `claude --resume <id> --dangerously-skip-permissions`
3. Note: `claude --resume` does NOT inherit `--dangerously-skip-permissions` — you must pass it explicitly

### Agent Worktree Gone — How to Recover

1. Check if worktree was deleted: `git worktree list`
2. If deleted, recreate: `wt switch --create feature/{window-name} --no-cd`
3. Notify agent of the new working directory path
