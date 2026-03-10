#!/bin/bash
# restart-agent.sh — 轻量重启卡死的 Agent（保留窗口位，重建 claude 进程）
# 用法: restart-agent.sh <session:window> <project> [--timeout <分钟>]
#
# 借鉴 tmux respawn-pane 思路：不 kill-window + spawn-role，
# 而是在原窗口直接重启 claude，保留窗口编号和日志。
# 适用场景：Agent thinking 卡死、ctx 耗尽无响应、403 token 错误。
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
TARGET="${1:-}"
PROJECT="${2:-}"
TIMEOUT_MIN=""

if [[ -z "$TARGET" || -z "$PROJECT" ]]; then
  echo "用法: restart-agent.sh <session:window> <project> [--timeout <分钟>]" >&2
  exit 1
fi

shift 2 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT_MIN="$2"; shift 2 ;;
    *)         shift ;;
  esac
done

source "${SKILL_DIR}/_session_name.sh"
WINDOW_NAME="${TARGET##*:}"
SESSION="${TARGET%%:*}"

# 检查窗口是否存在
if ! tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
  echo "[restart-agent] 窗口 ${TARGET} 不存在" >&2
  exit 1
fi

# 获取当前工作目录（从 pane）和主仓库路径
AGENT_WORKDIR=$(tmux display-message -p -t "$TARGET" '#{pane_current_path}' 2>/dev/null || pwd)
# 推导主仓库路径（用于 worktree 清理）
if [[ "$AGENT_WORKDIR" == */worktrees/* ]]; then
  MAIN_WORKDIR="$(git -C "$AGENT_WORKDIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')"
else
  MAIN_WORKDIR="$AGENT_WORKDIR"
fi

# 查找该窗口的 prompt 文件（优先 session+窗口名精确匹配，取最新的）
PROMPT_FILE=$(ls -t ${TMUXFORALL_TMP}/tmuxforall-prompt-${SESSION}-${WINDOW_NAME}-*.txt 2>/dev/null | head -1 || echo "")
# fallback: 旧格式（无 session 前缀）
if [[ -z "$PROMPT_FILE" || ! -f "$PROMPT_FILE" ]]; then
  PROMPT_FILE=$(ls -t ${TMUXFORALL_TMP}/tmuxforall-prompt-${WINDOW_NAME}-*.txt 2>/dev/null | head -1 || echo "")
fi
# fallback: 任意 prompt 文件
if [[ -z "$PROMPT_FILE" || ! -f "$PROMPT_FILE" ]]; then
  PROMPT_FILE=$(ls -t ${TMUXFORALL_TMP}/tmuxforall-prompt-*.txt 2>/dev/null | head -1 || echo "")
fi

# 发 esc 打断当前操作，等一下
tmux send-keys -t "$TARGET" Escape 2>/dev/null || true
sleep 1

# 构建退出时 worktree 清理命令
CLEANUP_CMD=""
if [[ "$AGENT_WORKDIR" != "$MAIN_WORKDIR" && "$AGENT_WORKDIR" == */worktrees/* ]]; then
  if command -v wt &>/dev/null; then
    CLEANUP_CMD="cd '${MAIN_WORKDIR}' && wt remove 'feature/${WINDOW_NAME}' 2>/dev/null; "
  else
    CLEANUP_CMD="git -C '${MAIN_WORKDIR}' worktree remove '${AGENT_WORKDIR}' --force 2>/dev/null; git -C '${MAIN_WORKDIR}' branch -d 'feature/${WINDOW_NAME}' 2>/dev/null; "
  fi
fi

# 用 respawn-pane 重启（-k 杀掉当前进程，保留窗口位）
if [[ -n "$PROMPT_FILE" && -f "$PROMPT_FILE" ]]; then
  # 有 prompt 文件，用 system-prompt 重启
  tmux respawn-pane -k -t "$TARGET" -c "$AGENT_WORKDIR" \
    "${TMUXFORALL_CLAUDE_CMD} --system-prompt \"\$(cat '${PROMPT_FILE}')\" ; ${CLEANUP_CMD}tmux kill-window"
else
  # 无 prompt 文件，裸启动
  tmux respawn-pane -k -t "$TARGET" -c "$AGENT_WORKDIR" \
    "${TMUXFORALL_CLAUDE_CMD} ; ${CLEANUP_CMD}tmux kill-window"
fi

# 重新开启日志
LOG_DIR="${TMUXFORALL_LOG_DIR}/${PROJECT}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/${WINDOW_NAME}-$(date +%Y%m%d).log"
tmux pipe-pane -t "$TARGET" "cat >> '${LOG_FILE}'"

# --timeout 安全网
if [[ -n "$TIMEOUT_MIN" ]]; then
  TIMEOUT_SEC=$((TIMEOUT_MIN * 60))
  nohup bash -c "
    sleep ${TIMEOUT_SEC}
    if tmux list-windows -t '${SESSION}' -F '#{window_name}' 2>/dev/null | grep -qx '${WINDOW_NAME}'; then
      bash '${SKILL_DIR}/send-msg.sh' '${SESSION}:CM' \
        '[TIMEOUT] ${WINDOW_NAME} 重启后仍超时 ${TIMEOUT_MIN}min，自动终止'
      tmux send-keys -t '${TARGET}' Escape 2>/dev/null || true
      sleep 2
      tmux kill-window -t '${TARGET}' 2>/dev/null || true
    fi
  " > /dev/null 2>&1 &
fi

echo "[restart-agent] ${WINDOW_NAME} 已在原窗口重启 (workdir: ${AGENT_WORKDIR})"
