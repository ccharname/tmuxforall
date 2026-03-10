# tmuxforall Changelog

## 2026-03-10b — 多 Session 邮箱隔离（关键 bugfix）

### 修复
- **邮箱命名空间冲突** — 所有临时文件（mailbox / task / wip / prompt）原来只用窗口名作 key，多个 session 同名窗口（如 project-a:BE 和 project-b:BE）共享同一邮箱，导致消息串台。现在全部加入 session 名前缀隔离
- 影响文件：`send-msg.sh`、`check-mail.sh`、`dispatch-task.sh`、`report-up.sh`、`spawn-role.sh`、`restart-agent.sh`、`babysit-session.sh`
- `check-mail.sh` 自动检测当前 tmux session，兼容旧格式文件（过渡期）
- `restart-agent.sh` prompt 文件查找优先匹配 session+窗口名，逐级 fallback

---

## 2026-03-10 — 安全加固 + 会话巡检

### 新增
- **babysit-session.sh** — 会话健康巡检脚本，检查 CM 存活/角色意识/写代码违规、Agent 存活状态、Board 一致性、worktree 未提交改动。`--fix` 模式仅修复 idle 状态的问题，busy 进程永不触碰

### 改进
- **spawn-role.sh** — timeout 机制从硬 `sleep N; kill` 改为空闲检测：每 60s 检查 pane 输出 hash 变化，连续 N 分钟无变化才终止。避免误杀正在工作但进度缓慢的 agent
- **merge-to-main.sh** — 合并前安全检查：agent 窗口 busy 时阻止合并（防止删除 worktree 导致 agent 失去工作目录）；agent idle 时合并后自动关闭窗口并通知 CM
- **babysit-session.sh** — CM 角色检测从纯关键词匹配升级为三层判断（prompt 文件 → pane 关键词 → idle/busy 状态），修复关键词滚出屏幕导致误判 bare claude 的问题
- **commander.yaml** — 明确禁止 CM 内调用 invoke-intern.sh / invoke-pm.sh（Claude 嵌套限制），改用 Agent tool 替代

### Lessons Learned
- babysit --fix must never restart busy processes → "observe first, fix only when safe"
- Merging a worktree while agent is busy orphans its working directory → merge-to-main checks agent state first
- `claude -p` cannot nest inside Claude Code → Commander must use Agent tool instead of invoke-intern.sh
