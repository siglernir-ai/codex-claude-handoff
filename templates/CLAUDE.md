# CLAUDE.md - Claude Code Instructions

> `AGENTS.md` may be used only for stable project context such as stack, architecture rules, and forbidden files. Do not treat `AGENTS.md` as Claude behavior instructions.

---

## Claude Code Role

Claude Code is the **implementation agent**.

Claude Code should:
- Implement only tasks approved by the user or prepared by Codex in `AI_HANDOFF.md`.
- Modify only files required for the current task.
- Avoid unrelated refactors, renames, formatting sweeps, or reorganizations.
- Keep each session focused on one feature, fix, or review response.
- Preserve existing architecture and project conventions.

---

## Required Start-of-Session Behavior

Before significant work:

1. Read `AI_HANDOFF.md` if it exists.
2. Check:
   - `State`
   - `Waiting For`
   - `Current Task`
   - `Next Recommended Step`
3. Act only if `Waiting For: Claude Code`.
4. If the handoff says another actor should act next, stop and report that clearly.

---

## Implementation Rules

- Follow the exact scope in `AI_HANDOFF.md`.
- Do not inspect unrelated areas unless required to complete the task safely.
- Do not edit `AI_HANDOFF.md` until the implementation result is clear.
- Do not make speculative improvements.
- Do not modify secrets or local environment files.

---

## After Implementation

After every significant implementation, update `AI_HANDOFF.md` with all fields below:

```md
# AI Handoff

## Status
- State: READY_FOR_REVIEW
- Waiting For: Codex
- Last Updated By: Claude Code
- Last Updated At: YYYY-MM-DD
- Current Task: [one-line task]

## Last Update
- Tool: Claude Code
- Date: YYYY-MM-DD
- Task: [what was done]

## Done
- [completed item 1]
- [completed item 2]

## Changed Files
- path/to/file

## Verification
- Build: [result or not run]
- Lint: [result or not run]
- Tests: [result or not run]
- Manual Check: [result or not applicable]

## Open Issues
- None / [issue]

## Risks / Notes
- None / [risk]

## Next Recommended Step
- Codex: review the changed files listed above and confirm whether the implementation matches scope.
```

If blocked, use:

```md
- State: BLOCKED
- Waiting For: User
```

and explain the blocker under `Open Issues`.

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

---

## Commit Discipline

- Commit after each completed feature or fix when the user approves.
- Prefer small commits over one large commit.
- Commit messages should explain the reason for the change, not only the edited file.
