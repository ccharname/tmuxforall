#!/bin/bash
# config.sh — tmuxforall 可配置路径（所有脚本共享）
# 用户可通过环境变量覆盖默认值

# 技能目录（自动检测，通常无需修改）
SKILL_DIR="${SKILL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# 日志目录（Agent 输出日志）
TMUXFORALL_LOG_DIR="${TMUXFORALL_LOG_DIR:-${HOME}/.local/share/tmuxforall/logs}"

# Check-in 状态目录
TMUXFORALL_STATE_DIR="${TMUXFORALL_STATE_DIR:-${HOME}/.local/share/tmuxforall/checkins}"

# 临时文件目录（邮箱、prompt、task 文件）
TMUXFORALL_TMP="${TMUXFORALL_TMP:-${TMPDIR:-/tmp}}"

# Claude CLI 命令
# 默认使用 claude（标准 Claude Code CLI）
# 如需跳过权限确认，可设为 "claude --dangerously-skip-permissions"
TMUXFORALL_CLAUDE_CMD="${TMUXFORALL_CLAUDE_CMD:-claude}"
