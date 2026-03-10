#!/bin/bash
# on-tmux-window-activate.sh — 放在项目根目录
# 切换到任意 Agent 窗口时自动触发，显示 Board 状态摘要

BOARD="$(dirname "$0")/COMMANDER-BOARD.md"

if [[ ! -f "$BOARD" ]]; then
  exit 0
fi

# 统计活跃 Agent 数（注册记录行数）
active=$(grep -c '^\[注册\]' "$BOARD" 2>/dev/null || echo 0)
# 统计待决策项
pending=$(grep -c '^\- \[ \]' "$BOARD" 2>/dev/null || echo 0)
# 获取当前阶段
stage=$(grep -A1 '## 当前阶段' "$BOARD" 2>/dev/null | tail -1 | tr -d '\n')

tmux display-message "Board | 阶段: ${stage:-?} | Agent: ${active} | 待决策: ${pending}"
