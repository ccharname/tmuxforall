#!/bin/bash
# build-prompt.sh — 为指定角色生成 system prompt（纯输出，不碰 tmux）
# 用法: build-prompt.sh <role-id> [project] [--archetype <type>] [--scope <path>]
# 输出: prompt 文本到 stdout
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
ROLE_ID="${1:-}"
PROJECT="${2:-$(basename "$(pwd)")}"
DYN_ARCHETYPE=""
DYN_SCOPE=""
DYN_DISPLAY=""

shift 2 2>/dev/null || shift $# 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archetype) DYN_ARCHETYPE="$2"; shift 2 ;;
    --scope)     DYN_SCOPE="$2";     shift 2 ;;
    --display)   DYN_DISPLAY="$2";   shift 2 ;;
    *)           shift ;;
  esac
done

if [[ -z "$ROLE_ID" ]]; then
  echo "用法: build-prompt.sh <role-id> [project] [--archetype <type>] [--scope <path>]" >&2
  exit 1
fi

ROLE_FILE="${SKILL_DIR}/roles/${ROLE_ID}.yaml"
DYNAMIC_ROLE=false
if [[ ! -f "$ROLE_FILE" ]]; then
  if [[ -n "$DYN_ARCHETYPE" ]]; then
    DYNAMIC_ROLE=true
  else
    echo "[build-prompt] 找不到角色定义: ${ROLE_FILE}（动态角色需加 --archetype）" >&2
    exit 1
  fi
fi

WORKDIR="$(pwd)"

# 读取 YAML 字段（复用 spawn-role.sh 的解析器）
read_yaml() {
  python3 - "$1" "$2" <<'PYEOF'
import sys, re
field = sys.argv[2]
with open(sys.argv[1]) as f:
    content = f.read()
pattern = r'^' + re.escape(field) + r':\s*\|[+-]?\s*\n'
m = re.search(pattern, content, re.MULTILINE)
if m:
    start = m.end()
    lines = []
    for line in content[start:].splitlines():
        if line == '' or line.startswith('  '):
            lines.append(line[2:] if line.startswith('  ') else '')
        else:
            break
    while lines and lines[-1] == '':
        lines.pop()
    print('\n'.join(lines))
    sys.exit(0)
pattern2 = r'^' + re.escape(field) + r':\s*["\']?(.+?)["\']?\s*$'
m2 = re.search(pattern2, content, re.MULTILINE)
if m2:
    print(m2.group(1).strip('"\''))
PYEOF
}

# 解析角色字段
if [[ "$DYNAMIC_ROLE" == "true" ]]; then
  WINDOW_NAME="${ROLE_ID^^}"
  ARCHETYPE_ID="$DYN_ARCHETYPE"
  BOUNDARIES="${DYN_SCOPE:+- 职责范围：${DYN_SCOPE}}"
  PERSONA="${DYN_DISPLAY:-你是 ${PROJECT} 项目的 ${ROLE_ID}，在独立工作空间中工作。}"
  METHODOLOGY=""
  COMM_PROTOCOL=""
  SAFETY_RULES=""
  MEMORY_FILE_REL=""
  MEMORY_LINES="0"
  SKILLS_LIST=""
else
  WINDOW_NAME="$(read_yaml "$ROLE_FILE" "window_name")"
  ARCHETYPE_ID="$(read_yaml "$ROLE_FILE" "archetype" || echo '')"
  BOUNDARIES="$(read_yaml "$ROLE_FILE" "boundaries" || echo '')"
  PERSONA="$(read_yaml "$ROLE_FILE" "persona")"
  METHODOLOGY="$(read_yaml "$ROLE_FILE" "methodology")"
  COMM_PROTOCOL="$(read_yaml "$ROLE_FILE" "communication_protocol")"
  SAFETY_RULES="$(read_yaml "$ROLE_FILE" "safety_rules" || echo '')"
  MEMORY_FILE_REL="$(read_yaml "$ROLE_FILE" "memory_file" || echo '')"
  MEMORY_LINES="$(read_yaml "$ROLE_FILE" "memory_inject_lines" || echo '0')"

  SKILLS_LIST="$(python3 - "$ROLE_FILE" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
m = re.search(r'^skills_recommended:\s*\n((?:  - .+\n?)+)', content, re.MULTILINE)
if m:
    items = re.findall(r'  - (.+)', m.group(1))
    for item in items:
        val = item.strip().strip('"').strip("'")
        parts = val.split(' — ', 1)
        name = parts[0].strip()
        desc = f' — {parts[1].strip()}' if len(parts) > 1 else ''
        print(f'  - /{name}{desc}')
PYEOF
  )"
fi

if [[ -n "$DYN_ARCHETYPE" ]]; then
  ARCHETYPE_ID="$DYN_ARCHETYPE"
fi

# 加载原型
ARCHETYPE_BASE_RULES=""
if [[ -n "$ARCHETYPE_ID" ]]; then
  ARCHETYPE_FILE="${SKILL_DIR}/archetypes/${ARCHETYPE_ID}.yaml"
  if [[ -f "$ARCHETYPE_FILE" ]]; then
    ARCHETYPE_BASE_RULES="$(read_yaml "$ARCHETYPE_FILE" "base_rules" || echo '')"
  fi
fi

# 读取成长记忆
MEMORY_CONTENT=""
if [[ -n "$MEMORY_FILE_REL" && "$MEMORY_LINES" != "0" ]]; then
  MEM_PATH="${SKILL_DIR}/memory/${MEMORY_FILE_REL}"
  if [[ -f "$MEM_PATH" ]]; then
    MEMORY_CONTENT="$(tail -n "${MEMORY_LINES}" "$MEM_PATH")"
  fi
fi

# 输出 prompt
cat <<PROMPT
${ARCHETYPE_BASE_RULES:+## 原型规则
${ARCHETYPE_BASE_RULES}
}${BOUNDARIES:+## 边界（不可越界）
${BOUNDARIES}
}${PERSONA/\{project\}/$PROJECT}

${METHODOLOGY}

${COMM_PROTOCOL}

${SAFETY_RULES:+## 安全规则（必须遵守）
${SAFETY_RULES}
}## 可用技能（斜杠命令直接调用）
${SKILLS_LIST:-（无预配置技能）}

## 成长记忆（来自历史项目）
${MEMORY_CONTENT}

## 经验沉淀（任务完成时自检）
如果本次任务中你踩了坑或发现了非显而易见的技巧，主动记录：
bash ${SKILL_DIR}/grow-agent.sh ${ROLE_ID} ${PROJECT} "<任务类型>" "<具体教训>"

## 项目上下文
- 角色: ${ROLE_ID} (${WINDOW_NAME})
- 项目: ${PROJECT}
- 工作目录: ${WORKDIR}
PROMPT
