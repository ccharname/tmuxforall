#!/bin/bash
# broadcast.sh — 向 session 所有非 CM 窗口广播消息
# 用法: broadcast.sh <project> "<消息>"
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
PROJECT="${1:-}"
MESSAGE="${2:-}"

if [[ -z "$PROJECT" || -z "$MESSAGE" ]]; then
  echo "用法: broadcast.sh <project> \"<消息>\"" >&2
  exit 1
fi

source "${SKILL_DIR}/_session_name.sh"
SESSION="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1 || echo "$TF_SESSION")"
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "[broadcast] Session ${TF_SESSION} 不存在（已查找含数字前缀）" >&2
  exit 1
fi

COUNT=0
while IFS= read -r win; do
  if [[ "$win" == "CM" ]]; then continue; fi
  bash "${SKILL_DIR}/send-msg.sh" "${SESSION}:${win}" "## 广播 [CM→全体] $(date +%H:%M)

${MESSAGE}" && COUNT=$((COUNT + 1))
done < <(tmux list-windows -t "$SESSION" -F "#{window_name}" 2>/dev/null)

echo "[broadcast] 已发送给 ${COUNT} 个窗口"
