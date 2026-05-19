# Codex-Claude Handoff

A simple collaboration protocol for using **Codex** and **Claude Code** together in the same software project.

The goal is to avoid copy-pasting long context between tools.

## Concept

- **Codex** acts as advisor, architect, task writer, and reviewer.
- **Claude Code** acts as the implementation agent.
- Both tools coordinate through a shared file: `AI_HANDOFF.md`.
- The user remains the approval point.

## Files

```text
templates/
  AGENTS.md
  CLAUDE.md
  AI_HANDOFF.md
  gitignore-snippet.txt
```

### `AGENTS.md`
Instructions for Codex.

Use it for:
- project context
- architecture rules
- Codex role
- review rules
- coordination flow

### `CLAUDE.md`
Instructions for Claude Code.

Use it for:
- implementation behavior
- scope discipline
- required handoff updates
- verification reporting

### `AI_HANDOFF.md`
Dynamic handoff file between Codex and Claude Code.

Use it for:
- current state
- who acts next
- current task
- changed files
- verification results
- risks and next step

### `gitignore-snippet.txt`
Optional `.gitignore` rule for keeping `AI_HANDOFF.md` out of Git.

## Recommended Manual Install

From the target project root:

```bash
cp templates/AGENTS.md ./AGENTS.md
cp templates/CLAUDE.md ./CLAUDE.md
cp templates/AI_HANDOFF.md ./AI_HANDOFF.md
cat templates/gitignore-snippet.txt >> .gitignore
```

Then edit:

```text
AGENTS.md
```

and replace the placeholder sections:

- Project Overview
- Tech Stack
- Architecture Rules
- Do Not Touch

## Basic Workflow

### 1. User asks Codex to analyze a task

Codex reads:

```text
AI_HANDOFF.md
AGENTS.md
```

Then Codex prepares the task for Claude Code by setting:

```md
State: READY_FOR_IMPLEMENTATION
Waiting For: Claude Code
```

### 2. Claude Code implements

Claude Code reads:

```text
AI_HANDOFF.md
CLAUDE.md
AGENTS.md
```

Claude Code implements only the requested scope.

After finishing, Claude Code updates `AI_HANDOFF.md` and sets:

```md
State: READY_FOR_REVIEW
Waiting For: Codex
```

### 3. Codex reviews

Codex reviews only files listed under:

```md
## Changed Files
```

Then Codex sets:

```md
State: REVIEW_DONE
Waiting For: User
```

### 4. User approves and commits

The user commits the approved change.

Recommended Git flow:

```bash
git status
git add AGENTS.md CLAUDE.md .gitignore
git commit -m "Add Codex-Claude handoff protocol"
git push
```

Do not commit `AI_HANDOFF.md` if it is listed in `.gitignore`.

## Allowed States

| State | Meaning |
|---|---|
| `NEEDS_ANALYSIS` | Codex should analyze before Claude Code can start. |
| `READY_FOR_IMPLEMENTATION` | Task is defined and Claude Code should implement. |
| `IMPLEMENTED` | Claude Code finished and no review is required. |
| `READY_FOR_REVIEW` | Claude Code finished and Codex should review. |
| `REVIEW_DONE` | Codex reviewed and user decides next step. |
| `BLOCKED` | Work is blocked. Reason must be documented. |
| `WAITING_FOR_USER` | User input or approval is needed. |

## Current Scope

This repository intentionally starts simple:

1. reusable templates
2. manual install instructions
3. optional install script later
4. Codex skill later
5. Claude Code skill later

Avoid jumping directly to automation before the manual workflow is stable.
