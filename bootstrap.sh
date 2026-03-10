#!/bin/bash
# bootstrap.sh — 一键启动 tmuxforall 多 Agent 项目
# 用法: bootstrap.sh <project> [--dir <workdir>] [--budget N]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
WORKDIR="$(pwd)"
PROJECT="${1:-$(basename "$WORKDIR")}"
BUDGET=5  # 默认中等复杂度
GOAL=""

shift 1 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)    WORKDIR="$2"; PROJECT="$(basename "$WORKDIR")"; shift 2 ;;
    --budget) BUDGET="$2"; shift 2 ;;
    --goal)   GOAL="$2"; shift 2 ;;
    *)        shift ;;
  esac
done

source "${SKILL_DIR}/_session_name.sh"
SESSION="$TF_SESSION"
BOARD="${WORKDIR}/COMMANDER-BOARD.md"
BUDGET_MIN=$(python3 -c "import math; print(math.ceil(${BUDGET}*0.5))")
BUDGET_MAX=$(python3 -c "import math; print(math.floor(${BUDGET}*1.5))")

# 1. 检查 tmux
if ! command -v tmux &>/dev/null; then
  echo "[bootstrap] 错误: tmux 未安装" >&2; exit 1
fi

if ! tmux info &>/dev/null; then
  echo "[bootstrap] 错误: tmux 服务器未运行" >&2; exit 1
fi

# 2. 检查 agent-tracker 健康状态
TRACKER_CLIENT="$HOME/.config/agent-tracker/bin/tracker-client"
if [[ -x "$TRACKER_CLIENT" ]]; then
  if ! "$TRACKER_CLIENT" state &>/dev/null; then
    echo "[bootstrap] agent-tracker 连接失败，尝试重启..."
    if brew services restart agent-tracker-server &>/dev/null; then
      sleep 2
      if "$TRACKER_CLIENT" state &>/dev/null; then
        echo "[bootstrap] agent-tracker 已恢复"
      else
        echo "[bootstrap] 警告: agent-tracker 仍无法连接，tracker 功能将降级" >&2
      fi
    else
      echo "[bootstrap] 警告: brew services restart 失败，tracker 功能将降级" >&2
    fi
  else
    echo "[bootstrap] agent-tracker 正常"
  fi
fi

# 3. 检查 session 是否已存在
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "[bootstrap] Session ${SESSION} 已存在，跳过创建"
  tmux switch-client -t "${SESSION}:CM" 2>/dev/null || true
  exit 0
fi

# 4. 清理孤儿 worktree（上次 session 异常退出遗留的）
if git -C "$WORKDIR" rev-parse --git-dir &>/dev/null 2>&1; then
  wt -C "$WORKDIR" step prune --yes 2>/dev/null || true
  echo "[bootstrap] wt prune 完成"
fi

# 5. 清理过期临时文件（>24h 的 task/msg/prompt 文件）
find "${TMUXFORALL_TMP}" -name "tmuxforall-task-*" -mtime +1 -delete 2>/dev/null || true
find "${TMUXFORALL_TMP}" -name "tmuxforall-msg-*" -mtime +1 -delete 2>/dev/null || true
find "${TMUXFORALL_TMP}" -name "tmuxforall-prompt-*" -mtime +1 -delete 2>/dev/null || true
find "${TMUXFORALL_TMP}" -name "tmuxforall-mailbox-*" -mtime +1 -delete 2>/dev/null || true
find "${TMUXFORALL_TMP}" -name "pm-output-*" -mtime +1 -delete 2>/dev/null || true

# 6. 创建工作目录
mkdir -p "$WORKDIR"

# 7. 初始化 COMMANDER-BOARD.md
NOW="$(date '+%Y-%m-%d %H:%M')"
if [[ ! -f "$BOARD" ]]; then
  sed \
    -e "s/{project}/${PROJECT}/g" \
    -e "s/{time}/${NOW}/g" \
    -e "s/{MAX_AGENTS}/8/g" \
    -e "s/{BUDGET}/${BUDGET}/g" \
    -e "s/{BUDGET_MIN}/${BUDGET_MIN}/g" \
    -e "s/{BUDGET_MAX}/${BUDGET_MAX}/g" \
    "${SKILL_DIR}/templates/COMMANDER-BOARD.md" > "$BOARD"
  echo "[bootstrap] 已创建 COMMANDER-BOARD.md"
fi

# 8. 复制 on-tmux-window-activate.sh 到工作目录
cp "${SKILL_DIR}/templates/on-tmux-window-activate.sh" \
   "${WORKDIR}/on-tmux-window-activate.sh"
chmod +x "${WORKDIR}/on-tmux-window-activate.sh"

# 9. 创建日志目录
mkdir -p "${TMUXFORALL_LOG_DIR}/${PROJECT}"
mkdir -p "${TMUXFORALL_STATE_DIR}"

# 10. 创建 session（临时初始窗口，后续由 spawn-role.sh 创建 Agent 窗口）
SESSION_ID="$(tmux new-session -d -s "$SESSION" -n "_init" -c "$WORKDIR" -P -F "#{session_id}")"

echo "[bootstrap] Session ${SESSION} (${SESSION_ID}) 已创建"

# 11. 孵化 CM — 传入 session_id 避免 tmux hook 重命名 session 后找不到
echo "[bootstrap] 孵化 CM..."
bash "${SKILL_DIR}/spawn-role.sh" commander "$PROJECT" --workdir "$WORKDIR" --session-id "$SESSION_ID"

# 12. 删除临时初始窗口
tmux kill-window -t "${SESSION_ID}:_init" 2>/dev/null || true

# 13. 调用 session manager（如果存在，同步 session 编号）
SESSION_MGR="${HOME}/.tmux/scripts/session_manager.py"
if [[ -f "$SESSION_MGR" ]]; then
  python3 "$SESSION_MGR" ensure 2>/dev/null || true
  echo "[bootstrap] session manager 已同步"
fi

# 14. 等待5秒让 Agent 启动
echo "[bootstrap] 等待 Agent 初始化 (5s)..."
sleep 5

# 15. 向 CM 发送启动简报
GOAL_SECTION=""
if [[ -n "$GOAL" ]]; then
  GOAL_SECTION="
- **项目目标**: ${GOAL}

目标已明确，请立即执行启动阶段工作循环：读 Board → 分析依赖 → 规划任务拆解 → 孵化 Agent 并行推进。"
else
  GOAL_SECTION="

目标尚未明确。请主动向用户询问项目目标和关键需求，拿到目标后立即开始规划。"
fi

BRIEFING="## 启动简报 — ${PROJECT}

项目已初始化完成。

- **Board 路径**: ${BOARD}
- **工作目录**: ${WORKDIR}
- **PM**: 按需召唤（invoke-pm.sh），不常驻
- **Session**: ${SESSION}
- **资源预算**: N=${BUDGET}，自主范围 [${BUDGET_MIN}, ${BUDGET_MAX}]，超过 ${BUDGET_MAX} 需向用户汇报
${GOAL_SECTION}"

bash "${SKILL_DIR}/send-msg.sh" "${SESSION_ID}:CM" "$BRIEFING" --direct

# 16. 打印操作说明
cat <<EOF

╔══════════════════════════════════════════════════════════╗
║  tmuxforall — ${PROJECT} 已启动                          ║
╠══════════════════════════════════════════════════════════╣
║  Session:    ${SESSION}
║  Board:      ${BOARD}
║  日志目录:   日志目录（见 config.sh）
╠══════════════════════════════════════════════════════════╣
║  快捷键:                                                  ║
║  M-0         → 跳到 CM 窗口                            ║
║  F1~F9       → 按编号跳转 Session                   ║
║  C-a w       → 树形窗口/session列表                      ║
║  prefix d    → 断开当前 session                          ║
╠══════════════════════════════════════════════════════════╣
║  常用命令:                                                ║
║  spawn-role.sh <role> ${PROJECT}    → 孵化新 Agent       ║
║  broadcast.sh ${PROJECT} "消息"    → 广播给所有 Agent    ║
╚══════════════════════════════════════════════════════════╝

切换到 session: tmux switch-client -t ${SESSION}
EOF

# 17. 如果在 tmux 内运行，切到新 session
if [[ -n "${TMUX:-}" ]]; then
  tmux switch-client -t "${SESSION_ID}:CM" 2>/dev/null || true
fi
