#!/bin/bash
# dashboard.sh — 显示 tmuxforall 项目状态概览
# 用法: dashboard.sh <project>
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
PROJECT="${1:-}"
if [[ -z "$PROJECT" ]]; then
  echo "用法: dashboard.sh <project>" >&2
  exit 1
fi

# 兼容 session 重命名（tf-xxx → N-tf-xxx）
source "${SKILL_DIR}/_session_name.sh"
SESSION="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1 || echo "$TF_SESSION")"

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "[dashboard] Session ${TF_SESSION} 不存在（已查找含数字前缀）" >&2
  exit 1
fi

WORKDIR="$(tmux display-message -p -t "${SESSION}:CM" '#{pane_current_path}' 2>/dev/null || \
           tmux display-message -p -t "${SESSION}:" '#{session_path}' 2>/dev/null || echo '?')"
BOARD="${WORKDIR}/COMMANDER-BOARD.md"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  tmuxforall 状态仪表板 — ${PROJECT}"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Session: ${SESSION}"
echo "║  工作目录: ${WORKDIR}"
echo "╠══════════════════════════════════════════════════════════╣"

# 窗口状态
echo "║  [窗口列表]"
tmux list-windows -t "$SESSION" -F '  #W  (#I)' 2>/dev/null | while read -r line; do
  echo "║  ${line}"
done

echo "╠══════════════════════════════════════════════════════════╣"

# 每个窗口最近活动（扫描关键状态词）
echo "║  [最近活动摘要]"
tmux list-windows -t "$SESSION" -F "#W" 2>/dev/null | while read -r win; do
  if [[ "$win" == "CM" ]]; then continue; fi
  RECENT=$(tmux capture-pane -t "${SESSION}:${win}" -p -S -20 2>/dev/null | \
    grep -E '\[DONE\]|\[BLOCKED\]|STATUS|ERROR|error|完成|阻塞|汇报' | \
    tail -3 | tr '\n' ' ' || echo "")
  if [[ -n "$RECENT" ]]; then
    echo "║  ${win}: ${RECENT:0:80}"
  fi
done

echo "╠══════════════════════════════════════════════════════════╣"

# Board 待决策项
if [[ -f "$BOARD" ]]; then
  PENDING=$(grep -c '^- \[ \]' "$BOARD" 2>/dev/null || echo 0)
  STAGE=$(grep -A1 '## 当前阶段' "$BOARD" 2>/dev/null | tail -1 | tr -d '\n')
  echo "║  [Board]"
  echo "║  阶段: ${STAGE:-未设定} | 待决策: ${PENDING} 项"

  # 显示待决策项
  if [[ "$PENDING" -gt 0 ]]; then
    grep '^- \[ \]' "$BOARD" 2>/dev/null | head -5 | while read -r line; do
      echo "║  !! ${line:5:75}"
    done
  fi
fi

echo "╠══════════════════════════════════════════════════════════╣"

# Agent Tracker（实时查询 tracker-server）
TRACKER_CLIENT="$HOME/.config/agent-tracker/bin/tracker-client"
if [[ -x "$TRACKER_CLIENT" ]]; then
  TRACKER_JSON=$("$TRACKER_CLIENT" state --json 2>/dev/null || echo '{}')
  if [[ -n "$TRACKER_JSON" && "$TRACKER_JSON" != "{}" ]]; then
    echo "║  [任务追踪 — Agent Tracker]"
    python3 - "$TRACKER_JSON" <<'PYEOF'
import sys, json
data = json.loads(sys.argv[1])
for t in data.get("tasks", []):
    status = t.get("status", "unknown")
    if status == "active":
        icon = "⏳"
    elif status == "waiting":
        icon = "🔔"
    elif status == "done":
        icon = "✅"
    else:
        icon = "❓"
    summary = t.get("summary", "")[:60]
    pane = t.get("pane", "?")
    print(f"║  {icon} {summary} ({pane})")
PYEOF
  fi
fi

echo "╚══════════════════════════════════════════════════════════╝"
