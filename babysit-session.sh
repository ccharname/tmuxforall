#!/bin/bash
# babysit-session.sh — 会话健康巡检 + 自动修复
# 用法: babysit-session.sh <project> [--fix]
#
# 检查项:
#   1. CM 是否存在 + 是否有角色提示（vs bare claude）
#   2. CM 是否在做不该做的事（写代码/跑测试）
#   3. 各 Agent 存活状态（alive_idle / alive_busy / dead）
#   4. Board 与实际状态是否一致
#   5. Worktree 未提交改动
#
# --fix: 自动修复可修复项（重建CM、重启无角色CM）
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"

PROJECT="${1:-}"
FIX_MODE=false

if [[ -z "$PROJECT" ]]; then
  echo "用法: babysit-session.sh <project> [--fix]" >&2
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix) FIX_MODE=true; shift ;;
    *)     shift ;;
  esac
done

# 动态查找 session
source "${SKILL_DIR}/_session_name.sh"
SESSION="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1 || echo "")"

if [[ -z "$SESSION" ]]; then
  echo "❌ 会话 ${TF_SESSION} 不存在"
  exit 1
fi

echo "🔍 巡检会话: ${SESSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ISSUES=0
FIXES=0

# === 0. 推断项目目录（从任意存活窗口获取，或常见位置） ===
PROJECT_DIR=""
WINDOWS=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null || echo "")

for w in $WINDOWS; do
  candidate=$(tmux display-message -p -t "${SESSION}:${w}" '#{pane_current_path}' 2>/dev/null || echo "")
  # 去掉 worktree 子路径，找到根目录
  root="${candidate%%/worktrees/*}"
  # 去掉 .feature-* 后缀（worktree 目录名）
  root="${root%%.feature-*}"
  if [[ -n "$root" && -d "$root" ]]; then
    PROJECT_DIR="$root"
    break
  fi
done

# fallback: 常见位置
if [[ -z "$PROJECT_DIR" ]]; then
  for loc in "$HOME/Developer/${PROJECT}" "$HOME/projects/${PROJECT}" "$HOME/${PROJECT}"; do
    if [[ -d "$loc" ]]; then
      PROJECT_DIR="$loc"
      break
    fi
  done
fi

echo ""
echo "📁 项目目录: ${PROJECT_DIR:-未找到}"

# === 1. 获取所有窗口 ===
echo "📋 窗口列表: $(echo $WINDOWS | tr '\n' ' ')"

# === 2. 检查 CM ===
echo ""
echo "▸ CM 角色检查"
CM_WIN=""
for w in $WINDOWS; do
  if [[ "$w" == "CM" || "$w" == "司令" ]]; then
    CM_WIN="$w"
    break
  fi
done

if [[ -z "$CM_WIN" ]]; then
  echo "  ❌ CM 窗口不存在"
  ISSUES=$((ISSUES + 1))
  if $FIX_MODE && [[ -n "$PROJECT_DIR" ]]; then
    echo "  🔧 正在重建 CM..."
    bash "${SKILL_DIR}/spawn-role.sh" commander "$PROJECT" --workdir "$PROJECT_DIR" 2>&1 | sed 's/^/  /'
    FIXES=$((FIXES + 1))
    # 刷新窗口列表
    WINDOWS=$(tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null || echo "")
    CM_WIN="CM"
  fi
else
  CM_OUTPUT=$(tmux capture-pane -t "${SESSION}:${CM_WIN}" -p -S -30 2>/dev/null || echo "")

  # === 判断 CM 是否 busy（非 idle） ===
  CM_IS_BUSY=false
  if ! echo "$CM_OUTPUT" | grep -qE '^❯\s*$'; then
    CM_IS_BUSY=true
  fi

  # === 角色检测：三层判断 ===
  # 第一层：prompt 文件是否存在（最可靠，spawn-role/restart-agent 生成）
  CM_HAS_PROMPT=false
  if ls ${TMUXFORALL_TMP}/tmuxforall-prompt-*-CM-*.txt ${TMUXFORALL_TMP}/tmuxforall-prompt-CM-*.txt &>/dev/null 2>&1; then
    CM_HAS_PROMPT=true
  fi

  # 第二层：pane 输出关键词（辅助判断，可能因滚屏而漏检）
  CM_HAS_KEYWORDS=false
  if echo "$CM_OUTPUT" | grep -q "COMMANDER-BOARD\|指挥板\|Commander\|三层执行\|spawn-role\|dispatch-task"; then
    CM_HAS_KEYWORDS=true
  fi

  if $CM_HAS_PROMPT || $CM_HAS_KEYWORDS; then
    echo "  ✅ CM 有角色意识${CM_HAS_PROMPT:+ (prompt文件存在)}${CM_HAS_KEYWORDS:+ (关键词匹配)}"
  else
    if $CM_IS_BUSY; then
      # CM 正在工作但无法确认角色 — 只警告，绝不重启
      echo "  ⚠️  CM 无角色特征但正在工作中 — 跳过重启（避免误杀）"
      echo "  💡 如确认是bare claude，请先等 CM idle 后再 --fix，或手动: restart-agent.sh ${SESSION}:CM $PROJECT"
      ISSUES=$((ISSUES + 1))
    else
      # CM idle 且无角色特征 — 大概率是bare claude
      echo "  ❌ CM 可能是bare claude（idle + 无 prompt 文件 + 无角色关键词）"
      ISSUES=$((ISSUES + 1))
      if $FIX_MODE; then
        echo "  🔧 正在重启 CM..."
        bash "${SKILL_DIR}/restart-agent.sh" "${SESSION}:${CM_WIN}" "$PROJECT" 2>&1 | sed 's/^/  /'
        FIXES=$((FIXES + 1))
      fi
    fi
  fi

  # 检查 CM 是否在写代码
  if echo "$CM_OUTPUT" | grep -qE '(Edit|Write)\(|vim |nano |code '; then
    echo "  ⚠️  CM 疑似在写代码（违反 Commander 铁律）"
    ISSUES=$((ISSUES + 1))
  else
    echo "  ✅ CM 未在写代码"
  fi
fi

# === 3. 各 Agent 健康状态 ===
echo ""
echo "▸ Agent 健康检查"

AGENT_COUNT=0
IDLE_AGENTS=""
for w in $WINDOWS; do
  [[ "$w" == "$CM_WIN" ]] && continue

  PANE_OUTPUT=$(tmux capture-pane -t "${SESSION}:${w}" -p -S -5 2>/dev/null || echo "__DEAD__")

  if [[ "$PANE_OUTPUT" == "__DEAD__" ]]; then
    STATUS="💀 dead"
    ISSUES=$((ISSUES + 1))
  elif echo "$PANE_OUTPUT" | grep -qE '^❯\s*$'; then
    STATUS="💤 idle"
    IDLE_AGENTS="${IDLE_AGENTS} ${w}"
  elif echo "$PANE_OUTPUT" | grep -q "Noodling\|Sautéing\|Baking\|thinking\|Running"; then
    STATUS="🔄 busy"
  elif echo "$PANE_OUTPUT" | grep -qE '(timeout|TIMEOUT)'; then
    STATUS="⏰ timeout"
    ISSUES=$((ISSUES + 1))
  else
    STATUS="🔄 active"
  fi

  echo "  ${w}: ${STATUS}"
  AGENT_COUNT=$((AGENT_COUNT + 1))
done

if [[ $AGENT_COUNT -eq 0 ]]; then
  echo "  (无 Agent 窗口)"
fi

if [[ -n "$IDLE_AGENTS" ]]; then
  echo "  💡 空闲 Agent:${IDLE_AGENTS}"
fi

# === 4. Board 一致性检查 ===
echo ""
echo "▸ Board 一致性"

BOARD_FILE=""
if [[ -n "$PROJECT_DIR" ]]; then
  for candidate in "${PROJECT_DIR}/COMMANDER-BOARD.md" "${PROJECT_DIR}/docs/COMMANDER.md"; do
    if [[ -f "$candidate" ]]; then
      BOARD_FILE="$candidate"
      break
    fi
  done
fi

if [[ -z "$BOARD_FILE" ]]; then
  echo "  ⚠️  未找到 Board 文件"
  ISSUES=$((ISSUES + 1))
else
  # 检查 Board 中标记为"执行中"但窗口已消失或已 idle 的 agent
  BOARD_ACTIVE=$(grep -E '🟡|执行中|busy' "$BOARD_FILE" 2>/dev/null | grep -oE '\b(BE|FE|QA|RS|PM|BE2|FE2|BE3|FE3)[0-9]*\b' || echo "")
  for agent in $BOARD_ACTIVE; do
    if ! echo "$WINDOWS" | grep -qx "$agent"; then
      echo "  ❌ Board 标记 ${agent} 为执行中，但窗口已不存在"
      ISSUES=$((ISSUES + 1))
    elif tmux capture-pane -t "${SESSION}:${agent}" -p -S -3 2>/dev/null | grep -qE '^❯\s*$'; then
      echo "  ⚠️  Board 标记 ${agent} 为执行中，但实际已 idle"
      ISSUES=$((ISSUES + 1))
    fi
  done

  BOARD_TIME=$(grep -oE '更新时间: [0-9-]+ [0-9:]+' "$BOARD_FILE" 2>/dev/null || echo "未知")
  echo "  📄 ${BOARD_FILE}"
  echo "  🕐 ${BOARD_TIME}"
fi

# === 5. Worktree 检查 ===
echo ""
echo "▸ Worktree 检查"

WORKTREE_DIR="${PROJECT_DIR}/worktrees"
if [[ -n "$PROJECT_DIR" && -d "$WORKTREE_DIR" ]]; then
  for wt_dir in "${WORKTREE_DIR}"/*/; do
    [[ -d "$wt_dir" ]] || continue
    wt_name=$(basename "$wt_dir")
    uncommitted=$(cd "$wt_dir" && git diff --stat 2>/dev/null | tail -1 || echo "")
    untracked=$(cd "$wt_dir" && git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    if [[ -n "$uncommitted" || "$untracked" -gt 0 ]]; then
      echo "  ⚠️  ${wt_name}: ${uncommitted:+未提交: $uncommitted}${untracked:+ 未跟踪: ${untracked}个}"
    else
      echo "  ✅ ${wt_name}: 干净"
    fi
  done
else
  echo "  (无 worktree 目录)"
fi

# === 汇总 ===
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $ISSUES -eq 0 ]]; then
  echo "✅ 巡检通过，无异常"
else
  echo "⚠️  发现 ${ISSUES} 个问题"
  if $FIX_MODE; then
    echo "🔧 已自动修复 ${FIXES} 个"
    [[ $((ISSUES - FIXES)) -gt 0 ]] && echo "📌 剩余 $((ISSUES - FIXES)) 个需人工处理"
  else
    echo "💡 加 --fix 自动修复可修复项"
  fi
fi
