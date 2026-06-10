---
name: codex-claude-handoff
description: Use this skill when working in a project that coordinates Codex and Claude Code through AGENTS.md, CLAUDE.md, and AI_HANDOFF.md.
---

# Codex-Claude Handoff Skill

## Purpose

Use this skill to coordinate AI tools in the same software project using a shared handoff file (`AI_HANDOFF.md`) as the execution state.

## Role Model

The protocol is organized around three roles, plus the User. Roles are bound to concrete tools in `.ai/roles/ROLE_ASSIGNMENT.md`, so they can be reassigned (with user approval) without rewriting the protocol.

- **Master** - decision router, architect, task writer, and coordinator.
- **Implementer** - implementation agent; during investigation and planning turns also a read-only repository-local feasibility and capability partner.
- **Reviewer** - independent review of implementation against approved scope, plus the Verification Gate.
- **The User** - the approval point. Never one of the three roles.

**Default binding:** Master = Codex, Reviewer = Codex, Implementer = Claude Code. This is behaviorally identical to earlier versions of the protocol.

**Invariant:** the Reviewer must never be the same tool as the Implementer (an implementer cannot be the sole reviewer of its own work). Switching roles requires explicit user approval. See `.ai/roles/ROLE_ASSIGNMENT.md`.

The Master role is read-only with respect to source during consultation: the Implementer does not modify source files during investigation or planning turns, and control returns to the Master before any implementation task is finalized.

## Canonical Shared Folder

This file is in `.ai/skills/codex-claude-handoff/`. The following files contain the full protocol:

| File | Contents |
|---|---|
| `SKILL.md` | This file - shared protocol index and role model |
| `MASTER.md` | Master + Reviewer role protocol: decision router, gates, states, review, verification |
| `IMPLEMENTER.md` | Implementer role protocol: investigation mode, planning mode, implementation rules, states |
| `CODEX.md` | Codex entry pointer - resolves Codex's current role(s) and points to the role file |
| `CLAUDE.md` | Claude Code entry pointer - resolves Claude Code's current role(s) and points to the role file |
| `CAPABILITIES.md` | Agent capability profile: what each tool is good at and the default role binding |
| `README.md` | Human-facing overview of this folder |
| `VERSION` | Installed protocol version |

The role-to-tool binding lives one level up, in `.ai/roles/ROLE_ASSIGNMENT.md`.

## How to Resolve Your Behavior

1. Read `.ai/roles/ROLE_ASSIGNMENT.md` to find which role(s) your tool currently holds.
2. If you hold **Master** and/or **Reviewer**: follow `MASTER.md`.
3. If you hold **Implementer**: follow `IMPLEMENTER.md`.
4. The tool-named entry pointers (`CODEX.md`, `CLAUDE.md`) exist only to send each tool to the right role file; they do not define behavior themselves.

## Required Project Files

When this protocol is active, expect these files in the project root:

- `AGENTS.md` - project context plus the Master + Reviewer protocol (read by the tool that follows the AGENTS.md convention)
- `CLAUDE.md` - the operational entry file for Claude Code (resolves its role)
- `AI_HANDOFF.md` - current state, which role acts next, changed files, verification, risks, and next step

## Encoding-Safe Handoff Rule

When a task involves non-English UI text (Hebrew, Arabic, RTL, CJK, or any language with encoding-sensitive characters), every role must follow these rules:

- **Never copy UI text from handoff files.** `AI_HANDOFF.md` and `NEXT_TURN.md` may contain garbled or corrupted characters if the author's terminal encoding was unstable. Do not use that text as a search string, a match pattern, or text to insert.
- **Write semantic English descriptions in handoff files.** Describe what the text means rather than copying the literal characters.
- **Always inspect the source file directly.** Before editing, searching for, or reviewing any UI string, open the actual source file and read the text from there.
- **Point to the exact location.** Reference the file path, component name, line number, or a nearby code comment - not the raw text itself.
- **If exact text is needed for a search or match, derive it from the source file**, not from terminal output or handoff notes.
- **The source of truth for UI text is the source file, not the handoff.**
