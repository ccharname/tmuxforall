#!/bin/bash
# live-board.sh — 实时状态采集，替代被动 cat Board
# 用法: live-board.sh <project> [--interval 10]
# 每 N 秒扫描所有窗口，提取实时状态，直接显示
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
PROJECT="${1:-}"
INTERVAL=10

if [[ -z "$PROJECT" ]]; then
  echo "用法: live-board.sh <project> [--interval N]" >&2
  exit 1
fi

shift 1 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

source "${SKILL_DIR}/_session_name.sh"

# 兼容 session 重命名
find_session() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | \
    grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1 || echo "$TF_SESSION"
}

# 从 pane 抓取状态关键词
extract_status() {
  local target="$1"
  local lines
  lines=$(tmux capture-pane -t "$target" -p -S -8 2>/dev/null || echo "")

  # 检测上下文剩余
  local ctx=$(echo "$lines" | grep -oE 'Context left[^%]*%|auto-compact: [0-9]+%' | tail -1 | grep -oE '[0-9]+%' || echo "")

  # 检测活动状态
  local activity=""
  if echo "$lines" | grep -qE '✻|✳|✶|⏺'; then
    # 正在工作
    local verb=$(echo "$lines" | grep -oE '(Compacting|Sautéed|Baked|Cooked|Crafting|Pollinating|Nesting|Churned|Crunched)' | tail -1 || echo "")
    if [[ "$verb" == "Compacting" ]]; then
      activity="🔄压缩中"
    elif [[ -n "$verb" ]]; then
      activity="⚡工作中"
    else
      activity="⚡工作中"
    fi
  elif echo "$lines" | grep -qE '^❯\s*$'; then
    activity="💤空闲"
  elif echo "$lines" | grep -qE 'Running.*timeout'; then
    activity="⏳长任务"
  else
    activity="❓未知"
  fi

  # 检测最近关键事件
  local event=$(echo "$lines" | grep -oE '\[DONE\]|\[BLOCKED\]|ERROR|error|完成|阻塞|PASS|FAIL|failed|commit [a-f0-9]{7}' | tail -1 || echo "")

  # 检测 bash 后台任务
  local bg=""
  if echo "$lines" | grep -qE 'bash|Running'; then
    bg=$(echo "$lines" | grep -oE '1 bash|[0-9]+ bash' | tail -1 || echo "")
  fi

  echo "${activity}${ctx:+ ctx:$ctx}${event:+ [$event]}${bg:+ ($bg)}"
}

# 主循环
while true; do
  clear
  SESSION=$(find_session)

  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Session ${TF_SESSION} 不存在"
    sleep "$INTERVAL"
    continue
  fi

  WORKDIR=$(tmux display-message -p -t "${SESSION}:CM" '#{pane_current_path}' 2>/dev/null || echo "?")
  BOARD="${WORKDIR}/COMMANDER-BOARD.md"
  NOW=$(date '+%H:%M:%S')
  BOARD_AGE=""
  if [[ -f "$BOARD" ]]; then
    BOARD_MOD=$(stat -f '%m' "$BOARD" 2>/dev/null || echo 0)
    NOW_TS=$(date +%s)
    AGE_MIN=$(( (NOW_TS - BOARD_MOD) / 60 ))
    if [[ $AGE_MIN -gt 30 ]]; then
      BOARD_AGE="⚠️ ${AGE_MIN}分钟前"
    elif [[ $AGE_MIN -gt 5 ]]; then
      BOARD_AGE="${AGE_MIN}分钟前"
    else
      BOARD_AGE="刚更新"
    fi
  fi

  # 读取 Board 关键信息
  STAGE=""
  PENDING=0
  if [[ -f "$BOARD" ]]; then
    STAGE=$(grep -A1 '## 当前阶段' "$BOARD" 2>/dev/null | tail -1 | sed 's/^[*[:space:]]*//' | head -c 60)
    PENDING=$(grep -c '^\- \[ \]' "$BOARD" 2>/dev/null || echo "0")
    PENDING="${PENDING//[^0-9]/}"
    PENDING="${PENDING:-0}"
  fi

  echo "══════════════════════════════════════════════════════"
  echo "  ${PROJECT} 实时状态  ${NOW}  Board:${BOARD_AGE:-?}"
  echo "  阶段: ${STAGE:-未设定}"
  [[ $PENDING -gt 0 ]] && echo "  ⚠ 待决策: ${PENDING} 项"
  echo "══════════════════════════════════════════════════════"
  printf "%-12s %-18s\n" "窗口" "状态"
  echo "──────────────────────────────────────────────────────"

  tmux list-windows -t "$SESSION" -F "#W" 2>/dev/null | while read -r win; do
    if [[ "$win" == "CM" ]]; then continue; fi
    status=$(extract_status "${SESSION}:${win}")
    printf "%-12s %-18s\n" "$win" "$status"
  done

  echo "══════════════════════════════════════════════════════"

  # eval 进度（如果有）
  if [[ -f ${TMUXFORALL_TMP}/eval_prod_v2.txt ]]; then
    LAST_EVAL=$(grep -E '^\[' ${TMUXFORALL_TMP}/eval_prod_v2.txt 2>/dev/null | tail -1 | head -c 70 || echo "")
    PASS_CT=$(grep -c '✓ PASS' ${TMUXFORALL_TMP}/eval_prod_v2.txt 2>/dev/null || echo "0")
    PASS_CT="${PASS_CT//[^0-9]/}"; PASS_CT="${PASS_CT:-0}"
    FAIL_CT=$(grep -c '✗ FAIL' ${TMUXFORALL_TMP}/eval_prod_v2.txt 2>/dev/null || echo "0")
    FAIL_CT="${FAIL_CT//[^0-9]/}"; FAIL_CT="${FAIL_CT:-0}"
    TOTAL=$((PASS_CT + FAIL_CT))
    if [[ $TOTAL -gt 0 ]]; then
      echo "  Eval: ${PASS_CT}✓ ${FAIL_CT}✗ / ${TOTAL}  ${LAST_EVAL}"
      echo "══════════════════════════════════════════════════════"
    fi
  fi

  sleep "$INTERVAL"
done
