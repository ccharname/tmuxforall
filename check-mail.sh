#!/bin/bash
# check-mail.sh — 查收并清空邮箱
# 用法: check-mail.sh <窗口名> [session名]
# session名 用于邮箱隔离（防止多项目串台）。
# 如不提供 session，自动检测当前 tmux session。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

WINDOW_NAME="${1:-}"
SESSION_NAME="${2:-}"

if [[ -z "$WINDOW_NAME" ]]; then
  echo "用法: check-mail.sh <窗口名> [session名]" >&2
  exit 1
fi

# 自动检测 session（agent 在 tmux 内调用时）
if [[ -z "$SESSION_NAME" ]]; then
  SESSION_NAME="$(tmux display-message -p '#{session_name}' 2>/dev/null || echo '')"
fi

# 优先尝试带 session 前缀的邮箱（新格式）
MAILBOX="${TMUXFORALL_TMP}/tmuxforall-mailbox-${SESSION_NAME}-${WINDOW_NAME}.txt"

# 兼容：如果新格式邮箱不存在但旧格式存在，读旧格式（过渡期）
OLD_MAILBOX="${TMUXFORALL_TMP}/tmuxforall-mailbox-${WINDOW_NAME}.txt"
if [[ ! -f "$MAILBOX" || ! -s "$MAILBOX" ]] && [[ -f "$OLD_MAILBOX" && -s "$OLD_MAILBOX" ]]; then
  MAILBOX="$OLD_MAILBOX"
fi

if [[ -f "$MAILBOX" && -s "$MAILBOX" ]]; then
  cat "$MAILBOX"
  # 清空而非删除，避免与 send-msg.sh 并发写入时丢消息
  : > "$MAILBOX"
else
  echo "（无新邮件）"
fi
