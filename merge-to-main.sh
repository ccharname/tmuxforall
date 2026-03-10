#!/bin/bash
# merge-to-main.sh — Commander-only: 合并 Agent feature 分支到 main
# 用法: merge-to-main.sh <project> <window-name>
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
PROJECT="${1:-}"
WINDOW_NAME="${2:-}"

if [[ -z "$PROJECT" || -z "$WINDOW_NAME" ]]; then
  echo "用法: merge-to-main.sh <project> <window-name>" >&2
  exit 1
fi

source "${SKILL_DIR}/_session_name.sh"
SESSION="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1 || echo "$TF_SESSION")"
WORKDIR="$(tmux display-message -p -t "${SESSION}" '#{session_path}' 2>/dev/null || pwd)"

# 安全检查：必须从 CM 窗口执行
CURRENT_WIN="$(tmux display-message -p '#{window_name}' 2>/dev/null || echo '')"
if [[ "$CURRENT_WIN" != "CM" ]]; then
  echo "[merge-to-main] 错误: 只有 CM 窗口可以执行合并操作 (当前: ${CURRENT_WIN})" >&2
  exit 1
fi

# 检查 git 仓库
if ! git -C "$WORKDIR" rev-parse --git-dir &>/dev/null; then
  echo "[merge-to-main] 错误: ${WORKDIR} 不是 git 仓库" >&2
  exit 1
fi

BRANCH="feature/${WINDOW_NAME}"

# 检查分支是否存在
if ! git -C "$WORKDIR" show-ref --quiet --heads "$BRANCH" 2>/dev/null; then
  echo "[merge-to-main] 找不到分支: ${BRANCH}" >&2
  exit 1
fi

echo "[merge-to-main] 准备合并 ${BRANCH} → main"

# === 安全检查：对应 agent 窗口是否还在运行 ===
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW_NAME"; then
  # 检查 agent 是否 idle（❯ 提示符）
  AGENT_OUTPUT=$(tmux capture-pane -t "${SESSION}:${WINDOW_NAME}" -p -S -3 2>/dev/null || echo "")
  if echo "$AGENT_OUTPUT" | grep -qE '^❯\s*$'; then
    echo "[merge-to-main] ${WINDOW_NAME} 窗口 idle，合并后将关闭"
    KILL_AFTER_MERGE=true
  else
    echo "[merge-to-main] ⚠️  ${WINDOW_NAME} 窗口仍在运行中！"
    echo "[merge-to-main] 先终止 agent 再合并，或等 agent 完成任务"
    echo "[merge-to-main] 强制继续请重新运行并加 --force（未实现，请先手动关窗口）"
    exit 1
  fi
else
  KILL_AFTER_MERGE=false
fi

if command -v wt &>/dev/null; then
  # wt merge: commit→squash→rebase→push→cleanup 一条龙
  WORKTREE_PATH="$(wt -C "$WORKDIR" list --format=json 2>/dev/null | python3 -c "
import sys,json
data=json.load(sys.stdin)
for w in data:
    if w.get('branch')=='${BRANCH}' and w.get('path'):
        print(w['path']); break
" 2>/dev/null || echo '')"
  if [[ -n "$WORKTREE_PATH" && -d "$WORKTREE_PATH" ]]; then
    wt -C "$WORKTREE_PATH" merge --yes 2>&1 && \
      echo "[merge-to-main] wt merge 完成: ${BRANCH} → main" || \
      echo "[merge-to-main] [warn] wt merge 失败，尝试手动合并"
  else
    # 无 worktree 但分支存在，手动合并
    git -C "$WORKDIR" checkout main
    git -C "$WORKDIR" merge --no-ff "$BRANCH" -m "merge: ${WINDOW_NAME} → main [tmuxforall/${PROJECT}]"
    git -C "$WORKDIR" branch -d "$BRANCH" 2>/dev/null || true
    echo "[merge-to-main] 手动合并完成: ${BRANCH} → main"
  fi
else
  WORKTREE="${WORKDIR}/worktrees/${WINDOW_NAME}"

  # 切换到 main
  git -C "$WORKDIR" checkout main

  # 合并（保留历史，不 fast-forward）
  git -C "$WORKDIR" merge --no-ff "$BRANCH" -m "merge: ${WINDOW_NAME} → main [tmuxforall/${PROJECT}]"

  echo "[merge-to-main] 合并成功: ${BRANCH} → main"

  # 清理已合并的 worktree 和分支
  if [[ -d "$WORKTREE" ]]; then
    git -C "$WORKDIR" worktree remove "$WORKTREE" --force 2>/dev/null && \
      echo "[merge-to-main] 已清理 worktree: ${WORKTREE}" || \
      echo "[merge-to-main] [warn] worktree 清理失败: ${WORKTREE}"
  fi
  git -C "$WORKDIR" branch -d "$BRANCH" 2>/dev/null && \
    echo "[merge-to-main] 已删除分支: ${BRANCH}" || true

  # 对所有其他 worktree rebase
  echo "[merge-to-main] 更新其他 worktrees..."
  for wt_dir in "${WORKDIR}/worktrees"/*/; do
    WT_NAME="$(basename "$wt_dir")"
    if [[ "$WT_NAME" == "$WINDOW_NAME" ]]; then continue; fi
    if [[ ! -d "$wt_dir" ]]; then continue; fi

    WT_BRANCH="feature/${WT_NAME}"
    if git -C "$wt_dir" rev-parse --git-dir &>/dev/null 2>&1; then
      echo "  rebase ${WT_BRANCH} onto main..."
      git -C "$wt_dir" rebase main 2>/dev/null || \
        echo "  [warn] ${WT_NAME} rebase 冲突，需手动处理"
    fi
  done
fi

# === 合并后安全关闭 agent 窗口 ===
if [[ "${KILL_AFTER_MERGE:-false}" == "true" ]]; then
  echo "[merge-to-main] 关闭 ${WINDOW_NAME} 窗口（worktree 已删除，agent 无法继续工作）"
  tmux send-keys -t "${SESSION}:${WINDOW_NAME}" Escape 2>/dev/null || true
  sleep 1
  tmux kill-window -t "${SESSION}:${WINDOW_NAME}" 2>/dev/null || true
  # 通知 CM
  bash "${SKILL_DIR}/send-msg.sh" "${SESSION}:CM" \
    "[merge-to-main] ${WINDOW_NAME} 分支已合并到 main，worktree 已清理，窗口已关闭。如需继续该角色的工作，请重新 spawn。" 2>/dev/null || true
fi

echo "[merge-to-main] 完成"
