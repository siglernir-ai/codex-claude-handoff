# AI Sequence

> This file is LOCAL and IGNORED by Git - never commit it. It owns only multi-task
> ordering: the ordered task list, per-task status, and release checkpoints.
> Per-task execution state belongs to `AI_HANDOFF.md`, which remains the source of
> truth for the current task. The Sequence Owner is a duty of the Master role.
> Contract: `.ai/skills/codex-claude-handoff/PROTOCOL_METHOD.md`.

## Sequence
- Name: [short sequence name]
- Owner: Master (Sequence Owner duty)
- User-approved plan: [date or reference - required before the first task runs]

## Tasks

| # | Task | Status | Release checkpoint |
|---|---|---|---|
| 1 | [one-line task description] | pending | - |
| 2 | [one-line task description] | pending | - |

Status values: `pending`, `active`, `released`.

- At most one task is `active` at a time, and it must match the Current Task in
  `AI_HANDOFF.md`.
- A task becomes `released` only after the user approves and performs the
  commit/tag for it. The sequence never advances past a REVIEW_DONE checkpoint
  without that approval.

## Sequence Notes
- [ordering decisions and progress notes only - never per-task execution state]
