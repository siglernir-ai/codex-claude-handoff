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

Review Independence: separate-tool
Setup: pending

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

- The Reviewer never shares a context with the Implementer.
- `Review Independence:` (one line, under Current Binding) says how. Any other value or a
  second line blocks every role-dependent command; no line means `separate-tool`.
  - `separate-tool` (default): the Reviewer is a different tool; one tool in both roles is refused.
  - `fresh-context`: one tool may hold both roles. It reviews only in a separate read-only
    run the harness starts (`review-run`, then `review-apply`); commit and release refuse
    any other verdict. A second vendor is the stronger check; two tools are recommended.
- Change it with `handoff.ps1 roles -ReviewIndependence <value>` (recorded in the history).
- `Setup:` (since v3.18.0): a fresh install is `pending` and work commands stop (exit 14)
  until `handoff.ps1 setup` records the user's choice. No line = configured.

## Switching Roles

- A role swap (for example Master = Claude Code, Implementer = Codex) requires
  explicit user approval. Neither Codex nor Claude Code may switch roles on its own.
- To switch: with user approval, edit the Current Binding table above and keep the
  invariant satisfied. The protocol docs and scripts resolve behavior from this
  table. The swap is atomic: in the same turn, synchronize the derived Task Actors
  fields in `AI_HANDOFF.md`, and record what changed, when, and that the user approved
  it. Later turns reread this table and fail closed if the derived actors disagree.

## Tooling Note

- Automation capability is resolved through
  `.ai/skills/codex-claude-handoff/ADAPTERS.md` (since v0.19.0). Role binding says
  which tool holds each role; the adapter registry says whether that role/tool/turn
  is callable.
- `scripts/handoff.ps1 adapters` prints the current resolved adapter status.
- Since v3.5.0 the adapter registry covers every role/tool combination. `cycle`
  (alias `run-next`) and `loop` automate `READY_FOR_IMPLEMENTATION` and
  `NEEDS_INVESTIGATION` for an Implementer bound to either Claude Code or Codex.
- `cycle` and `loop` enforce the invariant above in their preflight: under
  `separate-tool`, if the Reviewer and the Implementer resolve to the same tool, they
  block before any automation turn runs.
