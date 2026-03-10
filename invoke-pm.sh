#!/bin/bash
# invoke-pm.sh — 一键召唤 PM，替代 Commander 手拼复杂 shell 命令
# 用法: invoke-pm.sh <project> <task-file-or-string> [--output /path/to/output.md]
#
# 自动完成：读 PM 角色 YAML → 拼接 system prompt → 后台运行 claude → 结果写文件
# Commander 只需：bash invoke-pm.sh myproject /tmp/pm-task.md
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"

PROJECT="${1:-}"
TASK_INPUT="${2:-}"
OUTPUT_FILE=""

if [[ -z "$PROJECT" || -z "$TASK_INPUT" ]]; then
  echo "用法: invoke-pm.sh <project> <task-file-or-string> [--output /path/to/output.md]" >&2
  exit 1
fi

shift 2 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    *)        shift ;;
  esac
done

# 读取任务内容（文件或字符串）
if [[ -f "$TASK_INPUT" ]]; then
  TASK_CONTENT="$(cat "$TASK_INPUT")"
else
  TASK_CONTENT="$TASK_INPUT"
fi

# 从 YAML 提取 persona + methodology
ROLE_FILE="${SKILL_DIR}/roles/product-manager.yaml"
if [[ ! -f "$ROLE_FILE" ]]; then
  echo "[invoke-pm] 错误: 找不到 PM 角色文件 ${ROLE_FILE}" >&2
  exit 1
fi

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

print(persona)
if methodology:
    print('\n' + methodology)
if memory_content:
    print(memory_content)
PYEOF
)"

# 默认输出路径
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="${TMUXFORALL_TMP}/pm-output-${PROJECT}-${TIMESTAMP}.md"
fi

# 后台运行 claude
echo "[invoke-pm] 启动 PM 后台任务..."
echo "[invoke-pm] 任务: ${TASK_INPUT}"
echo "[invoke-pm] 输出: ${OUTPUT_FILE}"

# 动态查找 session（用于完成后 bell 通知 CM）
source "${SKILL_DIR}/_session_name.sh"
SESSION="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1 || echo "$TF_SESSION")"

nohup bash -c "
  ${TMUXFORALL_CLAUDE_CMD} -p $(printf '%q' "$TASK_CONTENT") --system-prompt $(printf '%q' "$SYSTEM_PROMPT") > '${OUTPUT_FILE}' 2>&1
  # 完成后 bell 通知 CM
  CM_TTY=\$(tmux display-message -p -t '${SESSION}:CM' '#{pane_tty}' 2>/dev/null || echo '')
  [[ -n \"\$CM_TTY\" && -w \"\$CM_TTY\" ]] && printf '\\a' > \"\$CM_TTY\"
  # 邮箱通知
  bash '${SKILL_DIR}/send-msg.sh' '${SESSION}:CM' 'PM 任务完成，结果: cat ${OUTPUT_FILE}'
" > /dev/null 2>&1 &
PM_PID=$!

echo "[invoke-pm] PM 已启动 (PID: ${PM_PID})，结果将写入 ${OUTPUT_FILE}"
echo "[invoke-pm] 完成后会自动 bell 通知 CM"
