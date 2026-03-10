#!/bin/bash
# register-agent.sh — 注册子 Agent 到 COMMANDER-BOARD.md + tracker-cache.json
# 用法: register-agent.sh <parent-window> <child-window> "<task>" <project>
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
PARENT_WIN="${1:-}"
CHILD_WIN="${2:-}"
TASK="${3:-}"
PROJECT="${4:-}"

if [[ -z "$PARENT_WIN" || -z "$CHILD_WIN" || -z "$PROJECT" ]]; then
  echo "用法: register-agent.sh <parent-window> <child-window> \"<task>\" <project>" >&2
  exit 1
fi

# 动态查找 session（兼容 session 重命名为 N-tf-xxx）
source "${SKILL_DIR}/_session_name.sh"
SESSION="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1 || echo "$TF_SESSION")"
WORKDIR="$(tmux display-message -p -t "${SESSION}:" '#{session_path}' 2>/dev/null || pwd)"
BOARD="${WORKDIR}/COMMANDER-BOARD.md"
TRACKER="${TMUXFORALL_TMP}/tmux-tracker-cache.json"
NOW="$(date +%H:%M)"

# 1. 写入 COMMANDER-BOARD.md Agent树区域
if [[ -f "$BOARD" ]]; then
  ENTRY="[注册] ${CHILD_WIN} ← ${PARENT_WIN} | 任务: ${TASK} | 时间: ${NOW}"
  # 插入到 <!-- register-agent.sh 自动追加 --> 注释之前，无标记则追加到文件末尾
  python3 - <<PYEOF
import re
with open('${BOARD}', 'r') as f:
    content = f.read()
entry = "${ENTRY}"
marker = "<!-- register-agent.sh 自动追加 -->"
if marker in content:
    content = content.replace(marker, entry + "\n" + marker)
else:
    content = content.rstrip('\n') + '\n\n' + entry + '\n'
with open('${BOARD}', 'w') as f:
    f.write(content)
PYEOF
fi

# 2. 更新 tracker-cache.json
CHILD_WIN_ID="$(tmux display-message -p -t "${SESSION}:${CHILD_WIN}" '#{window_id}' 2>/dev/null || echo '')"
if [[ -n "$CHILD_WIN_ID" ]]; then
  if [[ -f "$TRACKER" ]]; then
    python3 - <<PYEOF
import json, os
tracker = '${TRACKER}'
try:
    with open(tracker) as f:
        data = json.load(f)
except:
    data = {"tasks": []}
# 去重
data["tasks"] = [t for t in data.get("tasks", []) if t.get("window_id") != "${CHILD_WIN_ID}"]
data["tasks"].append({
    "window_id": "${CHILD_WIN_ID}",
    "window_name": "${CHILD_WIN}",
    "status": "in_progress",
    "task": "${TASK}",
    "parent": "${PARENT_WIN}",
    "project": "${PROJECT}",
    "started": "${NOW}"
})
with open(tracker, 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PYEOF
  else
    python3 -c "
import json
data = {'tasks': [{'window_id': '${CHILD_WIN_ID}', 'window_name': '${CHILD_WIN}', 'status': 'in_progress', 'task': '${TASK}', 'parent': '${PARENT_WIN}', 'project': '${PROJECT}', 'started': '${NOW}'}]}
with open('${TRACKER}', 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
"
  fi
fi

# 3. 设置 parent 窗口 @watching 1
PARENT_WIN_ID="$(tmux display-message -p -t "${SESSION}:${PARENT_WIN}" '#{window_id}' 2>/dev/null || echo '')"
if [[ -n "$PARENT_WIN_ID" ]]; then
  tmux set-option -t "${SESSION}:${PARENT_WIN}" @watching 1 2>/dev/null || true
fi

echo "[register-agent] ${CHILD_WIN} 已注册 (parent: ${PARENT_WIN})"
