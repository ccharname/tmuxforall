#!/usr/bin/env python3
"""tmuxforall MCP Server — 多 Agent 协作操作系统的结构化接口

三层架构：
  Level 1: Bash 脚本薄包装（spawn/dispatch/mail 等操作通过 subprocess 调用现有脚本）
  Level 2: Board 状态管理（结构化 JSON 状态 + 自动渲染 COMMANDER-BOARD.md）
  Level 3: 智能路由（检测 agent 存活/忙闲状态，自动选择最优投递方式）

每个 Agent 通过环境变量标识：
  TMUXFORALL_AGENT_ID — 窗口名（如 CM, BE, FE）
  TMUXFORALL_PROJECT  — 项目名
  TMUXFORALL_WORKDIR  — 项目工作目录（可选，自动从 tmux 推导）
"""

import fcntl
import json
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

from mcp.server.fastmcp import FastMCP

# ── 配置 ──────────────────────────────────────────────────────────────

SKILL_DIR = Path(__file__).parent
TMP_DIR = Path(os.environ.get("TMUXFORALL_TMP", os.environ.get("TMPDIR", "/tmp")))
AGENT_ID = os.environ.get("TMUXFORALL_AGENT_ID", "unknown")
PROJECT = os.environ.get("TMUXFORALL_PROJECT", "")
WORKDIR = os.environ.get("TMUXFORALL_WORKDIR", "")

mcp = FastMCP("tmuxforall")


# ── Level 3: Agent 健康检测 ──────────────────────────────────────────

def _tmux_run(args: list[str], timeout: int = 5) -> str | None:
    """执行 tmux 命令，失败返回 None"""
    try:
        r = subprocess.run(
            ["tmux"] + args, capture_output=True, text=True, timeout=timeout
        )
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None


def _resolve_session() -> str:
    """动态解析 session 名（兼容 N-xxx 重命名）"""
    if not PROJECT:
        return ""
    sessions = _tmux_run(["list-sessions", "-F", "#{session_name}"])
    if not sessions:
        return PROJECT
    for s in sessions.strip().split("\n"):
        s = s.strip()
        # 精确匹配 PROJECT 或 N-PROJECT（session manager 数字前缀）
        if s == PROJECT:
            return s
        parts = s.split("-", 1)
        if len(parts) == 2 and parts[0].isdigit() and parts[1] == PROJECT:
            return s
    return PROJECT


def _resolve_workdir() -> str:
    """推导项目工作目录"""
    if WORKDIR:
        return WORKDIR
    session = _resolve_session()
    if session:
        # 从 CM 窗口获取
        wd = _tmux_run(["display-message", "-p", "-t", f"{session}:CM",
                        "#{pane_current_path}"])
        if wd:
            return wd
        wd = _tmux_run(["display-message", "-p", "-t", f"{session}:",
                        "#{session_path}"])
        if wd:
            return wd
    return os.getcwd()


class AgentHealth:
    """Agent 健康状态"""
    ALIVE_IDLE = "alive_idle"      # 在 ❯ 提示符，空闲
    ALIVE_BUSY = "alive_busy"      # 正在工作
    DEAD = "dead"                  # 窗口不存在或进程已退出


def _check_agent_health(window_name: str) -> str:
    """检测 agent 存活和忙闲状态"""
    session = _resolve_session()
    if not session:
        return AgentHealth.DEAD

    # 检查窗口是否存在
    windows = _tmux_run(["list-windows", "-t", session, "-F", "#{window_name}"])
    if not windows or window_name not in windows.split("\n"):
        return AgentHealth.DEAD

    # 检查最后几行是否有 ❯ 提示符（空闲标志）
    last_lines = _tmux_run([
        "capture-pane", "-t", f"{session}:{window_name}", "-p", "-S", "-5"
    ])
    if last_lines and any(line.strip().startswith("❯") and len(line.strip()) <= 2
                          for line in last_lines.split("\n")):
        return AgentHealth.ALIVE_IDLE

    return AgentHealth.ALIVE_BUSY


# ── Level 2: 结构化状态管理 ──────────────────────────────────────────

def _state_path() -> Path:
    """状态文件路径（项目级共享）"""
    return TMP_DIR / f"tmuxforall-state-{PROJECT}.json"


def _board_path() -> str:
    """Board markdown 文件路径"""
    wd = _resolve_workdir()
    return os.path.join(wd, "COMMANDER-BOARD.md")


def _default_state() -> dict:
    """默认空状态"""
    return {
        "project": PROJECT,
        "session": _resolve_session(),
        "updated_at": "",
        "goal": "",
        "phase": "待定",
        "budget": {"initial": 3, "min": 2, "max": 4},
        "agents": {},
        "tasks": {},
        "decisions": [],
        "message_buffer": {},  # L3: 死亡 agent 的待投递消息
    }


def _load_state() -> dict:
    """加载状态（带文件锁）"""
    sp = _state_path()
    if not sp.exists():
        return _default_state()
    try:
        with open(sp, "r") as f:
            fcntl.flock(f, fcntl.LOCK_SH)
            data = json.load(f)
            fcntl.flock(f, fcntl.LOCK_UN)
        return data
    except (json.JSONDecodeError, OSError):
        return _default_state()


def _save_state(state: dict, render_board: bool = True):
    """保存状态 + 可选自动渲染 Board"""
    state["updated_at"] = datetime.now().strftime("%Y-%m-%d %H:%M")
    state["session"] = _resolve_session()
    sp = _state_path()
    with open(sp, "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        json.dump(state, f, ensure_ascii=False, indent=2)
        fcntl.flock(f, fcntl.LOCK_UN)

    if render_board:
        _render_board(state)


def _render_board(state: dict):
    """从结构化状态渲染 COMMANDER-BOARD.md"""
    bp = _board_path()
    if not bp:
        return

    budget = state.get("budget", {})
    agents = state.get("agents", {})
    tasks = state.get("tasks", {})
    decisions = state.get("decisions", [])
    active_count = sum(1 for a in agents.values()
                       if a.get("status") not in ("released", "done", ""))
    now = state.get("updated_at", "")

    lines = []
    lines.append(f"# {state['project']} Commander Board\n")
    lines.append(f"> 更新时间: {now} | 初始预算: N={budget.get('initial', '?')} "
                 f"| 活跃: {active_count} | 自主范围: [{budget.get('min', '?')}, "
                 f"{budget.get('max', '?')}] | MAX_AGENTS={budget.get('max', 8) + 4}\n")

    # 项目目标
    lines.append("## 项目目标")
    lines.append(f"> {state.get('goal', '（待填写）')}\n")

    # 当前阶段
    lines.append("## 当前阶段")
    lines.append(f"{state.get('phase', '待定')}\n")
    lines.append("---\n")

    # Agent 状态矩阵
    lines.append("## Agent 状态矩阵\n")
    lines.append("| Agent | 角色 | 状态 | 当前任务 | 阻塞 | 上次更新 |")
    lines.append("|-------|------|------|---------|------|---------|")
    for aid, info in agents.items():
        status_icon = {
            "idle": "🟢空闲", "working": "🟡工作中", "blocked": "🔴阻塞",
            "done": "✅完成", "released": "⬜释放", "compact": "🟡compact",
        }.get(info.get("status", ""), info.get("status", "?"))
        lines.append(
            f"| {aid} | {info.get('role', '?')} | {status_icon} "
            f"| {info.get('task', '')} | {info.get('blocker', '无')} "
            f"| {info.get('updated', '')} |"
        )
    lines.append("\n---\n")

    # Agent 树
    lines.append("## Agent 树（注册记录）\n")
    lines.append("```")
    cm_children = [aid for aid, info in agents.items()
                   if info.get("parent") == "CM" and aid != "CM"]
    lines.append("CM (Commander)")
    for child in cm_children:
        child_info = agents.get(child, {})
        lines.append(f"├── {child} ({child_info.get('role', '?')})")
    lines.append("```\n")

    # 注册记录（保留兼容性）
    for aid, info in agents.items():
        if aid == "CM":
            continue
        parent = info.get("parent", "CM")
        reg_time = info.get("registered", "")
        lines.append(f"[注册] {aid} ← {parent} | 任务: {info.get('task', '角色孵化')}"
                     f" | 时间: {reg_time}")
    lines.append("<!-- register-agent.sh 自动追加 -->\n")
    lines.append("---\n")

    # 文件锁
    lines.append("## 文件锁\n")
    lines.append("| Agent | 文件 | 时间 |")
    lines.append("|-------|------|------|\n")
    lines.append("<!-- Agent 编辑文件时写入，完成后删除 -->\n")
    lines.append("---\n")

    # 待决策项
    lines.append("## 待决策项\n")
    lines.append("> Commander 必须处理以下问题（收到后10分钟内响应）\n")
    lines.append("<!-- 格式：- [ ] [优先级] 问题描述（来自 Agent名, HH:MM） -->\n")
    lines.append("---\n")

    # 决策日志
    lines.append("## 决策日志\n")
    for d in decisions:
        lines.append(f"- {d.get('time', '')} {d.get('text', '')}")
    lines.append("\n---\n")

    # 任务队列
    lines.append("## 任务队列\n")

    pending = [(tid, t) for tid, t in tasks.items()
               if t.get("status") == "pending"]
    in_progress = [(tid, t) for tid, t in tasks.items()
                   if t.get("status") == "in_progress"]
    completed = [(tid, t) for tid, t in tasks.items()
                 if t.get("status") in ("done", "completed")]

    lines.append("### 🔴 待派发")
    for tid, t in pending:
        lines.append(f"- {tid}-{t.get('title', '?')}")

    lines.append("\n### 🟡 进行中")
    for tid, t in in_progress:
        assignee = t.get("assignee", "?")
        started = t.get("started", "?")
        lines.append(f"- {tid}-{t.get('title', '?')}（负责：{assignee}，开始：{started}）")

    lines.append("\n### 🟢 已完成")
    for tid, t in completed:
        assignee = t.get("assignee", "?")
        done_time = t.get("completed", "?")
        score = t.get("score", "")
        score_str = f"，评分：{score}" if score else ""
        lines.append(
            f"- {tid}-{t.get('title', '?')}（负责：{assignee}，完成：{done_time}"
            f"{score_str}）"
        )
    lines.append("")

    try:
        with open(bp, "w") as f:
            f.write("\n".join(lines))
    except OSError:
        pass  # Board 渲染失败不影响工具执行


# ── Level 1: Bash 脚本执行器 ────────────────────────────────────────

def _run_script(script_name: str, args: list[str], timeout: int = 30) -> str:
    """执行 tmuxforall bash 脚本并返回输出"""
    script_path = SKILL_DIR / script_name
    if not script_path.exists():
        return f"[ERROR] 脚本不存在: {script_name}"

    cmd = ["bash", str(script_path)] + args
    env = {
        **os.environ,
        "TMUXFORALL_TMP": str(TMP_DIR),
        "TMUXFORALL_PROJECT": PROJECT,
        "PROJECT": PROJECT,
    }

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, env=env
        )
        output = result.stdout.strip()
        stderr = result.stderr.strip()
        if result.returncode != 0:
            return f"[ERROR] {script_name} 返回 {result.returncode}\n{stderr}\n{output}"
        # 合并 stdout + stderr（很多脚本用 stderr 输出状态信息）
        parts = [p for p in [output, stderr] if p]
        return "\n".join(parts) if parts else "(completed)"
    except subprocess.TimeoutExpired:
        return f"[TIMEOUT] {script_name} 超时 ({timeout}s)"
    except Exception as e:
        return f"[ERROR] {script_name}: {e}"


def _mailbox_path(agent_id: str) -> Path:
    return TMP_DIR / f"tmuxforall-mailbox-{agent_id}.txt"


def _smart_bell(target: str):
    """tmux bell 通知（写入 pane tty）"""
    session = _resolve_session()
    if not session:
        return
    tty = _tmux_run(["display-message", "-p", "-t",
                     f"{session}:{target}", "#{pane_tty}"])
    if tty and os.path.exists(tty) and os.access(tty, os.W_OK):
        try:
            with open(tty, "w") as f:
                f.write("\a")
        except OSError:
            pass


def _smart_deliver(target: str, content: str, session: str):
    """L3 智能投递：根据 agent 健康状态选择最优投递方式"""
    health = _check_agent_health(target)

    if health == AgentHealth.DEAD:
        # 缓存消息，等 agent 重生后投递
        state = _load_state()
        buf = state.setdefault("message_buffer", {})
        buf.setdefault(target, []).append({
            "from": AGENT_ID,
            "content": content,
            "time": datetime.now().strftime("%H:%M:%S"),
        })
        _save_state(state, render_board=False)
        return f"[缓存] {target} 已死亡，消息已缓存（共 {len(buf[target])} 条待投递）"

    # 写入邮箱（统一格式，与 send-msg.sh 兼容）
    mailbox = _mailbox_path(target)
    timestamp = datetime.now().strftime("%H:%M:%S")
    msg = f"--- [{timestamp}] from {AGENT_ID} ---\n{content}\n\n"
    with open(mailbox, "a") as f:
        f.write(msg)

    if health == AgentHealth.ALIVE_IDLE:
        # 空闲：直接粘贴 check-mail 指令触发读取
        _tmux_run(["send-keys", "-t", f"{session}:{target}", "-l",
                   f"收到 {AGENT_ID} 的消息，请 check-mail 处理"])
        time.sleep(0.3)
        _tmux_run(["send-keys", "-t", f"{session}:{target}", "Escape"])
        time.sleep(0.1)
        _tmux_run(["send-keys", "-t", f"{session}:{target}", "Enter"])
        return f"[直投] {target} 空闲，已写入邮箱 + 直接触发 check-mail"

    # busy: 只写邮箱 + bell
    _smart_bell(target)
    return f"[邮箱] {target} 忙碌，已写入邮箱 + bell 通知"


def _flush_buffered_messages(target: str):
    """投递缓存的消息（agent 重生后调用）"""
    state = _load_state()
    buf = state.get("message_buffer", {})
    messages = buf.pop(target, [])
    if not messages:
        return

    mailbox = _mailbox_path(target)
    with open(mailbox, "a") as f:
        for msg in messages:
            f.write(f"--- [{msg['time']}] from {msg['from']} (buffered) ---\n"
                    f"{msg['content']}\n\n")
    _save_state(state, render_board=False)
    _smart_bell(target)


# ── MCP Tools: 通信 ─────────────────────────────────────────────────

@mcp.tool()
def send_message(to: str, content: str) -> str:
    """向另一个 Agent 发送消息（智能路由：自动检测目标状态选择最优投递）。

    投递策略：
    - 目标空闲 → 写入邮箱 + 直接触发 check-mail
    - 目标忙碌 → 写入邮箱 + bell 通知
    - 目标死亡 → 缓存消息，重生后自动投递

    Args:
        to: 目标窗口名（如 CM, BE, FE）
        content: 消息内容
    """
    session = _resolve_session()
    return _smart_deliver(to, content, session)


@mcp.tool()
def check_messages() -> str:
    """检查并读取自己的邮箱。读取后清空。"""
    mailbox = _mailbox_path(AGENT_ID)
    if not mailbox.exists() or mailbox.stat().st_size == 0:
        return "（无新邮件）"

    content = mailbox.read_text().strip()
    if not content:
        return "（无新邮件）"

    # 清空邮箱
    with open(mailbox, "w") as f:
        pass

    return content


@mcp.tool()
def dispatch_task(target: str, title: str, criteria: str = "") -> str:
    """向 Agent 派发任务（写入任务文件 + 粘贴 cat 指令）。

    同时更新 Board 状态中的任务记录和 agent 状态。

    Args:
        target: 目标窗口名（如 BE, FE, QA）
        title: 任务标题
        criteria: 验收标准（多条用换行分隔）
    """
    session = _resolve_session()
    full_target = f"{session}:{target}"

    # 构建 dispatch-task.sh 参数
    args = [full_target, title]
    if criteria:
        args.extend(criteria.split("\n"))

    result = _run_script("dispatch-task.sh", args, timeout=30)

    # L2: 更新状态
    state = _load_state()
    now = datetime.now().strftime("%H:%M")

    # 更新 agent 状态
    if target in state.get("agents", {}):
        state["agents"][target]["status"] = "working"
        state["agents"][target]["task"] = title[:50]
        state["agents"][target]["updated"] = now

    # 添加/更新任务
    task_id = f"T{len(state.get('tasks', {})) + 1}"
    state.setdefault("tasks", {})[task_id] = {
        "title": title,
        "assignee": target,
        "status": "in_progress",
        "started": now,
    }
    _save_state(state)

    return result


@mcp.tool()
def report_up(summary: str, parent: str = "CM", wip: bool = False) -> str:
    """向上级汇报任务完成或中间进度。

    自动更新 Board 状态、通知 parent、设置 tmux @unread。

    Args:
        summary: 汇报摘要
        parent: 上级窗口名（默认 CM）
        wip: 是否中间进度（True=只保存进度文件，不发完成信号）
    """
    session = _resolve_session()
    args = [AGENT_ID, parent, summary, PROJECT]
    if wip:
        args.append("--wip")

    result = _run_script("report-up.sh", args, timeout=15)

    # L2: 更新状态
    state = _load_state()
    now = datetime.now().strftime("%H:%M")
    if AGENT_ID in state.get("agents", {}):
        if wip:
            state["agents"][AGENT_ID]["updated"] = now
        else:
            state["agents"][AGENT_ID]["status"] = "done"
            state["agents"][AGENT_ID]["updated"] = now

    # 更新关联任务状态
    if not wip:
        for tid, task in state.get("tasks", {}).items():
            if task.get("assignee") == AGENT_ID and task.get("status") == "in_progress":
                task["status"] = "done"
                task["completed"] = now
                break
    _save_state(state)

    return result


@mcp.tool()
def broadcast(content: str) -> str:
    """向所有 Agent 广播消息（不包括自己）。"""
    return _run_script("broadcast.sh", [PROJECT, content], timeout=15)


# ── MCP Tools: 生命周期 ─────────────────────────────────────────────

@mcp.tool()
def spawn_role(
    role_id: str,
    archetype: str = "",
    scope: str = "",
    display: str = "",
    timeout: int = 0,
    parent: str = "CM",
) -> str:
    """孵化新 Agent（创建 tmux 窗口 + worktree + 角色注入）。

    优先使用动态角色（根据项目需求自定义命名），不要硬套 FE/BE/QA。

    Args:
        role_id: 角色 ID（预定义如 backend-engineer，或自定义如 data-cleaner）
        archetype: 动态角色原型（executor/inspector/thinker），无 YAML 时必填
        scope: 职责范围（如 "backend/ api/"）
        display: 角色描述（一句话）
        timeout: 超时安全网（分钟，0=不限）
        parent: 上级窗口名（默认 CM）
    """
    args = [role_id, PROJECT, "--parent", parent]
    if archetype:
        args.extend(["--archetype", archetype])
    if scope:
        args.extend(["--scope", scope])
    if display:
        args.extend(["--display", display])
    if timeout > 0:
        args.extend(["--timeout", str(timeout)])

    result = _run_script("spawn-role.sh", args, timeout=60)

    # L2: 注册 agent 到状态
    state = _load_state()
    now = datetime.now().strftime("%H:%M")

    # 推导窗口名（从 spawn-role.sh 输出解析，或用 role_id 大写）
    window_name = role_id.upper().replace("-", "")
    # 尝试从输出解析实际窗口名
    for line in result.split("\n"):
        if "已在" in line and "启动" in line:
            # "[spawn-role] BE 已在 my-project 启动"
            parts = line.split("]", 1)
            if len(parts) > 1:
                name_part = parts[1].strip().split(" ")[0]
                if name_part:
                    window_name = name_part
                    break

    state.setdefault("agents", {})[window_name] = {
        "role": display or role_id,
        "status": "idle",
        "task": "",
        "blocker": "",
        "parent": parent,
        "registered": now,
        "updated": now,
    }
    _save_state(state)

    # L3: 投递缓存的消息
    _flush_buffered_messages(window_name)

    return result


@mcp.tool()
def restart_agent(target: str, timeout: int = 0) -> str:
    """重启卡死的 Agent（保留窗口位，重建 claude 进程）。

    Args:
        target: 目标窗口名（如 BE, FE）
        timeout: 重启后超时安全网（分钟）
    """
    session = _resolve_session()
    full_target = f"{session}:{target}"
    args = [full_target, PROJECT]
    if timeout > 0:
        args.extend(["--timeout", str(timeout)])

    result = _run_script("restart-agent.sh", args, timeout=30)

    # L2: 更新状态
    state = _load_state()
    now = datetime.now().strftime("%H:%M")
    if target in state.get("agents", {}):
        state["agents"][target]["status"] = "idle"
        state["agents"][target]["updated"] = now
    _save_state(state)

    # L3: 投递缓存的消息
    _flush_buffered_messages(target)

    return result


# ── MCP Tools: 状态管理 (Level 2) ───────────────────────────────────

@mcp.tool()
def update_agent_status(
    agent: str,
    status: str,
    task: str = "",
    blocker: str = "",
) -> str:
    """更新 Agent 状态（自动渲染 Board）。

    比直接编辑 COMMANDER-BOARD.md 更安全——不会格式错乱。

    Args:
        agent: 窗口名（如 BE, FE, QA）
        status: 状态（idle/working/blocked/done/released/compact）
        task: 当前任务描述
        blocker: 阻塞原因（无则留空）
    """
    state = _load_state()
    now = datetime.now().strftime("%H:%M")
    agents = state.setdefault("agents", {})
    if agent not in agents:
        agents[agent] = {"role": "?", "parent": "CM", "registered": now}
    agents[agent]["status"] = status
    if task:
        agents[agent]["task"] = task
    agents[agent]["blocker"] = blocker or "无"
    agents[agent]["updated"] = now
    _save_state(state)
    return f"✓ {agent} 状态已更新: {status}"


@mcp.tool()
def add_decision(text: str) -> str:
    """添加决策日志条目（自动渲染 Board）。

    Args:
        text: 决策描述
    """
    state = _load_state()
    now = datetime.now().strftime("%H:%M")
    state.setdefault("decisions", []).append({"time": now, "text": text})
    _save_state(state)
    return f"✓ 决策已记录: {now} {text}"


@mcp.tool()
def update_task(
    task_id: str,
    status: str = "",
    assignee: str = "",
    title: str = "",
    score: str = "",
) -> str:
    """更新任务状态（自动渲染 Board）。

    Args:
        task_id: 任务 ID（如 T1, T2）
        status: 状态（pending/in_progress/done）
        assignee: 负责 agent
        title: 任务标题
        score: 评分（如 8/10）
    """
    state = _load_state()
    now = datetime.now().strftime("%H:%M")
    tasks = state.setdefault("tasks", {})
    if task_id not in tasks:
        tasks[task_id] = {"title": title or "?", "started": now}
    if status:
        tasks[task_id]["status"] = status
        if status in ("done", "completed"):
            tasks[task_id]["completed"] = now
    if assignee:
        tasks[task_id]["assignee"] = assignee
    if title:
        tasks[task_id]["title"] = title
    if score:
        tasks[task_id]["score"] = score
    _save_state(state)
    return f"✓ {task_id} 已更新"


@mcp.tool()
def set_project_info(goal: str = "", phase: str = "") -> str:
    """设置项目目标或当前阶段（自动渲染 Board）。

    Args:
        goal: 项目目标（一句话）
        phase: 当前阶段
    """
    state = _load_state()
    if goal:
        state["goal"] = goal
    if phase:
        state["phase"] = phase
    _save_state(state)
    parts = []
    if goal:
        parts.append(f"目标: {goal}")
    if phase:
        parts.append(f"阶段: {phase}")
    return "✓ " + " | ".join(parts)


@mcp.tool()
def set_budget(initial: int = 0, min_agents: int = 0, max_agents: int = 0) -> str:
    """设置 Agent 预算参数。

    Args:
        initial: 初始预算 N
        min_agents: 自主范围下限
        max_agents: 自主范围上限
    """
    state = _load_state()
    budget = state.setdefault("budget", {})
    if initial > 0:
        budget["initial"] = initial
    if min_agents > 0:
        budget["min"] = min_agents
    if max_agents > 0:
        budget["max"] = max_agents
    _save_state(state)
    return f"✓ 预算已更新: {budget}"


@mcp.tool()
def get_project_state() -> str:
    """获取项目完整状态（结构化 JSON）。

    返回所有 agent 状态、任务队列、决策日志、消息缓存的完整快照。
    比读 Board markdown 更结构化，适合程序化处理。
    """
    state = _load_state()

    # L3: 附加实时健康状态
    for agent_id in state.get("agents", {}):
        health = _check_agent_health(agent_id)
        state["agents"][agent_id]["health"] = health

    # 附加消息缓存统计
    buf = state.get("message_buffer", {})
    state["buffered_messages_summary"] = {
        k: len(v) for k, v in buf.items() if v
    }

    return json.dumps(state, ensure_ascii=False, indent=2)


# ── MCP Tools: 监控 ─────────────────────────────────────────────────

@mcp.tool()
def get_dashboard() -> str:
    """获取项目状态仪表板（窗口列表 + 活动摘要 + Board + Agent 健康）。"""
    result = _run_script("dashboard.sh", [PROJECT], timeout=15)

    # 补充 L3 健康信息
    state = _load_state()
    health_lines = ["\n[Agent 健康状态（实时）]"]
    for agent_id in state.get("agents", {}):
        h = _check_agent_health(agent_id)
        icon = {"alive_idle": "🟢", "alive_busy": "🟡", "dead": "💀"}.get(h, "?")
        health_lines.append(f"  {icon} {agent_id}: {h}")

    buf = state.get("message_buffer", {})
    if any(v for v in buf.values()):
        health_lines.append("\n[消息缓存（待投递）]")
        for target, msgs in buf.items():
            if msgs:
                health_lines.append(f"  📨 {target}: {len(msgs)} 条待投递")

    return result + "\n".join(health_lines)


@mcp.tool()
def get_agent_health(agent: str = "") -> str:
    """检测 agent 存活和忙闲状态。

    Args:
        agent: 窗口名（留空则检测所有已注册 agent）
    """
    state = _load_state()
    agents_to_check = [agent] if agent else list(state.get("agents", {}).keys())

    results = []
    for aid in agents_to_check:
        h = _check_agent_health(aid)
        icon = {"alive_idle": "🟢空闲", "alive_busy": "🟡忙碌",
                "dead": "💀已死亡"}.get(h, h)
        results.append(f"{aid}: {icon}")

        # 如果发现死亡，检查是否有缓存消息
        if h == AgentHealth.DEAD:
            buf = state.get("message_buffer", {}).get(aid, [])
            if buf:
                results.append(f"  └ {len(buf)} 条消息待投递（重生后自动投递）")

    return "\n".join(results)


# ── MCP Tools: Git ───────────────────────────────────────────────────

@mcp.tool()
def merge_branch(window_name: str) -> str:
    """合并 Agent 的 feature 分支到 main（CM 专用）。

    Args:
        window_name: 要合并的 Agent 窗口名
    """
    result = _run_script("merge-to-main.sh", [PROJECT, window_name], timeout=60)

    # L2: 更新状态
    state = _load_state()
    if window_name in state.get("agents", {}):
        state["agents"][window_name]["status"] = "released"
        state["agents"][window_name]["updated"] = datetime.now().strftime("%H:%M")
    _save_state(state)

    return result


# ── MCP Tools: 学习 ─────────────────────────────────────────────────

@mcp.tool()
def record_lesson(task_type: str, lesson: str) -> str:
    """记录跨项目成长教训。

    值得记的（具体、可操作）：
      "ES 8.x aggregate 返回值在 body.aggregations 下不是 body.aggs"
    不值得记的（泛泛而谈）：
      "要注意错误处理"

    Args:
        task_type: 任务类型（如 component-dev, api-design）
        lesson: 具体教训
    """
    # 从状态推导 role_id
    state = _load_state()
    agent_info = state.get("agents", {}).get(AGENT_ID, {})
    role_id = agent_info.get("role", AGENT_ID).lower().replace(" ", "-")

    return _run_script("grow-agent.sh",
                       [role_id, PROJECT, task_type, lesson], timeout=15)


# ── MCP Tools: 后台任务 ─────────────────────────────────────────────

@mcp.tool()
def invoke_intern(
    role_id: str,
    task: str,
    output: str = "",
    parent: str = "CM",
) -> str:
    """以实习生模式后台调用角色（不占窗口不占预算）。

    读角色 YAML → system prompt → 后台 claude -p → 结果写文件 → 通知。

    Args:
        role_id: 角色 ID（如 backend-engineer, qa-engineer）
        task: 任务描述
        output: 输出文件路径（默认自动生成）
        parent: 完成后通知的窗口（默认 CM）
    """
    args = [role_id, PROJECT, task]
    if output:
        args.extend(["--output", output])
    if parent != "CM":
        args.extend(["--parent", parent])

    return _run_script("invoke-intern.sh", args, timeout=15)


# ── MCP Tools: 身份 ─────────────────────────────────────────────────

@mcp.tool()
def whoami() -> str:
    """返回当前 Agent 的身份和上下文信息。"""
    state = _load_state()
    agent_info = state.get("agents", {}).get(AGENT_ID, {})
    health = _check_agent_health(AGENT_ID)

    info = {
        "agent_id": AGENT_ID,
        "project": PROJECT,
        "session": _resolve_session(),
        "workdir": _resolve_workdir(),
        "role": agent_info.get("role", "unknown"),
        "status": agent_info.get("status", "unknown"),
        "health": health,
        "pid": os.getpid(),
        "mailbox": str(_mailbox_path(AGENT_ID)),
    }
    return json.dumps(info, ensure_ascii=False, indent=2)


# ── MCP Tools: 初始化状态 ───────────────────────────────────────────

@mcp.tool()
def init_project_state(
    goal: str = "",
    budget: int = 3,
) -> str:
    """初始化项目状态（bootstrap 后调用一次）。

    从现有 Board markdown 导入状态，或创建全新状态。
    如果状态文件已存在，跳过（幂等）。

    Args:
        goal: 项目目标
        budget: Agent 预算
    """
    sp = _state_path()
    if sp.exists():
        state = _load_state()
        if state.get("agents"):
            return f"状态已存在（{len(state['agents'])} 个 agent），跳过初始化"

    import math
    state = _default_state()
    state["goal"] = goal
    state["budget"] = {
        "initial": budget,
        "min": math.ceil(budget * 0.5),
        "max": math.floor(budget * 1.5),
    }
    now = datetime.now().strftime("%H:%M")
    state["agents"]["CM"] = {
        "role": "Commander",
        "status": "idle",
        "task": "",
        "blocker": "无",
        "parent": "",
        "registered": now,
        "updated": now,
    }
    _save_state(state)
    return f"✓ 项目状态已初始化 (budget={budget}, goal={goal or '待填写'})"


# ── 启动 ─────────────────────────────────────────────────────────────

# 注册自身到状态（如果状态文件存在）
if PROJECT:
    try:
        state = _load_state()
        if AGENT_ID in state.get("agents", {}):
            state["agents"][AGENT_ID]["health"] = "alive"
            _save_state(state, render_board=False)
    except Exception:
        pass

if __name__ == "__main__":
    mcp.run()
