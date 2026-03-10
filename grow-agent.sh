#!/bin/bash
# grow-agent.sh — 追加成长记忆到角色 memory 文件
# 用法: grow-agent.sh <role-id> <project> "<task-type>" "<lesson>"
# compact-memory.sh 例外：不设 set -e（claude -p 返回非零时不终止）
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
ROLE_ID="${1:-}"
PROJECT="${2:-}"
TASK_TYPE="${3:-通用}"
LESSON="${4:-}"

if [[ -z "$ROLE_ID" || -z "$LESSON" ]]; then
  echo "用法: grow-agent.sh <role-id> <project> \"<task-type>\" \"<lesson>\"" >&2
  exit 1
fi

MEM_FILE="${SKILL_DIR}/memory/${ROLE_ID}.md"
if [[ ! -f "$MEM_FILE" ]]; then
  # 自动创建 memory 文件（含 marker）
  mkdir -p "${SKILL_DIR}/memory"
  cat > "$MEM_FILE" <<INITEOF
# ${ROLE_ID} 成长记忆

<!-- grow-agent.sh 自动追加 -->
INITEOF
  echo "[grow-agent] 已创建 memory 文件: ${MEM_FILE}"
fi

DATE="$(date +%Y-%m-%d)"
ENTRY="- [${DATE}] | [${PROJECT}] | [${TASK_TYPE}] | ${LESSON}"

# 追加到 <!-- grow-agent.sh 自动追加 --> 注释之前
python3 - <<PYEOF
with open('${MEM_FILE}', 'r') as f:
    content = f.read()
marker = "<!-- grow-agent.sh 自动追加 -->"
entry = "${ENTRY}"
content = content.replace(marker, entry + "\n" + marker)
with open('${MEM_FILE}', 'w') as f:
    f.write(content)
PYEOF

echo "[grow-agent] 已记录教训 → ${MEM_FILE}"

# 计算条目数，超过50条触发压缩
COUNT=$(grep -c '^- \[' "$MEM_FILE" 2>/dev/null) || COUNT=0
if [[ "$COUNT" -gt 50 ]]; then
  echo "[grow-agent] 条目数 ${COUNT} > 50，触发 compact-memory.sh"
  bash "${SKILL_DIR}/compact-memory.sh" "$ROLE_ID" || true
fi
