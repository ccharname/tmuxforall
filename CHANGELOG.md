# tmuxforall Changelog

## 2026-03-10d — L0 安全手册 + SKILL.md 安全段落

### 新增
- **references/safety-manual.md** — L0 操作安全手册：三大架构公理（session 名可变性、命名空间隔离、busy 进程神圣不可侵犯）、操作检查清单（bootstrap/kill/babysit/restart/merge 前检查项）、已知陷阱 P-001~P-004 记录、事故索引、恢复手册
- **SKILL.md L0 Safety 段落** — 在 Battle-Tested Lessons 后新增 L0 安全规范摘要，链接到完整安全手册

---

## 2026-03-10c — bootstrap 同名 session 冲突检测（致命 bugfix）

### 修复
- **bootstrap.sh 同名 session 冲突** — session manager 给 session 加数字前缀（如 `project-a` → `3-project-a`），但 bootstrap 用 `tmux has-session -t "project-a"` 做精确匹配检测不到 `3-project-a`，导致创建了同名新 session。L0 无法区分新旧 session，误杀了正在工作的原 CM
- 修复方式：改用 `grep -E "^([0-9]+-)?name$"` 模糊匹配，检测到已有 session 则**拒绝创建并报错退出**
- `_session_name.sh` 增加 `tf_find_session()` 辅助函数，统一模糊匹配逻辑

### 事件
- 为 new-project 项目执行 `bootstrap.sh --dir project-a`（误传了 project-a 目录），创建了第二个 project-a session，L0 杀错了正在研究 ongoing task的原 CM
- 通过日志 `CM-20260310.log` 中的 resume ID 恢复了原 CM 会话

---

## 2026-03-10b — 多 Session 邮箱隔离（关键 bugfix）

### 修复
- **邮箱命名空间冲突** — 所有临时文件（mailbox / task / wip / prompt）原来只用窗口名作 key，多个 session 同名窗口（如 project-a:BE 和 project-b:BE）共享同一邮箱，导致消息串台。现在全部加入 session 名前缀隔离
- 影响文件：`send-msg.sh`、`check-mail.sh`、`dispatch-task.sh`、`report-up.sh`、`spawn-role.sh`、`restart-agent.sh`、`babysit-session.sh`
- `check-mail.sh` 自动检测当前 tmux session，兼容旧格式文件（过渡期）
- `restart-agent.sh` prompt 文件查找优先匹配 session+窗口名，逐级 fallback

### 事件
- project-b 的 BE 通过 report-up.sh 写入 `tmuxforall-mailbox-CM.txt`，被 project-a 的 CM check-mail 读取，导致 project-a CM 接收了 project-b 的深度爬取汇报

---

## 2026-03-10 — 安全加固 + 会话巡检

### 新增
- **babysit-session.sh** — 会话健康巡检脚本，检查 CM 存活/角色意识/写代码违规、Agent 存活状态、Board 一致性、worktree 未提交改动。`--fix` 模式仅修复 idle 状态的问题，busy 进程永不触碰

### 改进
- **spawn-role.sh** — timeout 机制从硬 `sleep N; kill` 改为空闲检测：每 60s 检查 pane 输出 hash 变化，连续 N 分钟无变化才终止。避免误杀正在工作但进度缓慢的 agent
- **merge-to-main.sh** — 合并前安全检查：agent 窗口 busy 时阻止合并（防止删除 worktree 导致 agent 失去工作目录）；agent idle 时合并后自动关闭窗口并通知 CM
- **babysit-session.sh** — CM 角色检测从纯关键词匹配升级为三层判断（prompt 文件 → pane 关键词 → idle/busy 状态），修复关键词滚出屏幕导致误判裸 cl2 的问题
- **commander.yaml** — 明确禁止 CM 内调用 invoke-intern.sh / invoke-pm.sh（Claude 嵌套限制），改用 Agent tool 替代

### 经验教训
- L0 Meta-Commander 模式确立：Lucky 会话作为 CM 上层监督，诊断 CM 自身无法发现的问题
- babysit --fix 误杀工作中 CM 事件 → 确立"观察优先、修复需确认"原则
- 合并后 worktree 消失导致 agent 所有 Bash 命令失败 → merge-to-main 必须先检查 agent 状态
- invoke-intern.sh 在 Claude Code 内嵌套调用失败 → CM 必须用 Agent tool
