#!/bin/bash
# invoke-intern.sh — 以实习生模式调用任意角色（claude -p，不占窗口不占预算）
# 用法: invoke-intern.sh <role-id> <project> <task-file-or-string> [--output /path/to/output.md] [--parent <窗口名>]
#
# 泛化版 invoke-pm.sh：读角色 YAML → 拼接 system prompt → 后台 claude -p → 结果写文件 → bell+邮箱通知
# CM 用法：bash invoke-intern.sh backend-engineer myproject "检查 API 返回格式是否符合规范"
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"

ROLE_ID="${1:-}"
PROJECT="${2:-}"
TASK_INPUT="${3:-}"
OUTPUT_FILE=""
PARENT_WIN="CM"

if [[ -z "$ROLE_ID" || -z "$PROJECT" || -z "$TASK_INPUT" ]]; then
  echo "用法: invoke-intern.sh <role-id> <project> <task-file-or-string> [--output /path] [--parent <窗口>]" >&2
  exit 1
fi

shift 3 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --parent) PARENT_WIN="$2"; shift 2 ;;
    *)        shift ;;
  esac
done

# 读取任务内容（文件或字符串）
if [[ -f "$TASK_INPUT" ]]; then
  TASK_CONTENT="$(cat "$TASK_INPUT")"
else
  TASK_CONTENT="$TASK_INPUT"
fi

# 检查角色文件
ROLE_FILE="${SKILL_DIR}/roles/${ROLE_ID}.yaml"
if [[ ! -f "$ROLE_FILE" ]]; then
  echo "[invoke-intern] 错误: 找不到角色定义 ${ROLE_FILE}" >&2
  exit 1
fi

# 从 YAML 提取 persona + methodology + memory
SYSTEM_PROMPT="$(python3 - "$ROLE_FILE" "$PROJECT" <<'PYEOF'
import sys, re

role_file = sys.argv[1]
project = sys.argv[2]

with open(role_file) as f:
    content = f.read()

def extract_block(field, text):
    pattern = r'^' + re.escape(field) + r':\s*\|[+-]?\s*\n'
    m = re.search(pattern, text, re.MULTILINE)
    if not m:
        return ''
    start = m.end()
    lines = []
    for line in text[start:].splitlines():
        if line == '' or line.startswith('  '):
            lines.append(line[2:] if line.startswith('  ') else '')
        else:
            break
    while lines and lines[-1] == '':
        lines.pop()
    return '\n'.join(lines)

persona = extract_block('persona', content).replace('{project}', project)
methodology = extract_block('methodology', content).replace('{project}', project)

# 注入记忆（如果有）
memory_content = ''
memory_file = re.search(r'^memory_file:\s*"?(.+?)"?\s*$', content, re.MULTILINE)
memory_lines = re.search(r'^memory_inject_lines:\s*(\d+)', content, re.MULTILINE)
if memory_file and memory_lines:
    mf = memory_file.group(1).strip('"')
    ml = int(memory_lines.group(1))
    if mf and ml > 0:
        import os
        mem_path = os.path.join(os.path.dirname(role_file), '..', 'memory', mf)
        if os.path.exists(mem_path):
            with open(mem_path) as mfh:
                mem_lines = mfh.readlines()[-ml:]
                memory_content = '\n## 跨项目经验\n' + ''.join(mem_lines)

# 实习生模式附加说明
intern_note = """
## 实习生模式
你以实习生身份运行：无窗口、不占预算、一次性任务。
- 结果直接写到 stdout（会被重定向到输出文件）
- 不需要调用 report-up.sh / check-mail.sh
- 不需要汇报 STATUS 格式，直接输出结果
- 专注完成任务，不要做额外工作
"""

print(persona)
if methodology:
    print('\n' + methodology)
print(intern_note)
if memory_content:
    print(memory_content)
PYEOF
)"

# 默认输出路径
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ROLE_SHORT="$(python3 -c "
import re
with open('${ROLE_FILE}') as f: c = f.read()
m = re.search(r'^window_name:\s*\"?(.+?)\"?\s*$', c, re.MULTILINE)
print(m.group(1).strip('\"') if m else '${ROLE_ID}')
")"
if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="${TMUXFORALL_TMP}/intern-${ROLE_SHORT}-${PROJECT}-${TIMESTAMP}.md"
fi

echo "[invoke-intern] 启动 ${ROLE_ID} 实习生..."
echo "[invoke-intern] 任务: ${TASK_INPUT}"
echo "[invoke-intern] 输出: ${OUTPUT_FILE}"

# 动态查找 session
source "${SKILL_DIR}/_session_name.sh"
SESSION="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1 || echo "$TF_SESSION")"

nohup bash -c "
  ${TMUXFORALL_CLAUDE_CMD} -p $(printf '%q' "$TASK_CONTENT") --system-prompt $(printf '%q' "$SYSTEM_PROMPT") > '${OUTPUT_FILE}' 2>&1
  # 完成后 bell 通知 parent
  PARENT_TTY=\$(tmux display-message -p -t '${SESSION}:${PARENT_WIN}' '#{pane_tty}' 2>/dev/null || echo '')
  [[ -n \"\$PARENT_TTY\" && -w \"\$PARENT_TTY\" ]] && printf '\\a' > \"\$PARENT_TTY\"
  # 邮箱通知
  bash '${SKILL_DIR}/send-msg.sh' '${SESSION}:${PARENT_WIN}' '实习生[${ROLE_SHORT}] 任务完成，结果: cat ${OUTPUT_FILE}'
" > /dev/null 2>&1 &
INTERN_PID=$!

echo "[invoke-intern] ${ROLE_SHORT} 实习生已启动 (PID: ${INTERN_PID})，结果将写入 ${OUTPUT_FILE}"
