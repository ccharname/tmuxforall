#!/bin/bash
# spawn-role.sh — 孵化指定角色的 Agent 窗口
# 用法: spawn-role.sh <role-id> <project> [--name <自定义名>] [--parent <parent-window>] [--level <N>] [--timeout <分钟>]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SKILL_DIR}/config.sh"
ROLE_ID="${1:-}"
PROJECT="${2:-}"
WINDOW_NAME=""
PARENT_WIN=""
LEVEL="2"
WORKDIR_ARG=""
SESSION_ID_ARG=""
TIMEOUT_MIN=""
# 动态角色参数（无 YAML 时使用）
DYN_ARCHETYPE=""
DYN_SCOPE=""
DYN_DISPLAY=""

shift 2 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)       WINDOW_NAME="$2";    shift 2 ;;
    --parent)     PARENT_WIN="$2";     shift 2 ;;
    --level)      LEVEL="$2";          shift 2 ;;
    --workdir)    WORKDIR_ARG="$2";    shift 2 ;;
    --session-id) SESSION_ID_ARG="$2"; shift 2 ;;
    --timeout)    TIMEOUT_MIN="$2";    shift 2 ;;
    --archetype)  DYN_ARCHETYPE="$2";  shift 2 ;;
    --scope)      DYN_SCOPE="$2";      shift 2 ;;
    --display)    DYN_DISPLAY="$2";    shift 2 ;;
    *)            shift ;;
  esac
done

if [[ -z "$ROLE_ID" || -z "$PROJECT" ]]; then
  echo "用法: spawn-role.sh <role-id> <project> [--name <name>] [--parent <parent>] [--level <N>]" >&2
  echo "  动态角色: spawn-role.sh <自定义名> <project> --archetype executor --scope \"backend/\" --parent CM" >&2
  exit 1
fi

ROLE_FILE="${SKILL_DIR}/roles/${ROLE_ID}.yaml"
DYNAMIC_ROLE=false
if [[ ! -f "$ROLE_FILE" ]]; then
  # 无 YAML → 必须有 --archetype 才能动态创建
  if [[ -n "$DYN_ARCHETYPE" ]]; then
    DYNAMIC_ROLE=true
  else
    echo "[spawn-role] 找不到角色定义: ${ROLE_FILE}（动态角色需加 --archetype）" >&2
    exit 1
  fi
fi

source "${SKILL_DIR}/_session_name.sh"
# 动态查找 session（兼容 session 重命名为 N-xxx）
SESSION="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1 || echo "$TF_SESSION")"
# 优先用 session_id（不受 session 重命名影响），其次动态查找的 session name
TARGET="${SESSION_ID_ARG:-$SESSION}"

# 优先用传入的 workdir，其次查 tmux session 路径，最后 fallback 到 pwd
if [[ -n "$WORKDIR_ARG" ]]; then
  WORKDIR="$WORKDIR_ARG"
else
  WORKDIR="$(tmux display-message -p -t "${TARGET}:CM" '#{pane_current_path}' 2>/dev/null || \
             tmux display-message -p -t "${TARGET}:" '#{session_path}' 2>/dev/null || \
             pwd)"
fi

# 读取 YAML 字段（python3 解析）
read_yaml() {
  python3 - "$1" "$2" <<'PYEOF'
import sys, re
field = sys.argv[2]
with open(sys.argv[1]) as f:
    content = f.read()

# YAML 多行块读取（支持块内空行）
# 找到 field: | 后，收集所有缩进2格的行（包括空行），直到遇到非缩进行
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
    # 去掉尾部空行
    while lines and lines[-1] == '':
        lines.pop()
    print('\n'.join(lines))
    sys.exit(0)

# 单行值
pattern2 = r'^' + re.escape(field) + r':\s*["\']?(.+?)["\']?\s*$'
m2 = re.search(pattern2, content, re.MULTILINE)
if m2:
    print(m2.group(1).strip('"\''))
PYEOF
}

# 解析角色字段（静态 YAML 角色 vs 动态角色）
if [[ "$DYNAMIC_ROLE" == "true" ]]; then
  # 动态角色：从 CLI 参数构建
  ROLE_WINDOW_NAME="${WINDOW_NAME:-${ROLE_ID^^}}"
  ARCHETYPE_ID="$DYN_ARCHETYPE"
  BOUNDARIES="${DYN_SCOPE:+- 职责范围：${DYN_SCOPE}}"
  PERSONA="${DYN_DISPLAY:-你是 ${PROJECT} 项目的 ${ROLE_ID}，在独立工作空间中工作。}"
  METHODOLOGY=""
  COMM_PROTOCOL=""
  SAFETY_RULES=""
  MEMORY_FILE_REL=""
  MEMORY_LINES="0"
  DEFAULT_TIMEOUT="30"
  SKILLS_LIST=""
else
  # 静态角色：从 YAML 读取
  ROLE_WINDOW_NAME="$(read_yaml "$ROLE_FILE" "window_name")"
  ARCHETYPE_ID="$(read_yaml "$ROLE_FILE" "archetype" || echo '')"
  BOUNDARIES="$(read_yaml "$ROLE_FILE" "boundaries" || echo '')"
  PERSONA="$(read_yaml "$ROLE_FILE" "persona")"
  METHODOLOGY="$(read_yaml "$ROLE_FILE" "methodology")"
  COMM_PROTOCOL="$(read_yaml "$ROLE_FILE" "communication_protocol")"
  SAFETY_RULES="$(read_yaml "$ROLE_FILE" "safety_rules" || echo '')"
  MEMORY_FILE_REL="$(read_yaml "$ROLE_FILE" "memory_file" || echo '')"
  MEMORY_LINES="$(read_yaml "$ROLE_FILE" "memory_inject_lines" || echo '0')"
  DEFAULT_TIMEOUT="$(read_yaml "$ROLE_FILE" "default_timeout" || echo '0')"

  # 读取推荐技能列表（skills_recommended 是 YAML 列表，支持 "name — desc" 格式）
  SKILLS_LIST="$(python3 - "$ROLE_FILE" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
m = re.search(r'^skills_recommended:\s*\n((?:  - .+\n?)+)', content, re.MULTILINE)
if m:
    items = re.findall(r'  - (.+)', m.group(1))
    for item in items:
        val = item.strip().strip('"').strip("'")
        # "skill-name — description" → "/skill-name — description"
        parts = val.split(' — ', 1)
        name = parts[0].strip()
        desc = f' — {parts[1].strip()}' if len(parts) > 1 else ''
        print(f'  - /{name}{desc}')
PYEOF
  )"
fi

# CLI --archetype 覆盖 YAML archetype（允许临时切换）
if [[ -n "$DYN_ARCHETYPE" ]]; then
  ARCHETYPE_ID="$DYN_ARCHETYPE"
fi

# 加载原型定义
ARCHETYPE_BASE_RULES=""
ARCHETYPE_WORKTREE="false"
if [[ -n "$ARCHETYPE_ID" ]]; then
  ARCHETYPE_FILE="${SKILL_DIR}/archetypes/${ARCHETYPE_ID}.yaml"
  if [[ -f "$ARCHETYPE_FILE" ]]; then
    ARCHETYPE_BASE_RULES="$(read_yaml "$ARCHETYPE_FILE" "base_rules" || echo '')"
    ARCHETYPE_WORKTREE="$(read_yaml "$ARCHETYPE_FILE" "worktree" || echo 'false')"
  else
    echo "[spawn-role] 警告: 找不到原型 ${ARCHETYPE_FILE}，跳过原型注入" >&2
  fi
fi

# --timeout 未传时，使用角色定义的 default_timeout
if [[ -z "$TIMEOUT_MIN" && "$DEFAULT_TIMEOUT" != "0" ]]; then
  TIMEOUT_MIN="$DEFAULT_TIMEOUT"
fi

# 确定窗口名（检查 tmux 同名窗口，自动加序号避免冲突）
if [[ -z "$WINDOW_NAME" ]]; then
  WINDOW_NAME="${ROLE_WINDOW_NAME:-$ROLE_ID}"
fi
# 如果 session 中已有同名窗口，追加序号（BE→BE2→BE3）
ACTUAL_TARGET="${SESSION_ID_ARG:-$SESSION}"
if tmux list-windows -t "${ACTUAL_TARGET}:" -F '#{window_name}' 2>/dev/null | grep -qx "${WINDOW_NAME}"; then
  SEQ=2
  while tmux list-windows -t "${ACTUAL_TARGET}:" -F '#{window_name}' 2>/dev/null | grep -qx "${WINDOW_NAME}${SEQ}"; do
    SEQ=$((SEQ + 1))
  done
  WINDOW_NAME="${WINDOW_NAME}${SEQ}"
fi

# 读取成长记忆
MEMORY_CONTENT=""
if [[ -n "$MEMORY_FILE_REL" && "$MEMORY_LINES" != "0" ]]; then
  MEM_PATH="${SKILL_DIR}/memory/${MEMORY_FILE_REL}"
  if [[ -f "$MEM_PATH" ]]; then
    MEMORY_CONTENT="$(tail -n "${MEMORY_LINES}" "$MEM_PATH")"
  fi
fi

# 获取实际 session 名（session manager 可能已将 xxx 重命名为 N-xxx）
ACTUAL_SESSION="$(tmux display-message -p -t "${TARGET}:" '#{session_name}' 2>/dev/null || echo "$SESSION")"

# 创建 worktree — 基于原型决定（executor=true, inspector/thinker=false）
# commander 永远不创建 worktree（无 archetype）
# 防嵌套：如果 WORKDIR 本身在 worktree 里，回退到主仓库
if [[ "$WORKDIR" == */worktrees/* ]]; then
  WORKDIR="$(git -C "$WORKDIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')"
fi
AGENT_WORKDIR="$WORKDIR"
if [[ "$ARCHETYPE_WORKTREE" == "true" ]]; then
  if git -C "$WORKDIR" rev-parse --git-dir &>/dev/null 2>&1; then
    BRANCH_NAME="feature/${WINDOW_NAME}"
    wt -C "$WORKDIR" switch --create "$BRANCH_NAME" --no-cd 2>/dev/null || \
    wt -C "$WORKDIR" switch "$BRANCH_NAME" --no-cd 2>/dev/null || true
    WORKTREE_PATH="$(wt -C "$WORKDIR" list --format=json 2>/dev/null | python3 -c "
import sys,json
data=json.load(sys.stdin)
for w in data:
    if w.get('branch')=='${BRANCH_NAME}' and w.get('path'):
        print(w['path']); break
" 2>/dev/null || echo "${WORKDIR}/worktrees/${WINDOW_NAME}")"
    if [[ -d "$WORKTREE_PATH" ]]; then
      AGENT_WORKDIR="$WORKTREE_PATH"
    fi
  fi
fi

# 构建 system-prompt（写到临时文件避免转义问题）
# 文件名含窗口名，restart-agent.sh 可按窗口名精确查找
# 文件名含 session + 窗口名，避免多项目串台
PROMPT_FILE="${TMUXFORALL_TMP}/tmuxforall-prompt-${SESSION}-${WINDOW_NAME}-$$.txt"
cat > "$PROMPT_FILE" <<PROMPT
${ARCHETYPE_BASE_RULES:+## 原型规则
${ARCHETYPE_BASE_RULES}
}${BOUNDARIES:+## 边界（不可越界）
${BOUNDARIES}
}${PERSONA/\{project\}/$PROJECT}

${METHODOLOGY}

${COMM_PROTOCOL}

${SAFETY_RULES:+## 安全规则（必须遵守）
${SAFETY_RULES}
}## 通信工具
**优先使用 MCP tool**（结构化接口，自动管理状态和智能路由）：

通信：
- 查邮箱: \`mcp__tmuxforall__check_messages()\` — **每次完成一轮工作后、开始新任务前必须调用**
- 发消息: \`mcp__tmuxforall__send_message(to="窗口名", content="消息")\`（智能路由：空闲→直投 | 忙碌→邮箱 | 死亡→缓存）
- 向上汇报: \`mcp__tmuxforall__report_up(summary="摘要")\`（自动通知 parent + 更新 Board）
- 中间进度: \`mcp__tmuxforall__report_up(summary="进展...", wip=True)\`
- 广播: \`mcp__tmuxforall__broadcast(content="消息")\`

生命周期（CM 用）：
- 孵化: \`mcp__tmuxforall__spawn_role(role_id="xxx", archetype="executor", scope="dir/", display="描述")\`
- 派发: \`mcp__tmuxforall__dispatch_task(target="窗口名", title="任务", criteria="标准1\n标准2")\`
- 重启: \`mcp__tmuxforall__restart_agent(target="窗口名")\`
- 合并: \`mcp__tmuxforall__merge_branch(window_name="窗口名")\`

状态管理（自动渲染 Board，不要手动编辑 COMMANDER-BOARD.md）：
- \`mcp__tmuxforall__update_agent_status(agent="窗口名", status="done", task="任务")\`
- \`mcp__tmuxforall__add_decision(text="决策内容")\`
- \`mcp__tmuxforall__update_task(task_id="T1", status="done", score="8/10")\`
- \`mcp__tmuxforall__get_project_state()\` — 完整状态 JSON

身份与监控：
- \`mcp__tmuxforall__whoami()\`
- \`mcp__tmuxforall__get_agent_health()\`

学习：
- \`mcp__tmuxforall__record_lesson(task_type="类型", lesson="具体教训")\`

Bash 脚本通信（MCP 不可用时的 fallback）：
- 向上汇报: bash ${SKILL_DIR}/report-up.sh ${WINDOW_NAME} ${PARENT_WIN:-CM} "<摘要>" ${PROJECT}
- 查收邮箱: bash ${SKILL_DIR}/check-mail.sh ${WINDOW_NAME}
- 发送消息: bash ${SKILL_DIR}/send-msg.sh ${ACTUAL_SESSION}:<目标窗口> "消息"
- 派发任务: bash ${SKILL_DIR}/dispatch-task.sh ${ACTUAL_SESSION}:<窗口名> "标题" "验收1" "验收2"
- 记录教训: bash ${SKILL_DIR}/grow-agent.sh ${ROLE_ID} ${PROJECT} "<任务类型>" "<教训>"

Session 当前名称: ${ACTUAL_SESSION}（已注入，直接使用）
若发消息报错"can't find session"，动态查找：
SESSION=\$(tmux list-sessions -F '#{session_name}' | grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1)

## 可用技能（斜杠命令直接调用）
${SKILLS_LIST:-（无预配置技能）}

## 成长记忆（来自历史项目）
${MEMORY_CONTENT}

## 经验沉淀（任务完成时自检）
如果本次任务中你踩了坑或发现了非显而易见的技巧，主动记录：
bash ${SKILL_DIR}/grow-agent.sh ${ROLE_ID} ${PROJECT} "<任务类型>" "<具体教训>"

值得记的（具体、可操作）：
  "ES 8.x aggregate 返回值在 body.aggregations 下不是 body.aggs"
  "Next.js standalone 模式必须用 node server.js 不能用 next start"
不值得记的（泛泛而谈）：
  "要注意错误处理"
  "代码要写得更健壮"

## Bell 通知规则
每次 STATUS 汇报完成后，用 report-up.sh 汇报（它会自动发 bell 给 parent 窗口）。
如需手动 bell，写入自己 pane 的 tty: MY_TTY=\$(tmux display-message -p '#{pane_tty}') && printf '\\a' > "\$MY_TTY"

## 禁止空转等待
- **禁止 sleep 轮询**：不允许 \`sleep N && check\` 循环等待
- **禁止 TaskOutput 阻塞**：不要用 background Task + TaskOutput 等待
- **正确做法**：长任务用 \`nohup cmd > /tmp/output.log 2>&1 &\` 启动，然后汇报"已启动，日志在 /tmp/xxx.log"

## 自检规则
如果连续 3 次工具调用失败（编译错误、测试不过、文件找不到等），立即停止重试：
1. 用 report-up.sh 汇报 BLOCKED，附上错误信息和你已尝试的方法
2. 等待 CM 指示，不要自己换思路继续试

## Context 压缩恢复
如果你发现自己不记得当前任务（迷失、不确定做到哪一步），按以下顺序恢复：
1. \`cat /tmp/tmuxforall-task-*-${WINDOW_NAME}-* 2>/dev/null | tail -50\` — 重读任务文件
2. \`cat /tmp/tmuxforall-wip-*-${WINDOW_NAME}.md 2>/dev/null\` — 查看中间进度（如有）
3. \`git diff --stat\` — 看自己已经改了哪些文件
4. \`bash ${SKILL_DIR}/check-mail.sh ${WINDOW_NAME}\` — 查收未读消息（自动检测 session）
恢复后继续执行，不需要向 CM 汇报"我 compact 了"。
遇到长任务（预计 >15 分钟），中间主动保存进度：
  bash ${SKILL_DIR}/report-up.sh ${WINDOW_NAME} ${PARENT_WIN:-CM} "进行中：已完成X，剩余Y" ${PROJECT} --wip

## 项目上下文
- Session: ${ACTUAL_SESSION}
- 我的窗口名: ${WINDOW_NAME}
- 工作目录: ${AGENT_WORKDIR}
- 主仓库: ${WORKDIR}
- Board: ${WORKDIR}/COMMANDER-BOARD.md
PROMPT

# 创建日志目录
LOG_DIR="${TMUXFORALL_LOG_DIR}/${PROJECT}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/${WINDOW_NAME}-$(date +%Y%m%d).log"

# 创建 tmux 窗口（用 TARGET = session_id 或 session name，不受 session 重命名影响）
tmux new-window -d -t "${TARGET}:" -n "${WINDOW_NAME}" -c "${AGENT_WORKDIR}"
tmux select-pane -t "${TARGET}:${WINDOW_NAME}" -T "${WINDOW_NAME} | 就绪"

# 身份隔离：executor/inspector 用 SIMPLE 模式（禁用全局 CLAUDE.md/MCP/hooks）
# thinker 保留完整功能（需要 WebSearch/WebFetch 等 MCP 工具做调研）
SIMPLE_PREFIX=""
if [[ "$ARCHETYPE_ID" == "executor" || "$ARCHETYPE_ID" == "inspector" ]]; then
  SIMPLE_PREFIX="CLAUDE_CODE_SIMPLE=1 "
fi

# 生成 MCP 消息总线配置（每个 Agent 独立的 AGENT_ID）
MCP_CONFIG_FILE="${TMUXFORALL_TMP}/tmuxforall-mcp-config-${WINDOW_NAME}.json"
MCP_SERVER_PATH="${SKILL_DIR}/mcp_server.py"
VENV_PYTHON="${HOME}/.venv/bin/python3"
if [[ -f "$MCP_SERVER_PATH" && -x "$VENV_PYTHON" ]]; then
  cat > "$MCP_CONFIG_FILE" <<MCPEOF
{"mcpServers":{"tmuxforall":{"type":"stdio","command":"${VENV_PYTHON}","args":["${MCP_SERVER_PATH}"],"env":{"TMUXFORALL_AGENT_ID":"${WINDOW_NAME}","TMUXFORALL_PROJECT":"${PROJECT}"}}}}
MCPEOF
  MCP_FLAG="--mcp-config '${MCP_CONFIG_FILE}' "
else
  MCP_FLAG=""
fi

# 启动 claude（交互持久模式），退出后自动清理 worktree + 分支 + 关闭窗口
CLEANUP_CMD=""
if [[ "$AGENT_WORKDIR" != "$WORKDIR" && "$AGENT_WORKDIR" == */worktrees/* ]]; then
  CLEANUP_CMD="cd '${WORKDIR}' && wt remove '${BRANCH_NAME}' 2>/dev/null; "
fi
tmux send-keys -t "${TARGET}:${WINDOW_NAME}" \
  "${SIMPLE_PREFIX}${TMUXFORALL_CLAUDE_CMD} ${MCP_FLAG}--system-prompt \"\$(cat '${PROMPT_FILE}')\" ; ${CLEANUP_CMD}tmux kill-window" Enter

# 开启 pipe-pane 日志
tmux pipe-pane -t "${TARGET}:${WINDOW_NAME}" \
  "cat >> '${LOG_FILE}'"

# 设置 parent @watching 并注册
if [[ -n "$PARENT_WIN" ]]; then
  bash "${SKILL_DIR}/register-agent.sh" \
    "$PARENT_WIN" "$WINDOW_NAME" "角色孵化" "$PROJECT" || true
fi

# Agent Tracker: 标记任务开始（窗口级追踪）
TRACKER_CLIENT="$HOME/.config/agent-tracker/bin/tracker-client"
if [[ -x "$TRACKER_CLIENT" ]]; then
  NEW_SID="$(tmux display-message -p -t "${TARGET}:${WINDOW_NAME}" '#{session_id}' 2>/dev/null || true)"
  NEW_WID="$(tmux display-message -p -t "${TARGET}:${WINDOW_NAME}" '#{window_id}' 2>/dev/null || true)"
  NEW_PID="$(tmux display-message -p -t "${TARGET}:${WINDOW_NAME}" '#{pane_id}' 2>/dev/null || true)"
  if [[ -n "$NEW_SID" && -n "$NEW_WID" && -n "$NEW_PID" ]]; then
    "$TRACKER_CLIENT" command start_task \
      --session-id "$NEW_SID" --window-id "$NEW_WID" --pane "$NEW_PID" \
      --summary "[${WINDOW_NAME}] ${ROLE_ID} — ${PROJECT}" 2>/dev/null || true
  fi
fi

# --timeout 安全网：空闲超时机制（检测 pane 输出变化，连续无变化则终止）
if [[ -n "$TIMEOUT_MIN" ]]; then
  TIMEOUT_SEC=$((TIMEOUT_MIN * 60))
  CHECK_INTERVAL=60  # 每 60 秒检查一次
  ACTUAL_SESSION="$(tmux display-message -p -t "${TARGET}:" '#{session_name}' 2>/dev/null || echo "$SESSION")"
  nohup bash -c "
    IDLE_SECONDS=0
    LAST_HASH=''
    while true; do
      sleep ${CHECK_INTERVAL}
      # 检查窗口是否还在
      if ! tmux list-windows -t '${ACTUAL_SESSION}' -F '#{window_name}' 2>/dev/null | grep -qx '${WINDOW_NAME}'; then
        break  # 窗口已关，退出
      fi
      # 捕获最后 20 行输出的 hash
      CURRENT_HASH=\$(tmux capture-pane -t '${ACTUAL_SESSION}:${WINDOW_NAME}' -p -S -20 2>/dev/null | md5 -q 2>/dev/null || echo '')
      if [[ -z \"\$CURRENT_HASH\" ]]; then
        break  # 无法捕获，窗口可能已关
      fi
      if [[ \"\$CURRENT_HASH\" == \"\$LAST_HASH\" ]]; then
        IDLE_SECONDS=\$((IDLE_SECONDS + ${CHECK_INTERVAL}))
      else
        IDLE_SECONDS=0
        LAST_HASH=\"\$CURRENT_HASH\"
      fi
      if [[ \$IDLE_SECONDS -ge ${TIMEOUT_SEC} ]]; then
        # 空闲超时，通知 CM 并终止
        bash '${SKILL_DIR}/send-msg.sh' '${ACTUAL_SESSION}:${PARENT_WIN:-CM}' \
          '[TIMEOUT] ${WINDOW_NAME} 空闲 ${TIMEOUT_MIN}min 无输出变化，自动终止'
        tmux send-keys -t '${ACTUAL_SESSION}:${WINDOW_NAME}' Escape 2>/dev/null || true
        sleep 2
        tmux kill-window -t '${ACTUAL_SESSION}:${WINDOW_NAME}' 2>/dev/null || true
        break
      fi
    done
  " > /dev/null 2>&1 &
  echo "[spawn-role] 安全网: 空闲 ${TIMEOUT_MIN}min 无活动则终止 (PID: $!)"
fi

echo "[spawn-role] ${WINDOW_NAME} 已在 ${SESSION} 启动 (workdir: ${AGENT_WORKDIR})"
