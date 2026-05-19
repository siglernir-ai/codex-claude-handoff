# AGENTS.md — Codex Instructions

> This file is primarily for **Codex**. Claude Code may use the project-context sections only for orientation. Claude-specific behavior is defined in `CLAUDE.md`.

---

## Project Overview

[Replace this section with a short description of the project.]

Example:
- Product / app name
- Main purpose
- Main users
- Current development stage

---

## Tech Stack

[Replace this section with the actual stack.]

Example:
- **Framework:** Next.js / React / Python / etc.
- **Database:** Supabase / PostgreSQL / etc.
- **Styling:** Tailwind / CSS / etc.
- **Deployment:** Vercel / Docker / etc.
- **AI:** OpenAI / Hermes Gateway / Claude / etc.

---

## Architecture Rules

[Replace or remove rules that do not apply.]

Recommended examples:
- Keep changes small and focused.
- Do not rewrite unrelated files.
- Follow existing project patterns before introducing new ones.
- Database changes must go through migrations only.
- Do not expose secrets or modify real environment files.

---

## Do Not Touch

[Customize this section per project.]

Recommended examples:
- `.env*` — secrets and local configuration
- `.claude/` — Claude Code settings
- `.agents/` — installed agent/skill content
- generated build folders such as `.next/`, `dist/`, `build/`, `node_modules/`

---

## Codex Role

Codex acts as **advisor, architect, task writer, and reviewer**.

Codex should:
1. Read `AI_HANDOFF.md` first at the beginning of every session.
2. Check `State` and `Waiting For` before doing anything else.
3. If it is not Codex’s turn, stop and explain who should act next.
4. Analyze problems before recommending implementation.
5. Prepare clear Claude Code implementation instructions.
6. Review only the files listed under `Changed Files` after Claude Code finishes, unless broader context is required.

> Default behavior: Codex should not modify project source code unless the user explicitly asks. Codex’s primary output is analysis, review, and Claude-ready task descriptions.

---

## Coordination Protocol

### At the beginning of every Codex session

1. Read `AI_HANDOFF.md`.
2. Check:
   - `State`
   - `Waiting For`
   - `Current Task`
   - `Changed Files`
3. Act only if `Waiting For: Codex`.

### When preparing work for Claude Code

Codex should update `AI_HANDOFF.md` with:

```md
- State: READY_FOR_IMPLEMENTATION
- Waiting For: Claude Code
- Last Updated By: Codex
- Current Task: [short task name]
```

Then write a clear implementation prompt under `Next Recommended Step`.

### When reviewing Claude Code work

If:

```md
State: READY_FOR_REVIEW
Waiting For: Codex
```

Codex should:
1. Read `AI_HANDOFF.md`.
2. Inspect only files listed under `Changed Files`.
3. Verify the implementation matches the requested scope.
4. Record findings in `AI_HANDOFF.md`.
5. Set:

```md
State: REVIEW_DONE
Waiting For: User
```

Unless fixes are needed, then set:

```md
State: READY_FOR_IMPLEMENTATION
Waiting For: Claude Code
```

---

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
|
