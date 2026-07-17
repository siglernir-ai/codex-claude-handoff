---
name: codex-claude-handoff
description: Run the project-local Codex to Claude Code to Codex handoff protocol. Use only when the user explicitly selects $codex-claude-handoff, names codex-claude-handoff, or explicitly requests the full Codex-Claude handoff protocol; do not trigger for ordinary project tasks.
---

# Codex-Claude Handoff Skill - Codex Adapter

This is the Codex discovery adapter for the codex-claude-handoff skill.

The canonical shared protocol is at:

  .ai/skills/codex-claude-handoff/

Read the following for full protocol instructions:
- `.ai/skills/codex-claude-handoff/SKILL.md` - shared protocol index and role model
- `.ai/roles/ROLE_ASSIGNMENT.md` - which role(s) you currently hold (default: Codex = Master + Reviewer)
- `.ai/skills/codex-claude-handoff/CODEX.md` - Codex entry pointer; it resolves your role and sends you to `MASTER.md` (Master/Reviewer) or `IMPLEMENTER.md` (Implementer)
