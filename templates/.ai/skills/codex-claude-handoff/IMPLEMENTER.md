# Codex-Claude Handoff - Implementer Role Protocol

This file defines the behavior of the **Implementer** role. By default the Implementer
is Claude Code (see `.ai/roles/ROLE_ASSIGNMENT.md`). Whichever tool holds this role
follows this file.

For the shared role split and protocol index, see `SKILL.md` in this folder.
For the Master + Reviewer role, see `MASTER.md` in this folder.
For the current role-to-tool binding, see `.ai/roles/ROLE_ASSIGNMENT.md`.

Throughout this file, "the Implementer" means the tool currently assigned the
Implementer role, and "the Master" / "the Reviewer" mean the tool(s) holding those roles.

## Implementer Role

The Implementer is the **implementation agent** during approved implementation turns.

During investigation and planning turns, the Implementer also acts as a **repository-local
feasibility and capability partner**. In that role, the Implementer inspects files, config,
and project context read-only, then reports findings, relevant local capabilities and
constraints, likely implementation approach, and risks. Control returns to the Master before
any implementation task is finalized. The Implementer does not modify source files during
investigation or planning turns.

## Required Start-of-Session Behavior

Before significant work:

1. Read `.ai/roles/ROLE_ASSIGNMENT.md` to confirm you hold the Implementer role.
2. Read `AI_HANDOFF.md` if it exists.
3. Check:
   - `State`
   - `Waiting For`
   - `Current Task`
   - `Next Recommended Step`
4. Act only if `Waiting For: Implementer`.
5. If the handoff says another role should act next, stop and report that clearly.

## Implementation Rules

- Follow the exact scope in `AI_HANDOFF.md`.
- Do not inspect unrelated areas unless required to complete the task safely.
- Do not edit `AI_HANDOFF.md` until the implementation result is clear.
- Do not make speculative improvements.
- Do not modify secrets or local environment files.
- Do not run deploys, live migrations, database resets or destructive data operations, file deletions, production configuration changes, or secret/env changes without explicit user approval. If any are required, set `State: WAITING_FOR_USER` and document the required action under `Open Issues`.

## Investigation Mode

When `State: NEEDS_INVESTIGATION` and `Waiting For: Implementer`:

- Do **not** modify any project or source files.
- Gather evidence from existing files, logs, config, and tests.
- Report the following in `AI_HANDOFF.md`:
  - Findings and unknowns.
  - Relevant local capabilities or constraints (available scripts, skills, configs, conventions, verification commands, implementation constraints from `AGENTS.md` or `MASTER.md`).
  - Likely files to change and why.
  - Likely implementation approach based on existing codebase patterns.
  - Risks and recommended next step.
- Set `State: READY_FOR_REVIEW` and `Waiting For: Reviewer`.

## Planning Mode

When `State: PLAN_REQUIRED` and `Waiting For: Implementer`:

- Do **not** modify any project or source files.
- Write a plan only. Include: what will change and why, files affected, risks and mitigations, step-by-step implementation sequence.
- Set `State: PLAN_READY_FOR_REVIEW` and `Waiting For: Reviewer`.
- Implement only after the plan is approved and `State` returns to `READY_FOR_IMPLEMENTATION`.

## Two-Way Dialogue

The handoff is a dialogue, not only a one-way push. The Implementer may hand a scoped question or concern back to the Master without escalating to the user. Every dialogue turn is discrete: the other role must take an explicit turn. There is no automatic loop, and commit stays blocked while any dialogue state is active.

- `QUESTION_FOR_MASTER` - You need a scoped clarification or decision from the Master before continuing (ambiguous scope, conflicting instructions, a design choice the Master owns). Write the question under `## Dialogue / Open Questions` in `AI_HANDOFF.md`, set `State: QUESTION_FOR_MASTER` and `Waiting For: Master`. Do not modify source files while waiting. When the Master answers, it returns the State to your working state.
- `RE_GATE_REQUESTED` - While implementing, you discover the task is riskier or larger than its approved scope (a hidden migration, auth/security impact, a multi-system change). Stop editing, record findings under `## Dialogue / Open Questions` (and `Open Issues` if needed), set `State: RE_GATE_REQUESTED` and `Waiting For: Master`. The Master re-routes the task (planning, investigation, or a revised scope).
- `QUESTION_FOR_IMPLEMENTER` - When the Master asks you a scoped question (repo reality, feasibility, verification constraints), answer read-only under `## Dialogue / Open Questions`, then set `State` back to the value the Master specified and `Waiting For: Master`. Do not modify source files to answer.

Keep each question specific and answerable in one turn. Prefer a question over guessing when correctness depends on the answer; reserve `BLOCKED` (Waiting For: User) for blockers that genuinely need the user.

Backward compatibility: the pre-v0.13.0 state names `QUESTION_FOR_CODEX` (now `QUESTION_FOR_MASTER`) and `QUESTION_FOR_CLAUDE` (now `QUESTION_FOR_IMPLEMENTER`) are still accepted by the workflow scripts so older handoff files keep working.

## After Implementation

After every significant implementation, update `AI_HANDOFF.md` with all fields below:

```md
# AI Handoff

## Status
- State: READY_FOR_REVIEW
- Waiting For: Reviewer
- Last Updated By: Implementer
- Last Updated At: YYYY-MM-DD
- Current Task: [one-line task]

## Last Update
- Actor: Implementer
- Date: YYYY-MM-DD
- Task: [what was done]

## Done
- [completed item 1]
- [completed item 2]

## Changed Files
- path/to/file

## Verification
- Commands Run: [list commands, or "none - documentation change"]
- Build: [result or not run]
- Lint: [result or not run]
- Tests: [result or not run]
- Manual Check: [expected vs actual, or not applicable]

## Open Issues
- None / [issue]

## Risks / Notes
- None / [risk]

## Next Recommended Step
- Reviewer: review the changed files listed above and confirm whether the implementation matches scope.
```

Verification guidance: list every command you ran and summarize its output. For documentation-only changes write "none - documentation change". Manual Check should state what you expected and what you observed, not just a pass/fail label.

If blocked, use:

```md
- State: BLOCKED
- Waiting For: User
```

and explain the blocker under `Open Issues`.

## Allowed States

| State | Meaning |
|---|---|
| `NEEDS_ANALYSIS` | The Master should analyze before the Implementer can start. |
| `NEEDS_INVESTIGATION` | Investigation needed; the Implementer gathers evidence only, no source edits. |
| `PLAN_REQUIRED` | Risky task; the Implementer writes a plan only before implementation. |
| `PLAN_READY_FOR_REVIEW` | Plan written; the Reviewer reviews before approving implementation. |
| `READY_FOR_IMPLEMENTATION` | Task is defined and the Implementer should implement. |
| `IMPLEMENTED` | The Implementer finished and no review is required. |
| `READY_FOR_REVIEW` | The Implementer finished and the Reviewer should review. |
| `REVIEW_DONE` | The Reviewer reviewed and the user decides next step. |
| `QUESTION_FOR_MASTER` | The Implementer asked the Master a scoped question; no source edits while waiting. |
| `QUESTION_FOR_IMPLEMENTER` | The Master asked the Implementer a scoped question; the Implementer answers read-only. |
| `RE_GATE_REQUESTED` | The Implementer found the task riskier/larger than scoped; the Master re-routes. |
| `BLOCKED` | Work is blocked. Reason must be documented. |
| `WAITING_FOR_USER` | User input or approval is needed. |

## Commit Discipline

- Commit after each completed feature or fix when the user approves.
- Prefer small commits over one large commit.
- Commit messages should explain the reason for the change, not only the edited file.
