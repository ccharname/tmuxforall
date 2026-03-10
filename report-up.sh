#!/bin/bash
# report-up.sh — 向上级汇报并更新 Board + bell 通知
# 用法: report-up.sh <my-window> <parent-window> "<summary>" <project> [--wip]
# --wip: 保存中间进度到 /tmp/tmuxforall-wip-{window}.md，不发完成信号
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
MY_WIN="${1:-}"
PARENT_WIN="${2:-}"
SUMMARY="${3:-}"
PROJECT="${4:-}"
WIP_MODE=false
# 检查 --wip 标志（可能在第 4 或第 5 个参数位置）
for arg in "${@:4}"; do
  [[ "$arg" == "--wip" ]] && WIP_MODE=true
done
# PROJECT 可能被 --wip 占了位置，修正
[[ "$PROJECT" == "--wip" ]] && PROJECT="${5:-}" && WIP_MODE=true

if [[ -z "$MY_WIN" || -z "$PARENT_WIN" || -z "$PROJECT" ]]; then
  echo "用法: report-up.sh <my-window> <parent-window> \"<summary>\" <project> [--wip]" >&2
  exit 1
fi

# WIP 模式：只保存进度文件，不发完成信号
if [[ "$WIP_MODE" == "true" ]]; then
  # 用 PROJECT 隔离 WIP 文件（防止多项目串台）
  WIP_FILE="${TMUXFORALL_TMP}/tmuxforall-wip-${PROJECT}-${MY_WIN}.md"
  cat > "$WIP_FILE" <<WIPEOF
# WIP 进度 [${MY_WIN}] $(date +%H:%M)
${SUMMARY}
WIPEOF
  echo "[report-up] WIP 已保存: ${WIP_FILE}"
  exit 0
fi

# 动态查找 session（兼容 session 重命名为 N-tf-xxx）
source "${SKILL_DIR}/_session_name.sh"
SESSION="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1 || echo "$TF_SESSION")"
WORKDIR="$(tmux display-message -p -t "${SESSION}:" '#{session_path}' 2>/dev/null || pwd)"
BOARD="${WORKDIR}/COMMANDER-BOARD.md"
NOW="$(date +%H:%M)"
TRACKER="${TMUXFORALL_TMP}/tmux-tracker-cache.json"

# 1. 发送摘要给 parent
MSG="## 汇报 [${MY_WIN}→${PARENT_WIN}] ${NOW}

${SUMMARY}"
bash "${SKILL_DIR}/send-msg.sh" "${SESSION}:${PARENT_WIN}" "$MSG"

# 2. 更新 tracker-cache.json 状态为 done
MY_WIN_ID="$(tmux display-message -p -t "${SESSION}:${MY_WIN}" '#{window_id}' 2>/dev/null || echo '')"
if [[ -n "$MY_WIN_ID" && -f "$TRACKER" ]]; then
  python3 - <<PYEOF
import json
with open('${TRACKER}') as f:
    data = json.load(f)
for t in data.get("tasks", []):
    if t.get("window_id") == "${MY_WIN_ID}":
        t["status"] = "done"
        t["completed"] = "${NOW}"
with open('${TRACKER}', 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PYEOF
fi

# 3. 清除 parent @watching，设置 @unread 1
PARENT_WIN_ID="$(tmux display-message -p -t "${SESSION}:${PARENT_WIN}" '#{window_id}' 2>/dev/null || echo '')"
if [[ -n "$PARENT_WIN_ID" ]]; then
  tmux set-option -t "${SESSION}:${PARENT_WIN}" @watching 0 2>/dev/null || true
  tmux set-option -t "${SESSION}:${PARENT_WIN}" @unread 1 2>/dev/null || true
fi

# 4. 更新 COMMANDER-BOARD.md 中本 Agent 状态行（用精确字符串查找，避免正则注入）
if [[ -f "$BOARD" ]]; then
  python3 - "${BOARD}" "${MY_WIN}" "${NOW}" <<'PYEOF'
import sys
board_path, win_name, now = sys.argv[1], sys.argv[2], sys.argv[3]
with open(board_path, 'r') as f:
    lines = f.readlines()
needle = '| ' + win_name + ' |'
new_lines = []
for line in lines:
    if line.startswith(needle) or ('| ' + win_name + ' |') in line:
        # 替换最后一个 | 前的时间字段
        parts = line.rstrip('\n').split('|')
        if len(parts) >= 2:
            parts[-2] = ' ' + now + ' '
            line = '|'.join(parts) + '\n'
    new_lines.append(line)
with open(board_path, 'w') as f:
    f.writelines(new_lines)
PYEOF
fi

# 5. Agent Tracker: 标记任务完成
TRACKER_CLIENT="$HOME/.config/agent-tracker/bin/tracker-client"
if [[ -x "$TRACKER_CLIENT" && -n "$MY_WIN_ID" ]]; then
  MY_SID="$(tmux display-message -p -t "${SESSION}:${MY_WIN}" '#{session_id}' 2>/dev/null || true)"
  MY_PID="$(tmux display-message -p -t "${SESSION}:${MY_WIN}" '#{pane_id}' 2>/dev/null || true)"
  if [[ -n "$MY_SID" && -n "$MY_PID" ]]; then
    "$TRACKER_CLIENT" command finish_task \
      --session-id "$MY_SID" --window-id "$MY_WIN_ID" --pane "$MY_PID" \
      --summary "${SUMMARY:0:100}" 2>/dev/null || true
  fi
fi

# 6. Bell 通知 parent 窗口（写入 pane tty 才能触发 tmux bell 检测）
PARENT_TTY="$(tmux display-message -p -t "${SESSION}:${PARENT_WIN}" '#{pane_tty}' 2>/dev/null || echo '')"
if [[ -n "$PARENT_TTY" && -w "$PARENT_TTY" ]]; then
  printf '\a' > "$PARENT_TTY"
fi
# 也在本地 pane 响一下
MY_TTY="$(tmux display-message -p -t "${SESSION}:${MY_WIN}" '#{pane_tty}' 2>/dev/null || echo '')"
if [[ -n "$MY_TTY" && -w "$MY_TTY" ]]; then
  printf '\a' > "$MY_TTY"
fi

# 7. 唤醒 parent：如果 parent 空闲（在 ❯ 提示符），直接粘贴指令触发 check-mail
PARENT_LAST=$(tmux capture-pane -t "${SESSION}:${PARENT_WIN}" -p -S -3 2>/dev/null || echo "")
if echo "$PARENT_LAST" | grep -qE '^❯\s*$'; then
  tmux send-keys -t "${SESSION}:${PARENT_WIN}" -l \
    "${MY_WIN} 已汇报完成，请 check-mail 处理"
  sleep 0.3
  tmux send-keys -t "${SESSION}:${PARENT_WIN}" Escape
  sleep 0.1
  tmux send-keys -t "${SESSION}:${PARENT_WIN}" Enter
fi

# 8. tmux wait-for 信号（脚本层同步用：CM 可在脚本中 tmux wait-for tf-done-{窗口名} 阻塞等待）
tmux wait-for -S "tf-done-${MY_WIN}" 2>/dev/null || true

echo "[report-up] ${MY_WIN} → ${PARENT_WIN} 汇报完成"
