# Agent Capability Profile

This file describes what each agent in the codex-claude-handoff protocol is good at, and when the others should consult it. Codex reads this profile so it can route work to the right agent by default, instead of treating Claude Code only as an executor.

For the shared role split, see `SKILL.md`. For Codex-side behavior, see `CODEX.md`. For Claude Code-side behavior, see `CLAUDE.md`.

## Codex

Strengths:
- Reasoning, planning, and task definition.
- Risk classification and gate selection (investigation vs planning vs implementation).
- Independent review of implementation against approved scope.
- Coordination and decision routing.

Consult Codex when:
- A task needs design, architecture, or risk routing.
- Work must be classified, scoped, or reviewed before or after implementation.

## Claude Code

Strengths:
- Source of truth for what the repository actually does right now.
- File, config, and script inspection in the live working tree.
- Implementation feasibility checks and awareness of local patterns and conventions.
- Running approved local commands (build, lint, test, installer checks) when permitted.

Consult Claude Code by default when correctness depends on:
- Current repository behavior (what the code does now, not what it should do).
- Local implementation details (files, scripts, configs, conventions actually present).
- Verification constraints (which checks exist and what they currently report).

During investigation and planning turns Claude Code is read-only: it reports findings and returns control to Codex before any implementation task is finalized. It does not modify source files in those turns.

## User

Strengths and authority:
- Business intent and product judgment.
- Approval of risk, role changes, and scope.
- Owns commit, push, deploy, database, secrets, and production actions.

The user is the final approval point and must never be bypassed.

## Future Agents

The protocol is forward-compatible with additional agents (for example an independent reviewer such as Gemini). These are not active unless explicitly assigned through a future role model (see the v0.13 role-assignment work). Until assigned, only Codex, Claude Code, and the User hold roles.

## How Codex Uses This Profile

Before finalizing a task that touches the live codebase, Codex should check whether Claude Code's strengths above materially reduce risk. If correctness depends on current repo behavior, local implementation details, or verification constraints, Codex should default to a read-only `NEEDS_INVESTIGATION` pass first. See `CODEX.md` -> "When Claude Adds Value".
