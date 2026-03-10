#!/bin/bash
# install.sh — tmuxforall installer
# Checks dependencies, installs skill to ~/.claude/skills/tmuxforall
set -euo pipefail

INSTALL_DIR="${HOME}/.claude/skills/tmuxforall"

echo "tmuxforall — Multi-Agent Collaboration OS on tmux"
echo "=================================================="
echo ""

# === Check dependencies ===
MISSING=0

echo "Checking dependencies..."

# Required
if ! command -v tmux &>/dev/null; then
  echo "  ❌ tmux (required) — install: brew install tmux"
  MISSING=1
else
  TMUX_VER=$(tmux -V | grep -oE '[0-9]+\.[0-9]+')
  echo "  ✅ tmux ${TMUX_VER}"
fi

if ! command -v claude &>/dev/null; then
  echo "  ❌ claude (required) — install: npm install -g @anthropic-ai/claude-code"
  MISSING=1
else
  echo "  ✅ claude (Claude Code CLI)"
fi

if ! command -v git &>/dev/null; then
  echo "  ❌ git (required)"
  MISSING=1
else
  echo "  ✅ git"
fi

# Optional
if command -v wt &>/dev/null; then
  echo "  ✅ worktrunk (wt) — enhanced worktree management"
else
  echo "  ⚡ worktrunk (wt) — optional, improves worktree management"
  echo "     install: go install github.com/theniceboy/worktrunk@latest"
fi

if command -v tracker-client &>/dev/null; then
  echo "  ✅ agent-tracker — real-time task tracking"
else
  echo "  ⚡ agent-tracker — optional, adds task tracking TUI"
  echo "     install: go install github.com/theniceboy/agent-tracker@latest"
fi

echo ""

if [[ $MISSING -eq 1 ]]; then
  echo "❌ Missing required dependencies. Please install them first."
  exit 1
fi

# === Install ===
if [[ -d "$INSTALL_DIR" ]]; then
  echo "⚠️  ${INSTALL_DIR} already exists."
  read -p "Overwrite? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  rm -rf "$INSTALL_DIR"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$(dirname "$INSTALL_DIR")"
cp -r "$SCRIPT_DIR" "$INSTALL_DIR"

# Remove install script from installed copy
rm -f "${INSTALL_DIR}/install.sh"

echo ""
echo "✅ Installed to ${INSTALL_DIR}"
echo ""
echo "Quick start:"
echo "  SKILL=~/.claude/skills/tmuxforall"
echo '  bash $SKILL/bootstrap.sh my-project --dir /path/to/project --budget 3 --goal "Build something"'
echo ""
echo "For standalone roles (no Commander needed):"
echo "  Add to your ~/.zshrc or ~/.bashrc:"
echo '  alias claude-as="bash ~/.claude/skills/tmuxforall/claude-as"'
echo '  alias cl-be="claude-as backend-engineer"'
echo '  alias cl-fe="claude-as frontend-engineer"'
echo '  alias cl-qa="claude-as qa-engineer"'
echo '  alias cl-pm="claude-as product-manager"'
echo ""
echo "See SKILL.md for full documentation."
