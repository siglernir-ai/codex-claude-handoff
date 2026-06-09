# Codex-Claude Handoff — Shared Skill Folder

This folder is the canonical shared protocol source for the `codex-claude-handoff` skill.

## Files

| File | Purpose |
|---|---|
| `README.md` | This file — human-facing overview |
| `SKILL.md` | Shared protocol index, role split, and tool pointers |
| `CODEX.md` | Codex-specific protocol: decision router, gates, states, and rules |
| `CLAUDE.md` | Claude Code-specific protocol: investigation mode, planning mode, implementation rules |
| `CAPABILITIES.md` | Agent capability profile: what each agent is good at and when to consult it |
| `VERSION` | Installed protocol version |

## Discovery

Both Codex and Claude Code discover this shared folder via lightweight adapter stubs:

- `.agents/skills/codex-claude-handoff/SKILL.md` — Codex adapter, points to this folder
- `.claude/skills/codex-claude-handoff/SKILL.md` — Claude Code adapter, points to this folder

The adapter stubs are small files. All protocol content lives here in `.ai/skills/codex-claude-handoff/`.

## Relationship to Root Files

| File | Role |
|---|---|
| `AGENTS.md` | Codex operational behavior and project context (customized per project) |
| `CLAUDE.md` | Claude Code operational behavior (customized per project) |
| `AI_HANDOFF.md` | Execution state — dynamic, local, not committed |
| `.ai/skills/codex-claude-handoff/` | This folder — shared protocol source of truth |

Root `CLAUDE.md` remains the Claude Code operational behavior file. It is separate from this skill folder.

## Version

See `VERSION` for the installed protocol version.
