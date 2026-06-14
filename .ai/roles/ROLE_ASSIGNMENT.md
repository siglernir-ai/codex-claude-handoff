# Role Assignment

This file binds the protocol's three role tokens to concrete tools. The protocol
docs and scripts are written in role terms (Master / Implementer / Reviewer). This
file is the single place that records which tool currently holds each role.

## Current Binding

| Role | Tool |
|---|---|
| Master | Codex |
| Reviewer | Codex |
| Implementer | Claude Code |

The User is always the approval point and is never one of these roles.

## Role Meanings

- **Master** - decision router, task analysis and classification, gate selection,
  architecture and advisory work, task writing, and coordination.
- **Implementer** - makes approved source edits; during investigation and planning
  turns acts as a read-only repository-local feasibility and capability partner.
- **Reviewer** - independent review of implementation against approved scope, plus
  the Verification Gate.

## Duties Note (since v0.18.0)

- The **Sequence Owner** duty (multi-task ordering and release checkpoints) attaches
  to the Master role. It is not a fourth role. See
  `.ai/skills/codex-claude-handoff/PROTOCOL_METHOD.md`.
- **Operator** actions (pasting prompts, running scripts, committing, tagging) are
  manual user actions, not an AI role. Neither term may be added to the binding
  table above.

## Invariant (must always hold)

- The Reviewer must not be the same tool as the Implementer. An implementer cannot
  be the sole reviewer of its own work. With two tools, one tool holds Master +
  Reviewer and the other holds Implementer, which satisfies this by construction.
- Assigning the same tool to both Implementer and Reviewer is forbidden.

## Switching Roles

- A role swap (for example Master = Claude Code, Implementer = Codex) requires
  explicit user approval. Neither Codex nor Claude Code may switch roles on its own.
- To switch: with user approval, edit the Current Binding table above and keep the
  invariant satisfied. The protocol docs and scripts resolve behavior from this
  table, so no other file needs to change for a swap.

## Tooling Note

- Automation capability is resolved through
  `.ai/skills/codex-claude-handoff/ADAPTERS.md` (since v0.19.0). Role binding says
  which tool holds each role; the adapter registry says whether that role/tool/turn
  is callable.
- `scripts/handoff.ps1 adapters` prints the current resolved adapter status.
- In the default local registry, `cycle` (alias `run-next`) and `loop` can automate
  only `READY_FOR_IMPLEMENTATION` for an Implementer bound to Claude Code. If the
  Implementer is bound to a tool without a verified local adapter (for example
  Codex), these commands block and the Implementer turn must be run manually.
- `cycle` and `loop` enforce the invariant above in their preflight: if the Reviewer
  and the Implementer resolve to the same tool, they block before any automation
  turn runs.
