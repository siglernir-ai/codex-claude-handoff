---
name: codex-claude-handoff
description: >-
  Turn Codex and Claude Code into an accountable engineering pair on one Git
  task: one agent leads or implements, a different agent challenges and reviews,
  rejected work can return for bounded correction, and neither ships alone.
  Durable project-local state preserves scope, decisions, evidence, and the next
  actor across windows and CLI turns; exact-scope and fail-closed checks stop
  unsafe or inconsistent progress, while the user retains approval over sensitive
  actions. Roles can be swapped with explicit user approval. Use when the user
  explicitly selects or names codex-claude-handoff, requests cross-agent
  implementation and independent review, setup, diagnosis, role reassignment, or
  the full supervised workflow. Do not trigger for ordinary project tasks. On
  first use, request approval before installing the bundled protocol.
license: Apache-2.0
metadata:
  status: public-beta
  version: "3.3.1"
---

# Codex-Claude Handoff

**One drives. One challenges. Neither ships alone.**

The handoff is only the transport. The product is an accountable engineering
workflow between Codex and Claude Code on the same live Git task. By default,
Codex routes and scopes, Claude Code investigates or implements, Codex reviews
independently, and the user approves sensitive actions.

The agents do not merely pass a summary, run the same prompt in parallel, or let
the Implementer grade its own work. They share durable task state, can challenge
assumptions through scoped questions, and can send a rejected implementation back
for correction. The automated review/correction path is bounded by turn, time, and
budget limits. General question dialogue still advances through explicit turns.

## What makes it different

- **One accountable task, not two disconnected answers.** Both agents work from
  the same durable state, scope, decisions, and evidence in the Git project.
- **One implements; another challenges.** The Reviewer must remain different from
  the Implementer and can reject the work instead of merely commenting on it.
- **Correction is part of the protocol.** A blocked review can return the exact
  approved scope for another bounded implementation pass.
- **Continuity survives tool boundaries.** Project-local files preserve the next
  actor and the reasoning needed to resume across VS Code windows and CLI turns.
- Fails closed on inconsistent roles, scope mismatches, no-progress turns,
  timeouts, or malformed review output.
- Keeps roles configurable: with explicit user approval, Codex and Claude Code can
  exchange Master and Implementer responsibilities.
- Requires the Reviewer to remain different from the Implementer. Automation
  availability depends on the verified adapter for the selected role and tool.
- Stops before commit, push, tag, release, deploy, database, or secret actions
  until the user provides the protocol's exact authorization.

Run this skill only after explicit user activation.

## First use

Check for `.ai/skills/codex-claude-handoff/SKILL.md` in the project root.

If it is missing:

1. Explain that setup copies project-local protocol files and updates `.gitignore`.
2. Obtain explicit user approval before running setup.
3. On Windows, run the bundled `scripts/setup.ps1`. Prefer the copy under
   `.agents/skills/codex-claude-handoff/`; fall back to `.claude/skills/`.
4. On macOS/Linux, run the bundled `scripts/setup.sh` from the same locations.
5. Do not download or execute any additional remote code. The setup payload is
   bundled inside this skill.
6. Report the doctor result and tell the user which stable files should be
   reviewed and committed. Do not commit them automatically.

## Installed workflow

When the canonical protocol exists:

1. Read `.ai/roles/ROLE_ASSIGNMENT.md` and confirm the current role.
2. Read `.ai/skills/codex-claude-handoff/SKILL.md` for the shared protocol index.
3. Read `.ai/skills/codex-claude-handoff/CODEX.md` when acting as Codex, or
   `.ai/skills/codex-claude-handoff/CLAUDE.md` when acting as Claude Code.
4. Read `AI_HANDOFF.md` and continue according to its current state.

The default binding is Codex as Master + Reviewer and Claude Code as Implementer.
Do not change the binding without explicit user approval. After an approved role
swap, keep Reviewer and Implementer different and follow `ADAPTERS.md` for the
automation supported by the new binding.

## Safety

- This is a public beta intended for supervised, human-in-the-loop use.
- Never commit, push, tag, release, deploy, change a database, or change secrets
  without the protocol's exact user authorization.
- Keep local coordination and evidence files out of Git.
- If setup, role binding, scope, or state is inconsistent, stop and report the
  blocker instead of guessing.
