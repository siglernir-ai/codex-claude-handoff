---
name: codex-claude-handoff
description: Use this skill when working in a project that coordinates Codex and Claude Code through AGENTS.md, CLAUDE.md, and AI_HANDOFF.md.
---

# Codex-Claude Handoff Skill

## Purpose

Use this skill to coordinate Codex and Claude Code in the same software project using a shared handoff file (`AI_HANDOFF.md`) as the execution state.

## Role Split

- **Codex** acts as advisor, architect, task writer, and reviewer.
- **Claude Code** acts as the implementation agent. During investigation and planning turns, Claude Code also acts as a repository-local feasibility and capability partner: it inspects the codebase read-only, reports available local capabilities, likely implementation approach, and risks, and helps Codex produce better task instructions before any implementation is finalized.
- **The user** remains the approval point.

This dual role for Claude Code is read-only during consultation. Claude Code does not modify source files during investigation or planning turns. Control returns to Codex before any implementation task is finalized.

## Canonical Shared Folder

This file is in `.ai/skills/codex-claude-handoff/`. The following files contain the full protocol:

| File | Contents |
|---|---|
| `SKILL.md` | This file - shared protocol index and role split |
| `CODEX.md` | Codex-specific behavior: decision router, gates, states, responsibilities, and rules |
| `CLAUDE.md` | Claude Code-specific behavior: investigation mode, planning mode, implementation rules, and states |
| `CAPABILITIES.md` | Agent capability profile: what each agent is good at and when to consult it |
| `README.md` | Human-facing overview of this folder |
| `VERSION` | Installed protocol version |

## Tool-Specific Protocol

- **Codex:** read `CODEX.md` for the full Codex-side protocol including decision router, gates, states, responsibilities, and rules.
- **Claude Code:** read `CLAUDE.md` for the full Claude Code-side protocol including investigation mode, planning mode, implementation rules, and states.

## Required Project Files

When this protocol is active, expect these files in the project root:

- `AGENTS.md` - Codex behavior, project context, architecture rules, and review rules
- `CLAUDE.md` - Claude Code operational behavior
- `AI_HANDOFF.md` - current state, who acts next, changed files, verification, risks, and next step

## Encoding-Safe Handoff Rule

When a task involves non-English UI text (Hebrew, Arabic, RTL, CJK, or any language with encoding-sensitive characters), both Codex and Claude Code must follow these rules:

- **Never copy UI text from handoff files.** `AI_HANDOFF.md` and `NEXT_TURN.md` may contain garbled or corrupted characters if the author's terminal encoding was unstable. Do not use that text as a search string, a match pattern, or text to insert.
- **Write semantic English descriptions in handoff files.** Describe what the text means rather than copying the literal characters.
- **Always inspect the source file directly.** Before editing, searching for, or reviewing any UI string, open the actual source file and read the text from there.
- **Point to the exact location.** Reference the file path, component name, line number, or a nearby code comment - not the raw text itself.
- **If exact text is needed for a search or match, derive it from the source file**, not from terminal output or handoff notes.
- **The source of truth for UI text is the source file, not the handoff.**
