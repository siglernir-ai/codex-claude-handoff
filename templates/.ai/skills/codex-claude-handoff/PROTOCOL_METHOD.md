# Codex-Claude Handoff - Protocol Method Specification

Since v0.18.0. This file is the single normative definition of the protocol's
operating method: its layers, its lifecycle vocabulary, and its precedence rules.

Scope boundaries: this file is normative for the method layers, the lifecycle
mapping, the vocabulary, precedence, and the sequence contract. It is NOT normative
for per-role behavior (see `MASTER.md` and `IMPLEMENTER.md`), the role-to-tool
binding (see `.ai/roles/ROLE_ASSIGNMENT.md`), the safety model (see `ROADMAP.md`,
"Safety Model for Autonomous Dialogue"), adapter capability records (see
`ADAPTERS.md`), or the current task state (see `AI_HANDOFF.md`). It quotes those
sources; it must never alter them.

## Precedence

1. User decisions are always the highest authority.
2. This file defines the method and its vocabulary.
3. The role files (`MASTER.md`, `IMPLEMENTER.md`) define per-role behavior.
4. Prompts and `NEXT_TURN.md` are conveniences. `AI_HANDOFF.md` is authoritative
   for the current task. `AI_SEQUENCE.md` (since v0.18.1) is authoritative only
   for multi-task ordering.

If two documents appear to conflict, resolve in that order and treat the conflict
as Protocol Repair (see Vocabulary).

## The Method in One View

The protocol is ONE method with three layers. Layers 2 and 3 are coordination views
over Layer 1; they never replace or modify it.

### Layer 1 - Per-Task Handoff Method (the frozen core)

One task at a time flows through the role cycle:

```text
User -> Master -> Implementer -> Reviewer -> User
```

- `AI_HANDOFF.md` is the source of truth for the current task.
- The allowed states and their owners are defined in `MASTER.md` ("Allowed States")
  and resolved by the workflow scripts via the role binding.
- Gates: Investigation Gate, Planning Gate, Verification Gate (`MASTER.md`).
- Invariants (quoted authorities - this file does not restate them in new words):
  - "One task per handoff cycle." (`MASTER.md`, "Scope Discipline")
  - The Reviewer must not be the same tool as the Implementer
    (`.ai/roles/ROLE_ASSIGNMENT.md`, "Invariant").
  - Commits, pushes, deploys, database work, and secret changes require explicit
    user approval (`MASTER.md`, "Manual Approval Boundaries").

Nothing in this file changes Layer 1.

### Layer 2 - Sequence Layer (multi-task ordering)

A sequence is an ordered list of Layer 1 tasks that together deliver a larger goal.

- The **Sequence Owner** is a DUTY of the Master role (default: Codex). It is not a
  fourth role and never appears in the role binding table.
- The Sequence Owner maintains the numbered execution plan, feeds the next task into
  `AI_HANDOFF.md` only after the previous task completed its full Layer 1 cycle
  including the user's release approval, and records sequence progress.
- Artifact: `AI_SEQUENCE.md` - its contract is defined below; the artifact ships
  since v0.18.1 (template plus installer support). Sequences are advanced manually
  by the Sequence Owner.

### Layer 3 - Lifecycle Phases (labels over existing machinery)

The end-to-end lifecycle from user idea to release is a set of LABELS over Layer 1
and Layer 2 machinery. A lifecycle phase is never a new state, a new role, or a new
process.

| Lifecycle phase | Is exactly (existing machinery) |
|---|---|
| User idea | natural request via `handoff.ps1 start` or a direct prompt -> the Master's Decision Router (`MASTER.md`) |
| Specification | the Master's task analysis and task writing (NEEDS_ANALYSIS -> a defined task in `AI_HANDOFF.md`) |
| Architecture | Planning Gate output (PLAN_REQUIRED -> PLAN_READY_FOR_REVIEW) |
| Tooling & Capability Plan | `CAPABILITIES.md` consultation plus a read-only NEEDS_INVESTIGATION pass |
| Automation capability | `ADAPTERS.md` resolves role/tool/state to callable or manual behavior |
| Sequence ownership | the Master's Sequence Owner duty (Layer 2): the numbered execution plan |
| Current handoff | `AI_HANDOFF.md` - one task per cycle |
| Implementation | READY_FOR_IMPLEMENTATION -> Implementer turn(s) |
| Review | READY_FOR_REVIEW -> Reviewer; Verification Gate |
| Release | REVIEW_DONE (Reviewer attestation) -> user release authorization -> guarded operator commit/push/tag (Manual Approval Boundaries; since v0.19.1 this may use `handoff.ps1 release`) |
| Sequence update | a Layer 2 progress note, recorded only AFTER the user's release approval (since v0.19.2 the Sequence Owner may use `handoff.ps1 sequence-advance` for this local update) |

Rule: if a future phase cannot be expressed as a mapping to existing machinery, it
is out of scope for this specification and requires its own reviewed protocol
change.

## Vocabulary

- **Sequence** - an ordered list of Layer 1 tasks with per-task status and release
  checkpoints.
- **Sequence Owner** - the Master-role duty that maintains and advances a sequence.
  Not a role.
- **Director** - a reserved future term. Not a role in this version. Reconsider only
  if a third tool exists that could hold a separate coordination seat.
- **Operator** - a manual/mechanical ACTION CATEGORY: pasting a prompt into a tool,
  running a workflow script, committing, tagging, deploying. Operator actions are
  performed by the user (or a human at a terminal). Operator is not an AI role and
  never appears in the role binding.
- **Environment / Preflight Stop** - a STOP CATEGORY, not a state or a role. It maps
  to the existing automation exits: blocked preflight, dirty working tree, or
  invalid arguments (exit 1); missing Claude Code / npx prerequisite or bounded runner start failure (exit 3); Claude Code turn timeout (exit 4);
  NEXT_TURN.md write failure (exit 4). Resolving it is an environment task, not a
  user decision.
- **Protocol Repair** - a STOP CATEGORY, not a state or a role. It maps to the
  existing mismatch and unrecognized-state handling: route to the User, exit 6.
  A conflict between a sequence and `AI_HANDOFF.md` is Protocol Repair: the handoff
  wins for the current task, automation stops, and the user resolves the conflict.
  Protocol Repair is a correction task, not a product decision.
- **User Release Authorization** (since v0.18.2) - a STOP CATEGORY: the Reviewer has
  attested technical readiness (REVIEW_DONE - see `MASTER.md`, "Review Outcomes")
  and the only remaining step is the user's approval to turn reviewed work into a
  commit, push, tag, or release. The user is the authority, not the technical
  verifier: re-running verification is not the user's default duty.
- **User Decision** (since v0.18.2) - a STOP CATEGORY: a product, scope, business,
  or risk decision that only the user can make (WAITING_FOR_USER, a documented
  blocker, or a Decision Router user-decision outcome).
- **Non-callable Actor** (since v0.18.2) - a STOP CATEGORY: automation stops because
  the next role's tool has no callable adapter (for example Master or Reviewer bound
  to Codex), or the turn type cannot be safely automated. This is an automation
  limitation, not a user decision; the next step is an Operator Manual Action
  (paste the prepared prompt into the bound tool).
- **Adapter** (since v0.19.0) - a local capability contract for a role/tool/turn:
  whether it is callable, which existing states it supports, how it is invoked or
  run manually, its safety limits, stop category, and whether user authorization is
  required. Adapters do not add roles, states, or approval authority. See
  `ADAPTERS.md`.

## Stop Routing (since v0.18.2)

Every stop the protocol prints or documents belongs to exactly one category. A stop
names its category, says whether a user decision is required, and says who or what
acts next. Not every stop belongs to the User: most are mechanical, environmental,
or automation-limitation stops.

| Stop category | Typical trigger | Who/what acts next | User decision required? |
|---|---|---|---|
| User Release Authorization | REVIEW_DONE after Reviewer attestation | The user authorizes; an operator action performs the commit/push/tag | Authorization only - not technical re-verification |
| User Decision | WAITING_FOR_USER, a documented blocker | The user decides | Yes |
| Operator Manual Action | paste a prompt, run a script, execute an authorized commit | The user acting as operator (mechanical) | No |
| Protocol Repair | Waiting For mismatch, unrecognized state, contradictory handoff or binding | The user corrects the handoff or binding | No product decision - a correction |
| Environment / Preflight | dirty tree, missing dependency, NEXT_TURN.md failure, invalid arguments, tool unavailable | Whoever controls the environment | No |
| Non-callable Actor | next role's tool has no adapter, or the turn type is not automatable | Operator pastes the prepared prompt into the bound tool | No - automation limitation |

Release execution model (implemented in v0.19.1): Reviewer attestation ->
User Release Authorization -> a guarded operator action may execute the
commit/push/tag. The user remains the only authority for releases; the user is
never the default technical verifier. The guarded release executor must fail
closed unless the handoff is `REVIEW_DONE`, the changed-file scope matches git
status, the actual task Reviewer and actual task Implementer recorded in
`AI_HANDOFF.md` `Task Actors` are present and different, pre-release checks pass,
and the user supplies the exact release authorization token.

Codex Reviewer turn (since v1.2.0, completed v1.3.0): the `review-check` / `review-run`
commands invoke Codex read-only during `READY_FOR_REVIEW` and capture a review verdict to
local, gitignored artifacts. Since v1.3.0 the `review-apply` command reads that captured
verdict and applies the resulting transition: `APPROVED` -> `REVIEW_DONE` / `Waiting For:
User`; `BLOCKED` -> `READY_FOR_IMPLEMENTATION` / `Waiting For: Implementer`. Each command is
a guarded Operator Manual Action requiring an explicit `yes`; `review-run` performs no git
mutation and never transitions `AI_HANDOFF.md`, and `review-apply` edits ONLY `AI_HANDOFF.md`
(no git, no release action) and fails closed on any missing/malformed/stale verdict or failed
guard. Together they make the Reviewer/Codex `READY_FOR_REVIEW` turn callable end-to-end, but
ONLY via these explicit commands - by default the turn is never auto-run by `loop`/`cycle` (the
adapter's `AutoLoopEligible` flag is false). Since v1.4.0 the operator may explicitly opt the
Reviewer turn into a single `loop` session with `loop -IncludeReviewer`, which runs this same
guarded `review-run` + `review-apply` sequence in-session (forcing their non-interactive path
because the loop session was authorized) and routes the verdict the same way: `APPROVED` stops
the loop at `REVIEW_DONE` / `Waiting For: User`, `BLOCKED` returns to
`READY_FOR_IMPLEMENTATION` / `Waiting For: Implementer` and the loop continues under
`MaxTurns`/budget. This opt-in does not change `AutoLoopEligible` (Reviewer/Codex stays
`Auto-loop: no`), and `cycle` still never auto-runs a Reviewer turn. The independent-review
invariant is unchanged: both commands refuse unless the bound and actual Reviewer is Codex and
differs from the actual Implementer. The user's release authorization at `REVIEW_DONE` is also
unchanged. See `ADAPTERS.md`, "Automated Reviewer Turn" and "Opt-in Reviewer Loop Integration".

Codex Master turn (capture since v1.3.1; apply since v2.0.1): the `master-check` /
`master-run` commands invoke Codex read-only as the Master decision router during
`NEEDS_ANALYSIS` and capture a structured routing recommendation to local, gitignored artifacts
(`CODEX_MASTER.jsonl`, `CODEX_MASTER_LAST.md`). Since v2.0.1 the `master-apply` command reads
that captured recommendation and applies the resulting local `AI_HANDOFF.md` transition:
`READY_FOR_IMPLEMENTATION`, `NEEDS_INVESTIGATION`, or `PLAN_REQUIRED` -> `Waiting For:
Implementer`; `BLOCKED` -> `Waiting For: User`. Each command is a guarded Operator Manual
Action requiring an explicit `yes`; `master-run` performs no git mutation and never transitions
`AI_HANDOFF.md`, and `master-apply` edits ONLY `AI_HANDOFF.md` (no git, no release action) and
fails closed on any missing/malformed/stale recommendation, invalid state/actor pairing, or
role-binding mismatch. Together they make the Master/Codex `NEEDS_ANALYSIS` turn callable
end-to-end, but ONLY via explicit commands. Master/Codex is still never auto-run by
`loop`/`cycle` (`Auto-loop: no`); full loop integration remains later work. See `ADAPTERS.md`,
"Automated Master Turn".

## AI_SEQUENCE.md Contract (since v0.18.1)

`AI_SEQUENCE.md`:

- is local and ignored by Git, like `AI_HANDOFF.md`;
- is written by the Sequence Owner (the Master) only after the user approves the
  numbered execution plan;
- owns ONLY: the ordered task list, per-task status (pending / active / released),
  and release checkpoints;
- must never contain per-task execution state (that belongs to `AI_HANDOFF.md`);
- must never advance past a REVIEW_DONE checkpoint without the user's
  commit/release approval;
- must never be committed.

The template ships at `templates/AI_SEQUENCE.md` and the installers copy it to the
project root (no overwrite) and add the `.gitignore` rule.

Since v0.19.2, the Sequence Owner may perform the post-release advance with the local
`handoff.ps1 sequence-advance` command (dry run: `sequence-check`). It verifies the
released commit/tag in git read-only, marks the released task (and any bundled
superseded tasks) `released` with the checkpoint, sets the next task `active`, and
prepares `AI_HANDOFF.md` for the next task. It edits only the local, gitignored
`AI_SEQUENCE.md` and `AI_HANDOFF.md`, fails closed on any unverified or ambiguous
input, and never runs git mutations. It does not advance past a REVIEW_DONE
checkpoint without a supplied, verified release checkpoint.

## Non-Contradiction Rules

Single authority per concern:

| Concern | Single authority |
|---|---|
| Approval of commits, pushes, releases, risky actions | The User (`MASTER.md`, "Manual Approval Boundaries"; `ROADMAP.md` safety model) |
| Per-task routing and gates | The Master via the Decision Router (`MASTER.md`) |
| Multi-task ordering | The Sequence Owner duty (this file, Layer 2) |
| Source edits, investigation, and planning | The Implementer (`IMPLEMENTER.md`) |
| Independent review | The Reviewer (`MASTER.md`; invariant in `ROLE_ASSIGNMENT.md`) |
| Manual adapter actions | The Operator action category (this file) - performed by the user |
| Authorized release execution | Guarded operator action after User Release Authorization; PowerShell `handoff.ps1 release` may execute commit/push/tag only after explicit token authorization |
| Adapter capability and callable/manual status | `ADAPTERS.md` |
| Automation stop semantics | This file, "Stop Routing": workflow scripts must print one of the defined stop categories. Exit codes remain script behavior and must not be redefined as the category system. |
| Release audit provenance | `AI_HANDOFF.md` `Task Actors` for the current task; the global role binding is for routing/adapters, not one-off task provenance |

- New vocabulary must map to existing machinery; this specification may not invent
  states, roles, or automation.
- Documents that need the method refer to this file instead of restating it.
- If wording elsewhere appears to define the method differently, this file wins and
  the discrepancy should be fixed as a documentation task.

## Safe Agent Process Runner (v2.0.0)

PowerShell `cycle`, `run-next`, and `loop` invoke Claude Code through a bounded process runner. The runner preserves the existing Claude Code safety flags, captures stdout/stderr, enforces `-TimeoutSeconds`, and terminates the process tree on timeout. Timeout is a fail-closed environment/preflight stop, not a user decision and not a successful handoff transition. Bash commands remain honest and do not gain a Claude runner.
