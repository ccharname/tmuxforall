# Growth Memory

This directory stores cross-project lessons learned by each role.

When an agent of a given role spawns, the last 60 lines of its memory file
are injected into its system prompt — so it starts with the wisdom of its predecessors.

Files are auto-created by `grow-agent.sh` and auto-compacted by `compact-memory.sh`
when entries exceed 50.

Example:
```
backend-engineer.md
frontend-engineer.md
commander.md
```
