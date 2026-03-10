#!/bin/bash
# dispatch-task.sh — 向 Agent 派发任务（任务文件模式）
# 用法:
#   dispatch-task.sh <session:window> "任务标题" "验收标准1" "验收标准2" ...
#   dispatch-task.sh <session:window> --file /path/to/task.md
#
# 原理：任务内容写入文件，只向 Agent 粘贴一行 cat 指令。
# 优势：
#   - 短命令粘贴可靠（无转义问题）
#   - 任务持久化，Agent compact 后可反复 cat 回看
#   - 不怕 claude 还没启动完时就粘贴
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
  echo "用法: dispatch-task.sh <session:window> \"任务标题\" \"验收标准1\" ..." >&2
  echo "      dispatch-task.sh <session:window> --file /path/to/task.md" >&2
  exit 1
fi
shift

# 解析参数
TASK_FILE=""
TITLE=""
CRITERIA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      TASK_FILE="$2"
      shift 2
      ;;
    *)
      if [[ -z "$TITLE" ]]; then
        TITLE="$1"
      else
        CRITERIA+=("$1")
      fi
      shift
      ;;
  esac
done

# 提取 session 和窗口名（session 隔离，防止多项目串台）
SESSION_NAME="${TARGET%%:*}"
WINDOW_NAME="${TARGET##*:}"
TIMESTAMP="$(date +%H%M%S)"
TASK_PATH="${TMUXFORALL_TMP}/tmuxforall-task-${SESSION_NAME}-${WINDOW_NAME}-${TIMESTAMP}.md"

if [[ -n "$TASK_FILE" ]]; then
  # --file 模式：复制用户指定的文件
  cp "$TASK_FILE" "$TASK_PATH"
else
  # 内联模式：用参数生成任务文件
  if [[ -z "$TITLE" ]]; then
    echo "[dispatch-task] 需要任务标题或 --file 参数" >&2
    exit 1
  fi

  {
    echo "# TASK [CM→${WINDOW_NAME}] $(date +%H:%M)"
    echo ""
    echo "## 任务"
    echo "$TITLE"
    echo ""
    if [[ ${#CRITERIA[@]} -gt 0 ]]; then
      echo "## 验收标准"
      for c in "${CRITERIA[@]}"; do
        echo "- $c"
      done
      echo ""
    fi
    echo "## 完成后"
    echo "用 report-up.sh 汇报摘要，然后 check-mail.sh 查收是否有后续任务。"
  } > "$TASK_PATH"
fi

# 等待目标就绪（最多 15 秒）
READY=0
for i in $(seq 1 30); do
  LAST_LINES=$(tmux capture-pane -t "$TARGET" -p -S -5 2>/dev/null || echo "")
  if echo "$LAST_LINES" | grep -qE '^❯'; then
    READY=1
    break
  fi
  sleep 0.5
done

if [[ "$READY" == "1" ]]; then
  # 发送 cat 命令让 Agent 读取任务（Escape 清除自动补全 → Enter 提交）
  tmux send-keys -t "$TARGET" "cat ${TASK_PATH}"
  sleep 0.3
  tmux send-keys -t "$TARGET" Escape
  sleep 0.1
  tmux send-keys -t "$TARGET" Enter
else
  # 目标未就绪，fallback 到邮箱模式（任务不丢失）
  bash "${SKILL_DIR}/send-msg.sh" "$TARGET" "📋 新任务已派发，请读取: cat ${TASK_PATH}"
  echo "[dispatch-task] [warn] 目标 ${TARGET} 未就绪，已 fallback 到邮箱模式" >&2
fi

# Agent Tracker: 标记任务开始
TRACKER_CLIENT="$HOME/.config/agent-tracker/bin/tracker-client"
if [[ -x "$TRACKER_CLIENT" ]]; then
  T_SID="$(tmux display-message -p -t "$TARGET" '#{session_id}' 2>/dev/null || true)"
  T_WID="$(tmux display-message -p -t "$TARGET" '#{window_id}' 2>/dev/null || true)"
  T_PID="$(tmux display-message -p -t "$TARGET" '#{pane_id}' 2>/dev/null || true)"
  if [[ -n "$T_SID" && -n "$T_WID" && -n "$T_PID" ]]; then
    "$TRACKER_CLIENT" command start_task \
      --session-id "$T_SID" --window-id "$T_WID" --pane "$T_PID" \
      --summary "[${WINDOW_NAME}] ${TITLE:-task}" 2>/dev/null || true
  fi
fi

echo "[dispatch-task] 任务已写入 ${TASK_PATH}，指令已发送到 ${TARGET}"
