#!/bin/bash
# _session_name.sh — 统一生成 tmuxforall session 名称
# 用法: source 后使用 $TF_SESSION
# 规则: 直接用项目名（session manager 会自动加数字前缀如 3-xxx）
#
# 重要: session manager 会给 session 加数字前缀（如 chengguoagent → 3-chengguoagent）
# 所有需要查找已有 session 的地方必须用 tf_find_session() 做模糊匹配
TF_SESSION="${PROJECT}"

# 查找已存在的 session（匹配 PROJECT 或 N-PROJECT 格式）
# 用法: ACTUAL=$(tf_find_session) — 返回实际 session 名（如 3-chengguoagent），无则返回空
tf_find_session() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "^([0-9]+-)?${TF_SESSION}$" | head -1 || echo ""
}
