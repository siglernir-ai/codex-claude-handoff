# Codex-Claude Handoff - Shared Skill Folder

This folder is the canonical shared protocol source for the `codex-claude-handoff` skill.

## Files

| File | Purpose |
|---|---|
| `README.md` | This file - human-facing overview |
| `SKILL.md` | Shared protocol index and role model |
| `MASTER.md` | Master + Reviewer role protocol: decision router, gates, states, review, verification |
| `IMPLEMENTER.md` | Implementer role protocol: investigation mode, planning mode, implementation rules |
| `PROTOCOL_METHOD.md` | Protocol method specification: method layers, lifecycle mapping, vocabulary, precedence (since v0.18.0) |
| `ADAPTERS.md` | Adapter registry and automation capability contract (since v0.19.0) |
| `CODEX.md` | Codex entry pointer - resolves Codex's role(s) and points to the role file |
| `CLAUDE.md` | Claude Code entry pointer - resolves Claude Code's role(s) and points to the role file |
| CAPABILITIES.md | Agent capability profile: what each tool is good at and the default role binding |
| `CLAUDE_EXECUTION_POLICY.md` | Claude model-policy labels, command transparency, subagent evidence rules, and CLI/window continuity artifacts |
| `VERSION` | Installed protocol version |

The role-to-tool binding lives one level up:

| File | Purpose |
|---|---|
| `.ai/roles/ROLE_ASSIGNMENT.md` | Binds Master / Implementer / Reviewer to concrete tools |

This table is authoritative for role binding. `AI_HANDOFF.md` only displays derived
Task Actors. Each protocol turn checks both files and fails closed on drift or an
invalid Reviewer/Implementer pairing.

## Discovery

Both Codex and Claude Code discover this shared folder via lightweight adapter stubs:

- `.agents/skills/codex-claude-handoff/SKILL.md` - Codex adapter, points to this folder
- `.claude/skills/codex-claude-handoff/SKILL.md` - Claude Code adapter, points to this folder

The adapter stubs are small files. All protocol content lives here in `.ai/skills/codex-claude-handoff/`.

## Resolving Behavior by Role

Behavior is defined by role, not by tool name:

1. Read `.ai/roles/ROLE_ASSIGNMENT.md` to find your current role(s).
2. Master / Reviewer -> follow `MASTER.md`. Implementer -> follow `IMPLEMENTER.md`.
3. `CODEX.md` and `CLAUDE.md` are thin entry pointers that send each tool to the right role file.

## Relationship to Root Files

| File | Role |
|---|---|
| `AGENTS.md` | Project context plus the Master + Reviewer protocol (customized per project) |
| `CLAUDE.md` | Claude Code operational entry file - resolves its role (customized per project) |
| `AI_HANDOFF.md` | Execution state - dynamic, local, not committed |
| `AI_SEQUENCE.md` | Multi-task ordering and progress (since v0.18.1) - dynamic, local, not committed |
| `.ai/skills/codex-claude-handoff/` | This folder - shared protocol source of truth |
| `.ai/roles/ROLE_ASSIGNMENT.md` | Role-to-tool binding |

Root `CLAUDE.md` remains the Claude Code operational entry file. It is separate from this skill folder.

## User Guidance

Since v2.5.0, `handoff.ps1 user-next` shows the single next user action for the current state, including the guarded commit command when review is done.

## Version

See `VERSION` for the installed protocol version.
