#!/bin/bash
# send-msg.sh — 向 tmux 窗口发送消息（邮箱模式 + bell 通知）
# 用法: send-msg.sh <session:window> "消息内容" [--file /path] [--direct]
#
# 默认行为：消息写入邮箱文件 + bell 通知目标窗口。
# 目标 Agent 在准备好时主动读邮箱（check-mail.sh）。
# --direct 强制直接粘贴（仅用于 CM 主动派发任务等场景）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

TARGET="${1:-}"
MESSAGE="${2:-}"
FILE_ARG=""
DIRECT=0

if [[ -z "$TARGET" ]]; then
  echo "用法: send-msg.sh <session:window> \"消息\" [--file /path] [--direct]" >&2
  exit 1
fi

shift 2 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)   FILE_ARG="$2"; shift 2 ;;
    --direct) DIRECT=1; shift ;;
    *)        shift ;;
  esac
done

# --file 模式：读取文件内容作为消息发送
if [[ -n "$FILE_ARG" ]]; then
  MESSAGE="$(cat "$FILE_ARG")"
fi

# 提取 session 和窗口名用于邮箱路径（session 隔离，防止多项目串台）
SESSION_NAME="${TARGET%%:*}"
WINDOW_NAME="${TARGET##*:}"

# --direct 模式：检测空闲后直接粘贴（CM 主动派发任务用）
if [[ "$DIRECT" == "1" ]]; then
  LAST_LINES=$(tmux capture-pane -t "$TARGET" -p -S -5 2>/dev/null || echo "")
  IS_IDLE=0
  if echo "$LAST_LINES" | grep -qE '^❯'; then
    IS_IDLE=1
  fi

  if [[ "$IS_IDLE" == "0" ]]; then
    # 即使 --direct 也不打断正在忙碌的目标
    MAILBOX="${TMUXFORALL_TMP}/tmuxforall-mailbox-${SESSION_NAME}-${WINDOW_NAME}.txt"
    TIMESTAMP="$(date '+%H:%M:%S')"
    {
      echo "--- [${TIMESTAMP}] ---"
      echo "$MESSAGE"
      echo ""
    } >> "$MAILBOX"
    # bell: 写入目标 pane 的 tty 触发 tmux bell 检测
    TARGET_TTY="$(tmux display-message -p -t "$TARGET" '#{pane_tty}' 2>/dev/null || echo '')"
    [[ -n "$TARGET_TTY" && -w "$TARGET_TTY" ]] && printf '\a' > "$TARGET_TTY"
    echo "[send-msg] 目标 ${TARGET} 正忙，消息已写入邮箱 ${MAILBOX}" >&2
    exit 0
  fi

  # 直接发送
  MSG_LEN=${#MESSAGE}
  HAS_SPECIAL=0
  [[ "$MESSAGE" == *'`'* || "$MESSAGE" == *'$'* || "$MESSAGE" == *'\\'* || "$MESSAGE" == *'"'* ]] && HAS_SPECIAL=1

  if [[ $MSG_LEN -le 200 && "$HAS_SPECIAL" == "0" ]]; then
    tmux send-keys -t "$TARGET" -l "$MESSAGE"
  else
    TMP_FILE="${TMUXFORALL_TMP}/tmuxforall-msg-$$.txt"
    printf '%s' "$MESSAGE" > "$TMP_FILE"
    BUF_NAME="tmuxforall_$$"
    tmux load-buffer -b "$BUF_NAME" "$TMP_FILE"
    tmux paste-buffer -t "$TARGET" -b "$BUF_NAME" -d
    rm -f "$TMP_FILE"
  fi
  # Escape 清除自动补全 → Enter 提交（Ink TUI 兼容）
  sleep 0.3
  tmux send-keys -t "$TARGET" Escape
  sleep 0.1
  tmux send-keys -t "$TARGET" Enter
  echo "[send-msg] 已直接发送到 ${TARGET}" >&2
  exit 0
fi

# 默认模式：写入邮箱 + bell 通知
MAILBOX="${TMUXFORALL_TMP}/tmuxforall-mailbox-${SESSION_NAME}-${WINDOW_NAME}.txt"
TIMESTAMP="$(date '+%H:%M:%S')"
{
  echo "--- [${TIMESTAMP}] ---"
  echo "$MESSAGE"
  echo ""
} >> "$MAILBOX"

# bell 通知目标窗口（写入 pane tty 触发 tmux bell 检测，状态栏高亮）
TARGET_TTY="$(tmux display-message -p -t "$TARGET" '#{pane_tty}' 2>/dev/null || echo '')"
[[ -n "$TARGET_TTY" && -w "$TARGET_TTY" ]] && printf '\a' > "$TARGET_TTY"

echo "[send-msg] 消息已写入邮箱 ${MAILBOX}，已 bell 通知 ${TARGET}" >&2
