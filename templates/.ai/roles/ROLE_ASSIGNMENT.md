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

- `scripts/handoff.ps1 run-next` can only automate an Implementer bound to Claude
  Code, because only Claude Code has a local CLI. If the Implementer is bound to a
  tool without a local CLI (for example Codex), run-next blocks and the Implementer
  turn must be run manually.
