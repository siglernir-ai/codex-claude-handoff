# Agent Capability Profile

This file describes what each tool in the codex-claude-handoff protocol is good at. Tool
strengths are stable properties of the tools; the protocol uses them to decide which tool
should hold which role. The role-to-tool binding itself lives in `.ai/roles/ROLE_ASSIGNMENT.md`.

For the shared role model, see `SKILL.md`. For the Master + Reviewer protocol, see `MASTER.md`.
For the Implementer protocol, see `IMPLEMENTER.md`.

## Default Role Binding

| Role | Default Tool | Why |
|---|---|---|
| Master | Codex | Strong at reasoning, planning, task definition, and decision routing |
| Reviewer | Codex | Independent review and risk classification; must differ from the Implementer |
| Implementer | Claude Code | Source of truth for live repo behavior; strong at local inspection and approved edits |

The User is always the approval point and is never one of these roles. Switching the binding
requires explicit user approval, and the Reviewer must never be the same tool as the Implementer.

## Codex

Strengths:
- Reasoning, planning, and task definition.
- Risk classification and gate selection (investigation vs planning vs implementation).
- Independent review of implementation against approved scope.
- Coordination and decision routing.

These strengths are why Codex is the default Master and Reviewer. Consult Codex (as Master) when:
- A task needs design, architecture, or risk routing.
- Work must be classified, scoped, or reviewed before or after implementation.

## Claude Code

Strengths:
- Source of truth for what the repository actually does right now.
- File, config, and script inspection in the live working tree.
- Implementation feasibility checks and awareness of local patterns and conventions.
- Running approved local commands (build, lint, test, installer checks) when permitted.

These strengths are why Claude Code is the default Implementer. Consult the Implementer by default when correctness depends on:
- Current repository behavior (what the code does now, not what it should do).
- Local implementation details (files, scripts, configs, conventions actually present).
- Verification constraints (which checks exist and what they currently report).

During investigation and planning turns the Implementer is read-only: it reports findings and returns control to the Master before any implementation task is finalized. It does not modify source files in those turns.

## User

Strengths and authority:
- Business intent and product judgment.
- Approval of risk, role changes, and scope.
- Owns commit, push, deploy, database, secrets, and production actions.

The user is the final approval point and must never be bypassed.

## Additional Tools

The protocol is forward-compatible with additional tools (for example an independent reviewer such as Gemini). A new tool becomes active only when the user assigns it a role in `.ai/roles/ROLE_ASSIGNMENT.md`. Until assigned, only Codex, Claude Code, and the User participate.

## How the Master Uses This Profile

Before finalizing a task that touches the live codebase, the Master should check whether the Implementer's strengths above materially reduce risk. If correctness depends on current repo behavior, local implementation details, or verification constraints, the Master should default to a read-only `NEEDS_INVESTIGATION` pass first. See `MASTER.md` -> "When the Implementer Adds Value".
