#!/bin/bash
# _session_name.sh — 统一生成 tmuxforall session 名称
# 用法: source 后使用 $TF_SESSION
# 规则: 直接用项目名（session manager 会自动加数字前缀如 3-xxx）
TF_SESSION="${PROJECT}"
