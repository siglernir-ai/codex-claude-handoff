# Codex-Claude Handoff - Claude Code Protocol

Use this file for Claude Code-specific behavior in the Codex-Claude handoff protocol.

For the shared role split and protocol index, see `SKILL.md` in this folder.
For Codex-specific behavior, see `CODEX.md` in this folder.

## Claude Code Role

Claude Code is the **implementation agent** during approved implementation turns.

During investigation and planning turns, Claude Code also acts as a **repository-local feasibility and capability partner**. In that role, Claude Code inspects files, config, and project context read-only, then reports findings, relevant local capabilities and constraints, likely implementation approach, and risks. Control returns to Codex before any implementation task is finalized. Claude Code does not modify source files during investigation or planning turns.

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

## Implementation Rules

- Follow the exact scope in `AI_HANDOFF.md`.
- Do not inspect unrelated areas unless required to complete the task safely.
- Do not edit `AI_HANDOFF.md` until the implementation result is clear.
- Do not make speculative improvements.
- Do not modify secrets or local environment files.
- Do not run deploys, live migrations, database resets or destructive data operations, file deletions, production configuration changes, or secret/env changes without explicit user approval. If any are required, set `State: WAITING_FOR_USER` and document the required action under `Open Issues`.

## Investigation Mode

When `State: NEEDS_INVESTIGATION` and `Waiting For: Claude Code`:

- Do **not** modify any project or source files.
- Gather evidence from existing files, logs, config, and tests.
- Report the following in `AI_HANDOFF.md`:
  - Findings and unknowns.
  - Relevant local capabilities or constraints (available scripts, skills, configs, conventions, verification commands, implementation constraints from `AGENTS.md` or `CLAUDE.md`).
  - Likely files to change and why.
  - Likely implementation approach based on existing codebase patterns.
  - Risks and recommended next step.
- Set `State: READY_FOR_REVIEW` and `Waiting For: Codex`.

## Planning Mode

When `State: PLAN_REQUIRED` and `Waiting For: Claude Code`:

- Do **not** modify any project or source files.
- Write a plan only. Include: what will change and why, files affected, risks and mitigations, step-by-step implementation sequence.
- Set `State: PLAN_READY_FOR_REVIEW` and `Waiting For: Codex`.
- Implement only after the plan is approved and `State` returns to `READY_FOR_IMPLEMENTATION`.

## Two-Way Dialogue

The handoff is a dialogue, not only a one-way push. Claude Code may hand a scoped question or concern back to Codex without escalating to the user. Every dialogue turn is discrete: the other actor must take an explicit turn. There is no automatic loop, and commit stays blocked while any dialogue state is active.

- `QUESTION_FOR_CODEX` - You need a scoped clarification or decision from Codex before continuing (ambiguous scope, conflicting instructions, a design choice Codex owns). Write the question under `## Dialogue / Open Questions` in `AI_HANDOFF.md`, set `State: QUESTION_FOR_CODEX` and `Waiting For: Codex`. Do not modify source files while waiting. When Codex answers, it returns the State to your working state.
- `RE_GATE_REQUESTED` - While implementing, you discover the task is riskier or larger than its approved scope (a hidden migration, auth/security impact, a multi-system change). Stop editing, record findings under `## Dialogue / Open Questions` (and `Open Issues` if needed), set `State: RE_GATE_REQUESTED` and `Waiting For: Codex`. Codex re-routes the task (planning, investigation, or a revised scope).
- `QUESTION_FOR_CLAUDE` - When Codex asks you a scoped question (repo reality, feasibility, verification constraints), answer read-only under `## Dialogue / Open Questions`, then set `State` back to the value Codex specified and `Waiting For: Codex`. Do not modify source files to answer.

Keep each question specific and answerable in one turn. Prefer a question over guessing when correctness depends on the answer; reserve `BLOCKED` (Waiting For: User) for blockers that genuinely need the user.

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
- Codex: review the changed files listed above and confirm whether the implementation matches scope.
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
| `NEEDS_ANALYSIS` | Codex should analyze before Claude Code can start. |
| `NEEDS_INVESTIGATION` | Investigation needed; Claude Code gathers evidence only, no source edits. |
| `PLAN_REQUIRED` | Risky task; Claude Code writes a plan only before implementation. |
| `PLAN_READY_FOR_REVIEW` | Plan written; Codex reviews before approving implementation. |
| `READY_FOR_IMPLEMENTATION` | Task is defined and Claude Code should implement. |
| `IMPLEMENTED` | Claude Code finished and no review is required. |
| `READY_FOR_REVIEW` | Claude Code finished and Codex should review. |
| `REVIEW_DONE` | Codex reviewed and user decides next step. |
| `QUESTION_FOR_CODEX` | Claude Code asked Codex a scoped question; no source edits while waiting. |
| `QUESTION_FOR_CLAUDE` | Codex asked Claude Code a scoped question; Claude answers read-only. |
| `RE_GATE_REQUESTED` | Claude Code found the task riskier/larger than scoped; Codex re-routes. |
| `BLOCKED` | Work is blocked. Reason must be documented. |
| `WAITING_FOR_USER` | User input or approval is needed. |

## Commit Discipline

- Commit after each completed feature or fix when the user approves.
- Prefer small commits over one large commit.
- Commit messages should explain the reason for the change, not only the edited file.
