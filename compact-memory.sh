#!/bin/bash
# compact-memory.sh — 用 claude -p 压缩角色成长记忆（超50条时触发）
# 注意: 不用 set -e，claude -p 返回非零时不终止
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
ROLE_ID="${1:-}"

if [[ -z "$ROLE_ID" ]]; then
  echo "用法: compact-memory.sh <role-id>" >&2
  exit 1
fi

MEM_FILE="${SKILL_DIR}/memory/${ROLE_ID}.md"
if [[ ! -f "$MEM_FILE" ]]; then
  echo "[compact-memory] 找不到: ${MEM_FILE}" >&2
  exit 1
fi

BACKUP="${MEM_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp "$MEM_FILE" "$BACKUP"
echo "[compact-memory] 已备份 → ${BACKUP}"

HEADER="$(head -8 "$MEM_FILE")"
ENTRIES="$(grep '^- \[' "$MEM_FILE" || true)"
COUNT=$(echo "$ENTRIES" | grep -c '^- \[' || echo 0)

echo "[compact-memory] 压缩 ${COUNT} 条记忆..."

COMPRESSED=$(claude -p "你是一个AI agent记忆管理器。以下是一个 ${ROLE_ID} 角色的跨项目成长记忆条目（共${COUNT}条）。
请将其压缩到最多30条，保留最具普遍价值、最常出现模式、最重要的教训。
格式保持不变: - [日期] | [项目] | [任务类型] | 教训
对同类教训做合并（取最近日期、综合描述）。只输出条目，不要其他说明。

${ENTRIES}" 2>/dev/null || echo "")

if [[ -z "$COMPRESSED" ]]; then
  echo "[compact-memory] 压缩失败，保留原文件"
  exit 0
fi

# 重写 memory 文件
{
  echo "${HEADER}"
  echo ""
  echo "${COMPRESSED}"
  echo ""
  echo "<!-- grow-agent.sh 自动追加 -->"
} > "$MEM_FILE"

NEW_COUNT=$(grep -c '^- \[' "$MEM_FILE" 2>/dev/null || echo 0)
echo "[compact-memory] 完成: ${COUNT} → ${NEW_COUNT} 条"
