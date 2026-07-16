# Codex-Claude Handoff - Adapter Registry

Since v0.19.0. This file defines the automation adapter contract and the default
local adapter registry. It does not add roles or states.

## Adapter Contract

An adapter is a local capability record that tells workflow automation whether a
role/tool turn can be invoked automatically, must be run manually, is blocked by
environment, or is only future-supported.

Each adapter record must define:

| Field | Meaning |
|---|---|
| `role` | One of the existing protocol roles: Master, Implementer, or Reviewer. |
| `tool` | The concrete tool currently bound to the role in `.ai/roles/ROLE_ASSIGNMENT.md`. |
| `callable` | `yes` only when a verified local invocation path exists for that role/tool/turn; otherwise `no`. |
| `supported states` | The existing handoff states the adapter may automate. Empty means no automated states. |
| `invocation command or manual instruction` | The exact local command for callable adapters, or the manual paste instruction for non-callable adapters. |
| `safety limits` | Boundaries the adapter must enforce before and during invocation. |
| `stop category when not callable` | One of the stop categories in `PROTOCOL_METHOD.md`, usually `Non-callable Actor` or `Environment/Preflight`. |
| `user authorization required` | Whether the adapter may proceed only after explicit user authorization. |

Adapter records are capability descriptions, not authority. The user remains the
approval authority for commits, pushes, tags, deploys, database work, secrets,
production configuration, role swaps, and product decisions.

## Default Local Registry

These records describe only capabilities present in this repository's local
workflow scripts. They do not assume an API, MCP server, Codex CLI, or external
orchestrator exists.

| Role | Default tool | Callable | Supported states | Invocation or manual instruction | Safety limits | Stop category when not callable | User authorization required |
|---|---|---|---|---|---|---|---|
| Master | Codex | yes, explicit-command only (NEEDS_ANALYSIS) | `NEEDS_ANALYSIS` | Capture: `handoff.ps1 master-run`. Apply: `handoff.ps1 master-apply` (since v2.0.1). Together they complete the Master's `NEEDS_ANALYSIS` routing turn end-to-end. Since v2.1.0, `loop -IncludeMaster` may opt this exact turn into one loop session. For other states, paste the generated prompt into Codex. | Explicit `yes` per command, or explicit `loop -IncludeMaster` for one authorized loop session; bound Master is Codex; captured `TASK` must match Current Task; recommendation/Waiting For pair must be valid; non-`BLOCKED` routing must use the current bound Implementer and Reviewer and preserve Reviewer != Implementer; `master-apply` edits only `AI_HANDOFF.md`; not auto-run by default and never by `cycle`; no git add/commit/push/tag/deploy/db/secrets. | Operator Manual Action | yes, explicit `yes` before `master-run` and `master-apply`; loop session authorization when `-IncludeMaster` is used |
| Implementer | Claude Code | yes | `READY_FOR_IMPLEMENTATION` only | `bounded PowerShell runner -> npx --yes @anthropic-ai/claude-code -p "<prompt>" --permission-mode acceptEdits --disallowed-tools "Bash" --max-budget-usd N --no-session-persistence --output-format text` via `handoff.ps1 cycle`, `run-next`, or `loop`. | Explicit `yes` confirmation (interactive `yes` or `-Yes`); Reviewer != Implementer; clean tree except local handoff files, or an exact `Changed Files` match after a Reviewer `BLOCKED` verdict; Bash disallowed; budget cap; hard timeout; stdout/stderr capture; process-tree kill on timeout; post-turn no-op/no-progress guard (v2.6.0); exact-scope interrupted-correction recovery may route only to the independent Reviewer (v3.1.5); no commit/push/tag/deploy/db/secrets automation. | Non-callable Actor for unsupported Implementer states; Environment/Preflight when `npx` or Claude Code is unavailable | yes, explicit confirmation before each `cycle` or loop session |
| Reviewer | Codex | yes, explicit-command only (READY_FOR_REVIEW) | `READY_FOR_REVIEW` | Capture: `handoff.ps1 review-run`. Apply: `handoff.ps1 review-apply` (since v1.3.0). Together they complete the Reviewer's `READY_FOR_REVIEW` turn end-to-end. For other states, paste the generated prompt into Codex. | Explicit `yes` per command; bound and actual Reviewer is Codex and != actual Implementer; Changed Files == git status; Codex read-only (no `--ask-for-approval` / `--dangerously-bypass` / danger-full-access); `review-apply` edits only `AI_HANDOFF.md`; not auto-run by `loop`/`cycle` by default (callable != loop-eligible); since v1.4.0 `loop -IncludeReviewer` may opt in to auto-run this exact turn in-session, `cycle` never does; no commit/push/tag/deploy/db/secrets; no release action. | Operator Manual Action | yes, explicit `yes` before `review-run` and `review-apply`; commit/release stay separate User authorizations |

## Approved Commit Execution Adapter

Commit execution is an authorized operator action, not a protocol role turn. It is
documented here because Window Mode needs one guarded local capability after Reviewer
approval without forcing the user to type raw git commands.

| Capability | Callable | Eligible state | Invocation | Safety limits | Stop category when unavailable or unauthorized | User authorization required |
|---|---|---|---|---|---|---|
| Approved commit executor | yes, PowerShell only | `REVIEW_DONE` with `Waiting For: User` | Dry-run: `handoff.ps1 commit-check [-Message "<msg>"]`. Execute: `handoff.ps1 commit-approved -Message "<msg>" -Authorize "I_AUTHORIZE_COMMIT"`. | Requires actual task Reviewer != actual task Implementer from `AI_HANDOFF.md` `Task Actors`, exact Changed Files vs git status match, explicit authorization token, and no push/tag/deploy/db/secrets actions. Commits only the approved Changed Files and excludes local coordination files. | Environment/Preflight when PowerShell is unavailable; User Commit Authorization until the token is supplied | yes, exact token required for execution |

## Release Execution Adapter

Release execution is an authorized operator action, not a protocol role turn. It is
documented here because it is a callable local capability with the same safety
contract shape as role adapters.

| Capability | Callable | Eligible state | Invocation | Safety limits | Stop category when unavailable or unauthorized | User authorization required |
|---|---|---|---|---|---|---|
| Authorized release executor | yes, PowerShell only | `REVIEW_DONE` with `Waiting For: User` | Dry-run: `handoff.ps1 release-check -Version vX.Y.Z`. Execute: `handoff.ps1 release -Version vX.Y.Z -Message "<msg>" -Authorize "I_AUTHORIZE_RELEASE_vX.Y.Z"`. | Requires actual task Reviewer != actual task Implementer from `AI_HANDOFF.md` `Task Actors`, exact Changed Files vs git status match, existing pre-release checks, explicit authorization token, commit before tag, and no deploy/db/secrets/production-config actions. | Environment/Preflight when PowerShell is unavailable; User Release Authorization until the token is supplied | yes, exact token required for execution |

## State-Specific Notes

- `READY_FOR_IMPLEMENTATION` can be automated only when the Implementer is bound
  to Claude Code and the local Claude Code CLI path is available.
- `NEEDS_INVESTIGATION`, `PLAN_REQUIRED`, and `QUESTION_FOR_IMPLEMENTER` remain
  manual. The current Claude Code CLI invocation cannot be safely
  restricted to handoff-only edits in non-interactive mode.
- Since v2.0.1 the Master/Codex `NEEDS_ANALYSIS` turn is callable end-to-end via the
  explicit `master-run` + `master-apply` commands - see "Automated Master Turn" below. Since
  v2.1.0, `loop -IncludeMaster` may opt that same guarded turn into one loop session; it is
  still not auto-run by default and `cycle` never runs it. Since v1.3.0 the Reviewer/Codex
  `READY_FOR_REVIEW` turn is callable via the explicit `review-run` + `review-apply`
  commands - see "Automated Reviewer Turn" below. It is likewise not loop/cycle eligible by
  default.
- `callable` is not the same as `loop`/`cycle` eligible. The adapter model carries a
  separate `AutoLoopEligible` flag: `loop` and `cycle` gate on `AutoLoopEligible`, never on
  `callable`, so an explicit-command-only adapter (Reviewer/Codex) makes `loop` STOP rather
  than auto-run a turn. Only `READY_FOR_IMPLEMENTATION` / Implementer / Claude Code is
  `AutoLoopEligible`. Since v2.1.0 there is an explicit, operator-opted-in Master exception:
  `loop -IncludeMaster` may auto-run the Codex Master's `NEEDS_ANALYSIS` turn in-session (see
  "Opt-in Master Loop Integration" below). Since v1.4.0 there is also an explicit Reviewer
  exception:
  `loop -IncludeReviewer` may auto-run the Codex Reviewer's `READY_FOR_REVIEW` turn in-session
  (see "Opt-in Reviewer Loop Integration" below). These opt-ins do NOT change the
  `AutoLoopEligible` flag (Master/Codex and Reviewer/Codex stay `Auto-loop: no` in the
  `adapters` view), and `cycle` still never auto-runs Master or Reviewer turns.
- Codex was not callable through v1.2.0: a discovered Codex CLI binary - even with a passing
  read-only `codex exec` smoke test - was not sufficient on its own, and the v1.2.0
  `review-check` / `review-run` POC was capture-only. Since v1.3.0, the Reviewer/Codex
  `READY_FOR_REVIEW` turn is callable end-to-end via `review-run` + `review-apply` (read-only
  capture then a fail-closed local `AI_HANDOFF.md` transition). Since v2.0.1, the
  Master/Codex `NEEDS_ANALYSIS` turn is callable end-to-end via `master-run` + `master-apply`.
  All other Codex roles/states remain non-callable. See "Codex CLI Verification", "Automated
  Reviewer Turn", "Automated Master Turn", and the opt-in loop integration sections below.
- Since v0.19.1, `release-check` and `release` are PowerShell-only. Bash reports the
  limitation honestly and does not run release git mutations. `review-apply` (v1.3.0) is
  likewise PowerShell-only; Bash refuses honestly.

## Script Contract

Workflow scripts must resolve automation through this adapter model:

1. State -> expected role (`MASTER.md` state table and script action map).
2. Role -> bound tool (`.ai/roles/ROLE_ASSIGNMENT.md`).
3. Role/tool/state -> adapter capability (this contract).
4. If callable, run only through the adapter's invocation command and safety
   limits.
5. If non-callable, print the stop category, reason, manual instruction, and next
   enablement step.

The `adapters` command in `scripts/handoff.ps1` and `scripts/handoff.sh` prints
the current resolved role registry plus the approved commit and release executor
capabilities for the local project.

Since v3.0.0, the PowerShell helper also exposes two user-facing read-only local
commands for supervised daily operation:

- `handoff.ps1 doctor` checks the local protocol install and environment health
  with OK/WARN/INFO output. It never mutates files, runs AI tools, commits, pushes,
  tags, deploys, touches databases, or changes secrets.
- `handoff.ps1 work` prints the daily workflow view: State, Waiting For, Current
  Task, and the exact next action. For tool turns it points to
  `.\scripts\handoff.ps1 next -Clip`; for `REVIEW_DONE / Waiting For: User` it
  prints the guarded `commit-approved` command.

Commit/release execution is not a role turn and does not approve work. It is a
guarded operator action after the Reviewer has attested technical readiness and
the user has supplied the exact authorization token.

For release audit, the executor reads the current task's actual actors from
`AI_HANDOFF.md`:

```md
## Task Actors
- Implementer: Codex
- Reviewer: Claude Code
```

The global role binding remains the routing/adapters source of truth. It is not
enough for release audit when a task used an explicit one-off actor assignment.

## Local Sequence Advance (since v0.19.2)

`handoff.ps1 sequence-check` (dry run) and `handoff.ps1 sequence-advance` (apply)
update local coordination after a released checkpoint. They are not a role turn and
do not approve work. `sequence-advance` verifies the released commit and tag in git
read-only, marks the released task (and any `-SupersededVersions` bundled tasks)
`released` with the checkpoint, sets the next task `active`, and prepares
`AI_HANDOFF.md` for the next task (`NEEDS_ANALYSIS` / `Waiting For: Master`, Task
Actors `TBD`). They edit only the local, gitignored `AI_SEQUENCE.md` and
`AI_HANDOFF.md`, fail closed on any missing/unverified/ambiguous input, and never run
git add/commit/push/tag, deploys, database, or secret actions. They are
PowerShell-only; Bash refuses honestly and points to PowerShell.

## Codex CLI Verification (v1.1.0)

A bundled Codex CLI may be present on a machine (an OpenAI Codex install exposing a
`codex exec` non-interactive subcommand, plus `review` and `mcp-server` subcommands).
Discovering such a binary does NOT make Codex callable in this protocol.

Before any Codex role/turn may be recorded `callable: yes`, a verification turn must
demonstrate, and this registry must record, all of the following:

1. Read-only safety: a `codex exec` invocation, constrained by a read-only sandbox,
   reads `AI_HANDOFF.md` / `NEXT_TURN.md` without writing or editing any file it was not
   authorized to change.
2. Determinism: the invocation produces structured, parseable output the workflow
   scripts can consume (for example via `--output-last-message` and/or `--json`).
3. Bounded approval: the path never requires
   `--dangerously-bypass-approvals-and-sandbox` or danger-full-access.
4. Reviewer independence: a Codex Reviewer adapter is admissible only when Codex is
   not also that task's Implementer. The invariant in `.ai/roles/ROLE_ASSIGNMENT.md`
   and the `Task Actors` release audit continue to apply unchanged.

Status as of v1.1.0: a read-only `codex exec` smoke test has been run successfully.
Using `codex exec --cd <repo> --sandbox read-only --ephemeral --json
--output-last-message <tempfile> <prompt>`, the CLI read `AI_HANDOFF.md`, emitted JSONL
events, wrote the expected final message `CODEX_READONLY_SMOKE_OK`, and left `git
status` unchanged. That demonstrates criteria 1-2 (read-only safety; deterministic,
parseable output) for a one-off manual run, executed under a read-only sandbox with no
bypass flag (criterion 3).

At v1.1.0 this smoke test was still not enough to mark Codex `callable: yes`: no
protocol wrapper/adapter had been implemented and tested, and nothing yet wired a per-turn
Codex invocation into the workflow scripts with enforced read-only sandboxing, output
capture, and Reviewer independence (criterion 4). The verified candidate invocation shape
above became the basis for the later Reviewer and Master adapters. Note: the installed CLI
does NOT accept `--ask-for-approval`, so that flag is not part of the shape; a config-based
approval mechanism may be recorded later only if directly verified.

## Codex Reviewer POC (v1.2.0)

Since v1.2.0 the workflow scripts include a narrow, conservative proof of concept for
invoking Codex as Reviewer during `READY_FOR_REVIEW`. It is the first real bridge from
the verified read-only smoke test (v1.1.0) into a per-turn Codex invocation wired into
the scripts. It is deliberately capture-only.

| Capability | Callable | Eligible state | Invocation | Safety limits | Stop category when unavailable | User authorization required |
|---|---|---|---|---|---|---|
| Codex Reviewer POC (read-only review capture) | POC available, NOT a full callable Reviewer | `READY_FOR_REVIEW` with `Waiting For: Reviewer` | Dry-run: `handoff.ps1 review-check`. Run: `handoff.ps1 review-run` (explicit `yes` confirmation). | Bound Reviewer is Codex; exactly one Task Actors Implementer and one Reviewer; actual Reviewer is Codex and != actual Implementer; Changed Files match git status after excluding local coordination files; Codex run only as `exec --cd <repo> --sandbox read-only --ephemeral --json --output-last-message <file> -` with the review prompt delivered on stdin (never as an argv token, so a multi-word prompt is not split); never `--ask-for-approval`, `--dangerously-bypass-approvals-and-sandbox`, or danger-full-access; no git add/commit/push/tag; no deploy/db/secrets; no `AI_HANDOFF.md` state change. | Environment/Preflight when the Codex CLI cannot be resolved or `exec --help` fails; PowerShell only (Bash refuses honestly). | yes, explicit `yes` confirmation before `review-run` |

Status at v1.2.0: this was a POC, not yet a callable Reviewer adapter. The POC demonstrates
a wired, guarded, read-only Codex invocation that captures a review verdict to local
artifacts; by itself, it did NOT complete the Reviewer's protocol responsibility end-to-end:

- `review-run` itself does not transition `AI_HANDOFF.md` (no automatic `REVIEW_DONE` or
  `READY_FOR_IMPLEMENTATION`); it only captures. Since v1.3.0 the separate `review-apply`
  command reads the captured verdict and applies the state transition fail-closed - see
  "Automated Reviewer Turn" below. `review-run` stays strictly capture-only.
- It satisfies criterion 4 (Reviewer independence) of the v1.1.0 callability criteria by
  refusing unless the bound and actual Reviewer is Codex and the actual Reviewer differs
  from the actual Implementer, but a verdict capture is not the same as a tested,
  end-to-end callable role turn.

Codex CLI resolution for the POC prefers the `CODEX_CLI` environment override (an explicit
path to the codex executable), then probes a local install under
`%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe`, then falls back to `codex` on `PATH`.
Candidates are accepted only if `exec --help` succeeds, so a PATH alias that exists but is
not actually runnable is refused honestly during preflight. No user-specific path is
hardcoded in the scripts, docs, or templates.

`review-run` delivers the review prompt on Codex's stdin (the trailing `-`), not as a
command-line argument, so a multi-word prompt is never split into separate argv tokens.
The prompt is tightly scoped for bounded runtime: Codex is told to be fast, to NOT load
AGENTS.md / CLAUDE.md / the skill or other protocol files, to inspect only AI_HANDOFF.md,
`git status`, and the Changed Files' diffs. Since v2.0.2, if a Changed File is untracked or
new and `git diff -- <file>` is empty or insufficient, the prompt tells Codex to inspect the
file's current content directly as the diff equivalent while still forbidding `git add`,
`git add -N`, index mutation, or working-tree mutation. Since v1.3.0 the prompt asks Codex
to end with a strict four-line verdict block (`VERDICT:` APPROVED/BLOCKED, `REVIEWER: Codex`, `TASK:`
the current task verbatim, `REASON:` one line) so the captured verdict is machine-parseable
by `review-apply`.
`review-run` is bounded by `-TimeoutSeconds` (default 180) and runs Codex as a tracked
child process. If Codex does not finish in time it fails closed: it terminates the Codex
process tree, preserves any partial `CODEX_REVIEW.jsonl` labelled as incomplete, removes
any partial `CODEX_REVIEW_LAST.md` so no incomplete output is read as a verdict, makes no
git or `AI_HANDOFF.md` change, and exits non-zero. This keeps a hung or slow Codex from
blocking the protocol or leaving a stray process. `-Yes` skips the interactive
confirmation for automation/tests; `review-run` stays read-only capture-only regardless.

Captured artifacts are local and gitignored, never committed: `CODEX_REVIEW.jsonl` (the
`--json` event stream) and `CODEX_REVIEW_LAST.md` (the Codex final message via
`--output-last-message`). Both are in the clean-tree exemption list and the `.gitignore`
rules.

## Automated Reviewer Turn (v1.3.0)

Since v1.3.0, `handoff.ps1 review-apply` completes the Reviewer's `READY_FOR_REVIEW` turn by
applying the verdict captured by `review-run`. With the two commands together, the
Reviewer/Codex `READY_FOR_REVIEW` turn is **callable end-to-end** (read approved scope ->
produce a verdict -> apply the correct local handoff transition), fail-closed. This is the
first Codex-held role turn recorded `callable: yes` in the Default Local Registry, and it is
narrowly scoped.

| Capability | Callable | Auto-loop eligible | Eligible state | Invocation | Safety limits | Stop category when blocked | User authorization required |
|---|---|---|---|---|---|---|---|
| Automated Reviewer turn (capture + apply) | yes, explicit-command only | no | `READY_FOR_REVIEW` with `Waiting For: Reviewer` | Capture: `handoff.ps1 review-run` (explicit `yes`). Apply: `handoff.ps1 review-apply` (explicit `yes`, or `-Yes` for automation). | All `review-run` guards re-checked at apply time (bound + actual Reviewer is Codex and != actual Implementer; exactly one Task Actors Implementer + Reviewer; Changed Files == git status); the captured verdict must parse to exactly one strict block (one `VERDICT:` APPROVED/BLOCKED, `REVIEWER: Codex`, `TASK:` matching the current task, non-empty `REASON:`); `review-apply` edits ONLY `AI_HANDOFF.md`; no Codex re-invocation; no git add/commit/push/tag; no deploy/db/secrets; no release action; not auto-run by `loop`/`cycle` by default; since v1.4.0 only `loop -IncludeReviewer` may opt this Reviewer turn into one loop session, and `cycle` never does. | Protocol guard / Environment-Preflight (no usable verdict) - not a user decision; Protocol Repair when a required handoff section is missing. | yes, explicit `yes` (or `-Yes`) before `review-apply`; commit/release stay separate User authorizations |

State transitions applied by `review-apply`:

- `VERDICT: APPROVED` -> `State: REVIEW_DONE`, `Waiting For: User`. The Reviewer attests
  technical readiness; the user still grants commit authorization. `review-apply` performs
  NO release action.
- `VERDICT: BLOCKED` -> `State: READY_FOR_IMPLEMENTATION`, `Waiting For: Implementer`, with
  the captured `REASON` recorded under Last Update so the Implementer sees why.

`review-apply` rewrites only the Status, Last Update, and Next Recommended Step sections of
`AI_HANDOFF.md` (every other section, including Task Actors and Changed Files, is preserved)
and fails closed without writing if any of those required sections is missing.

Why `callable: yes` but `AutoLoopEligible: no`: the adapter model separates "has a verified
end-to-end command path" (`callable`) from "may be auto-run inside `loop`/`cycle`"
(`AutoLoopEligible`). `loop` and `cycle` gate on `AutoLoopEligible`, so by default the
Reviewer/Codex turn makes `loop` STOP and never runs unattended. Since v1.4.0 the operator may
explicitly opt the Reviewer turn into a single `loop` session with `-IncludeReviewer` (see
"Opt-in Reviewer Loop Integration" below); this is a per-session opt-in, not a change to
`AutoLoopEligible`, and `cycle` still never runs a Reviewer turn. Master/Codex remains
explicit-command callable for `NEEDS_ANALYSIS` only (`master-run` + `master-apply`) and is
still not loop/cycle eligible - see "Automated Master Turn" below.

Tested fail-closed conditions (see `protocol-tests.ps1`, section 10): missing capture file;
malformed / missing / multiple / unknown-token `VERDICT`; empty `REASON`; `REVIEWER` not
Codex; stale `TASK` mismatch; wrong State / `Waiting For`; Changed Files != git status;
actual Reviewer == actual Implementer. Each blocks with no transition and no `AI_HANDOFF.md`
change. `loop` stops at a Reviewer turn instead of auto-running it, and `cycle` refuses it.
`review-apply` is PowerShell-only; Bash refuses honestly and points to PowerShell.

## Automated Master Turn (v2.0.1)

Since v2.0.1, `handoff.ps1 master-apply` completes the Master's `NEEDS_ANALYSIS` routing turn
by applying the recommendation captured by `master-run`. With the two commands together, the
Master/Codex `NEEDS_ANALYSIS` turn is **callable end-to-end** (read current handoff -> capture
a routing recommendation -> apply the local handoff transition), fail-closed. This is explicit
command automation by default; since v2.1.0 `loop -IncludeMaster` may opt this same guarded
path into one authorized loop session. `cycle` still never auto-runs Master turns.

| Capability | Callable | Auto-loop eligible | Eligible state | Invocation | Safety limits | Stop category when unavailable | User authorization required |
|---|---|---|---|---|---|---|---|
| Automated Master turn (capture + apply) | yes, explicit-command only | no | `NEEDS_ANALYSIS` with `Waiting For: Master` | Capture: `handoff.ps1 master-run` (explicit `yes`). Apply: `handoff.ps1 master-apply` (explicit `yes`, or `-Yes` for automation/tests). Since v2.1.0, `loop -IncludeMaster` may run this pair in-session. | Bound Master is Codex; `State: NEEDS_ANALYSIS` / `Waiting For: Master`; Codex run only as `exec --cd <repo> --sandbox read-only --ephemeral --json --output-last-message <file> -` with the prompt on stdin; never `--ask-for-approval`, `--dangerously-bypass-approvals-and-sandbox`, or danger-full-access; captured recommendation must parse to one strict block with matching `TASK`; non-`BLOCKED` routing must name the current bound Implementer and Reviewer and keep them different; `master-apply` edits ONLY `AI_HANDOFF.md`; no git add/commit/push/tag; no deploy/db/secrets; not auto-run by default and never by `cycle`. | Environment/Preflight when the Codex CLI cannot be resolved, `exec --help` fails, the run times out, no capture is produced, or no usable recommendation exists; PowerShell only (Bash refuses honestly). | yes, explicit `yes` confirmation before `master-run` and `master-apply`, or explicit loop session authorization with `-IncludeMaster` |

The captured recommendation block is, by default:

```
MASTER_RECOMMENDATION: READY_FOR_IMPLEMENTATION|PLAN_REQUIRED|NEEDS_INVESTIGATION|BLOCKED
WAITING_FOR: Implementer|User
IMPLEMENTER: <tool or TBD>
REVIEWER: <tool or TBD>
TASK: <current Current Task exactly>
REASON: <one non-empty line>
```

`master-apply` parses this block and applies one local transition:

- `READY_FOR_IMPLEMENTATION`, `NEEDS_INVESTIGATION`, or `PLAN_REQUIRED` -> the captured state /
  `Waiting For: Implementer`, with concrete Task Actors from the capture.
- `BLOCKED` -> `State: BLOCKED` / `Waiting For: User`.

`master-run` reuses the v1.2/v1.3 machinery: the runnable Codex CLI resolver (`CODEX_CLI`
override, then a local install, then `PATH`, accepted only if `exec --help` succeeds), stdin
prompt delivery (so a multi-word prompt is never split into argv tokens), the
`-TimeoutSeconds` bound with a process-tree kill on timeout, and fail-closed exits: blocked
guards/bad args (1), Codex CLI unavailable or failed to start (3), timeout (4), non-zero Codex
exit (5), and exit-0 with no captured recommendation (6). Captured artifacts are local and
gitignored, never committed:
`CODEX_MASTER.jsonl` (the `--json` event stream) and `CODEX_MASTER_LAST.md` (the Codex final
message). Both are in the clean-tree exemption list and the `.gitignore` rules.

Tested guards (see `protocol-tests.ps1`, sections 11-12): wrong State / `Waiting For` blocks;
the tool-name form of `Waiting For` is rejected; bound Master must be Codex; Task Actors TBD is
allowed for capture; `master-run` fails closed (no handoff change, no commit) on an unavailable
CLI, timeout (no capture file), and exit-0-with-no-capture; the multi-word prompt is delivered
via stdin (not argv); `master-apply` fails closed on missing/malformed/stale recommendations,
invalid recommendation/Waiting For pairs, missing concrete actors, Reviewer == Implementer, and
captured actors that do not match the current role binding. Master/Codex is `callable: yes` /
`Auto-loop: no` in the `adapters` view. Bash refuses `master-check` / `master-run` honestly and
does not implement `master-apply`.

## Opt-in Master Loop Integration (v2.1.0)

Since v2.1.0, `handoff.ps1 loop -IncludeMaster` may auto-run the Codex Master's
`NEEDS_ANALYSIS` turn inside one explicitly authorized loop session, instead of stopping at
it. This connects the already-proven, fail-closed Master path (`master-run` capture +
`master-apply` transition) into `loop`.

- **Opt-in per session.** Without `-IncludeMaster`, `loop` auto-runs no Master turn: it stops
  cleanly at the Master turn as before the flag existed. The flag authorizes the Master turn
  for that single `loop` invocation only.
- **Master/Codex only.** The in-loop Master turn runs only when the bound next actor is the
  Codex Master at `NEEDS_ANALYSIS`. `AutoLoopEligible` is unchanged (still `no` in the
  `adapters` view); this is a per-session operator opt-in, not a default capability change.
- **Reuses the guarded path.** The loop runs the existing `master-run` (read-only Codex
  capture) then `master-apply` (consume the captured recommendation, edit only
  `AI_HANDOFF.md`), forcing their non-interactive `-Yes` path because the operator already
  authorized the loop session. Every `master-run`/`master-apply` guard is re-checked. Any
  guard violation, or a malformed/stale/missing recommendation, fails closed and stops the
  loop with no unintended transition.
- **Routing.** `READY_FOR_IMPLEMENTATION`, `NEEDS_INVESTIGATION`, or `PLAN_REQUIRED` route to
  `Waiting For: Implementer`; `BLOCKED` routes to `Waiting For: User`. The loop then continues
  only when the next state is otherwise automatable or explicitly opted in.
- **Counts as a turn.** A Master turn counts against `-MaxTurns` like any automated turn.
- **Boundaries preserved.** No git add/commit/push/tag/rebase/amend; no deploy/db/secrets/
  production config; no bypass/danger sandbox flags; local artifacts stay gitignored. `cycle`
  still refuses Master turns. The feature is PowerShell-only; Bash refuses honestly and points
  to PowerShell.

Tested coverage (see `protocol-tests.ps1`, section 13): default `loop` still stops at the
Master turn when `-IncludeMaster` is absent (even with a runnable fake Codex present); opt-in
`loop` captures + applies a `READY_FOR_IMPLEMENTATION` recommendation and then stops on
`MaxTurns` before running Claude when capped; none of these create a git commit.

## Opt-in Reviewer Loop Integration (v1.4.0)

Since v1.4.0, `handoff.ps1 loop -IncludeReviewer` may auto-run the Codex Reviewer's
`READY_FOR_REVIEW` turn inside one explicitly authorized loop session, instead of stopping at
it. This minimizes the number of human handoffs after implementation by connecting the
already-proven, fail-closed Reviewer path (`review-run` capture + `review-apply` transition)
into `loop`. It is the narrowest possible integration:

- **Opt-in per session.** Without `-IncludeReviewer`, `loop` auto-runs no Reviewer turn: it
  stops cleanly at the Reviewer turn (and every other non-Implementer turn) as before the flag
  existed. The flag authorizes the Reviewer turn for that single `loop` invocation only.
- **Reviewer/Codex only.** The in-loop Reviewer turn runs only when the bound and actual next
  actor is the Codex Reviewer at `READY_FOR_REVIEW`. `AutoLoopEligible` is unchanged (still
  `no` in the `adapters` view); this is a per-session operator opt-in, not a capability change.
- **Reuses the guarded path.** The loop runs the existing `review-run` (read-only Codex
  capture) then `review-apply` (consume the captured verdict, edit only `AI_HANDOFF.md`),
  forcing their non-interactive `-Yes` path because the operator already authorized the loop
  session. Every `review-run`/`review-apply` guard is re-checked (bound + actual Reviewer is
  Codex and != actual Implementer; exactly one Task Actors Implementer + Reviewer; Changed
  Files == git status; strict captured-verdict schema with matching `TASK:`). Any guard
  violation, or a malformed/stale/missing verdict, fails closed and stops the loop with no
  handoff transition.
- **Verdict routing.** `APPROVED` -> `REVIEW_DONE` / `Waiting For: User`; the loop then stops
  at that non-loop-eligible User turn (release authorization stays the User's). `BLOCKED` ->
  `READY_FOR_IMPLEMENTATION` / `Waiting For: Implementer`; the loop continues under the
  existing `MaxTurns`/budget rules without involving the user.
- **Counts as a turn.** A Reviewer turn counts against `-MaxTurns` like any automated turn.
- **Clean-tree gate at a Reviewer-turn start.** When a `loop` session begins directly at the
  Codex Reviewer's `READY_FOR_REVIEW` turn, the session-start clean-tree gate does not apply -
  in both modes - because the working tree is expected to carry the changes under review.
  Without `-IncludeReviewer` the loop just stops cleanly at that non-loop-eligible Reviewer turn
  (exit 0), so there is no automated turn for the gate to protect and blocking on the very
  changes under review would be a spurious Environment/Preflight failure. With `-IncludeReviewer`,
  `review-run`/`review-apply` still enforce Changed Files == git status. The clean-tree
  requirement is unchanged for every normal Implementer-first session and for the per-iteration
  Implementer-turn recheck.
- **Boundaries preserved.** No git add/commit/push/tag/rebase/amend; no deploy/db/secrets/
  production config; no bypass/danger sandbox flags; local artifacts stay gitignored. Since
  v2.1.0, Master may be integrated into `loop` only with `-IncludeMaster`; `cycle` still never
  runs Master or Reviewer turns. The feature is PowerShell-only; Bash `loop` refuses honestly
  and points to PowerShell.

Tested coverage (see `protocol-tests.ps1`, section 12): default `loop` still stops at the
Reviewer turn when `-IncludeReviewer` is absent (even with a runnable fake Codex present);
opt-in `loop` captures + applies an `APPROVED` verdict and stops at `REVIEW_DONE` / `Waiting
For: User`; opt-in `loop` applies a `BLOCKED` verdict, returns to `READY_FOR_IMPLEMENTATION` /
`Waiting For: Implementer`, and stops on `MaxTurns` without involving the user; a malformed
captured verdict fails closed (non-zero exit, no handoff transition); none of these create a
git commit; `cycle` still refuses a Reviewer turn; and Reviewer/Codex stays `callable: yes` /
`Auto-loop: no`.

## Safe Agent Process Runner (v2.0.0)

The Claude Code Implementer path is still the only default auto-loop-eligible agent turn, but it now runs through a bounded PowerShell process runner instead of a direct `npx` call. The runner starts a real child process, captures stdout/stderr to temporary files, enforces `-TimeoutSeconds`, and terminates the process tree on timeout before failing closed. The Claude Code safety flags remain unchanged: `--permission-mode acceptEdits`, `--disallowed-tools "Bash"`, `--max-budget-usd`, `--no-session-persistence`, and `--output-format text`.

This does not add Master automation, does not make planning/investigation/question turns callable, and does not add any commit/push/tag/deploy/db/secrets path.

## No-Op / No-Progress Guard (v2.6.0)

The automated Claude Code Implementer path (`cycle`, `run-next`, `loop`) fails closed when a turn exits 0
but does not actually advance the task. Before v2.6.0 such a turn looked like success: `cycle` printed a
benign "next actor" line and exited 0, and `loop` re-ran the identical turn every iteration until
MaxTurns/budget, burning spend on repeated no-ops.

After each exit-0 Claude Implementer turn, the runner compares the pre-turn and post-turn handoff `State`
and the working tree (via `Get-WorkingTreeState`, which already excludes local coordination artifacts):

- **Progressed** - the handoff `State` changed (any legitimate transition: `READY_FOR_REVIEW`,
  `QUESTION_FOR_MASTER`, `RE_GATE_REQUESTED`, `BLOCKED`, `WAITING_FOR_USER`, `IMPLEMENTED`, or a PLAN
  state). Routing continues as before; these are never flagged.
- **No-op** (exit code **7**) - `State` unchanged and no non-exempt source files changed. `cycle` stops
  with a "no-op / no-progress" message; `loop` stops instead of repeating the turn.
- **Incomplete** (exit code **6**, Protocol Repair) - `State` unchanged but non-exempt source files were
  modified (edits made, handoff not moved to `READY_FOR_REVIEW`), or git could not be read. Not treated
  as success.

Exit code 7 is reserved for no-op/no-progress and does not collide with the existing codes (1 blocked,
2 cancelled, 3 runner-start failure, 4 timeout, 5 Claude error, 6 protocol repair / mismatch / incomplete).
The guard reads only local state and mutates nothing; it adds no commit/push/tag/deploy/db/secrets path.
Local coordination artifacts (`AI_HANDOFF.md`, `NEXT_TURN.md`, `HANDOFF_LOOP.log`, and the Claude/Codex
capture files) never count as source progress. Tested in `protocol-tests.ps1`.

## Claude Implementer Prompt Grounding (v2.7.0)

The automated Claude Code Implementer prompt (built in `Invoke-ClaudeTurn`) opens with an explicit
non-interactive directive. In headless `-p` mode the turn otherwise inherits the operator's global/project
Claude context (global `CLAUDE.md`, memory, plugins), whose start-of-session behavior can hijack a thin
prompt: an observed cycle turn received the prompt and ran in the correct repo but responded with an
interactive greeting ("what are you working on? which plugins?") and asked the operator a question instead
of executing the handoff task, so it made no progress (correctly caught by the v2.6.0 no-op guard, exit 7).

To make the turn deterministic regardless of ambient context, the prompt now states up front that this is a
NON-INTERACTIVE, headless turn with no human to talk to: do not greet, do not ask what to work on, do not
ask for plugin choices, do not wait for input, and do not treat it as the start of an interactive session.
It must immediately read `NEXT_TURN.md` and `AI_HANDOFF.md`, follow the current state, and either complete
the required Implementer action or update `AI_HANDOFF.md` with a protocol-valid blocker/question. The
Claude Execution Evidence requirement is preserved.

This is a prompt-only change: the invocation flags, `-p` argv delivery, and the safety model are unchanged.
`--bare` (skipping global/project Claude context entirely) is intentionally NOT used yet - it is a future
hardening option if a live cycle still greets or asks. Tested in `protocol-tests.ps1` by asserting the
non-interactive guard text is present in the prompt source.

## Claude Implementer Context Isolation (v2.8.0)

v2.7.0 prompt grounding proved insufficient on machines that carry an operator global `~/.claude/CLAUDE.md`
and auto-memory: a live cycle turn received the NON-INTERACTIVE directive intact but still greeted the
operator and asked what to work on, because the global start-of-session behavior outranks a user-message
directive.

v2.8.0 isolates the turn at the source: the Claude invocation adds `--setting-sources "project,local"`, so the
headless turn loads only the project and local setting sources and NOT the `user` source (the global
`CLAUDE.md` and auto-memory that caused the greeting), while preserving project-local context and the
existing OAuth authentication. The v2.7.0 grounding prompt is kept as belt-and-suspenders.

`--bare` is intentionally NOT used: on this environment it is higher risk because it forces
`ANTHROPIC_API_KEY` / `apiKeyHelper` auth ("Sets strictly ANTHROPIC_API_KEY or apiKeyHelper"), and this
machine authenticates via OAuth with no API key or apiKeyHelper configured, so `--bare` would likely fail to
authenticate headlessly. `--bare` remains a future option only if API-key / apiKeyHelper headless auth is
set up with explicit user approval.

This is an invocation-only change: `-p` argv delivery and the safety model are unchanged, and the sanitized
command-transparency output records the new flag. Tested in `protocol-tests.ps1` (the runner passes
`--setting-sources "project,local"` and the sanitized/capture strings include it). Live verification (a tiny
probe or a bounded `cycle`) is required to confirm OAuth still works and the greeting is gone, and is run
only with explicit user budget authorization.

## Claude Implementer System-Prompt Grounding (v2.9.0)

v2.8.0's `--setting-sources "project,local"` proved insufficient in the full live `cycle`: the turn still
greeted and cited global `CLAUDE.md` / memory content, so `--setting-sources` does not actually exclude the
user-global `CLAUDE.md` / auto-memory (it only layers settings.json sources). `--bare` would exclude them but
skips keychain reads and forces `ANTHROPIC_API_KEY` / `apiKeyHelper`, which this OAuth machine lacks, so it
stays deferred.

v2.9.0 adds `--append-system-prompt` with a concise directive injected at the SYSTEM-prompt level (a higher
authority than the v2.7.0 user-message directive): non-interactive headless run; never greet; never ask what
to work on; never ask for plugins/input; read the requested local files exactly; follow the `AI_HANDOFF.md`
state and act now, or record a protocol-valid blocker/question. A user-run handoff-shaped probe confirmed
this reads `AI_HANDOFF.md` exactly and returns the correct status with no greeting. The v2.8.0
`--setting-sources "project,local"` and the v2.7.0 user prompt are kept as layered belt-and-suspenders.

Command transparency shows `--append-system-prompt "<system-prompt:redacted>"` (the system prompt is
redacted, never dumped). This is an invocation-only change: `-p` argv delivery and the safety model are
unchanged; no secret / API key is configured. `--bare` remains deferred until a user-approved headless
API-key / apiKeyHelper auth path exists (or a user-approved global `CLAUDE.md` headless exception). Tested in
`protocol-tests.ps1` (the runner passes `--append-system-prompt`; the system prompt carries the guard
phrases; transparency redacts it).

## Claude Implementer Windows argv Quoting (v2.10.0)

The first full live v2.9.0 `cycle` still failed closed, but for a different reason than the original global
memory greeting. Claude Code reported that the message was cut off and that it received only `are`. The
runner capture showed the intended prompt was present before launch, so the failure was in Windows process
argument delivery.

Root cause: Windows PowerShell 5.1 does not expose `ProcessStartInfo.ArgumentList`, and `Start-Process
-ArgumentList` can collapse an array into one command-line string without preserving multi-word prompt
arguments for `npx.cmd`. As a result, `--append-system-prompt` / `-p` values were split into stray words.

v2.10.0 keeps the same safety model and Claude Code flags, but the bounded runner now:

- flattens the user prompt to a single command-line-safe line before passing it to `-p`;
- converts every `npx` argument through explicit Windows command-line quoting;
- passes the quoted command line to `Start-Process`, while still recording the child PID for timeout cleanup.

`protocol-tests.ps1` includes a fake `npx.cmd` argv check proving that `--append-system-prompt`, the
multi-word system prompt, `-p`, and the multi-word user prompt arrive as the expected single argv values.

## Timeout Partial Progress Repair Guidance (v2.11.0)

Live pilots showed that Claude Code can complete an approved source edit and then time out before updating
`AI_HANDOFF.md`. This is not safe to treat as success, but it is also more informative than a plain timeout.

v2.11.0 keeps timeout as exit code 4, but after a timeout `cycle` and `loop` inspect the working tree. If
non-exempt source files changed while the handoff state did not transition, the command prints explicit
partial-progress repair guidance:

- source files changed;
- `AI_HANDOFF.md` did not complete a valid transition;
- do not commit yet;
- open Codex as Reviewer/repair to inspect the diff and either approve, block, or repair the local handoff
  state.

This preserves fail-closed behavior while making the next operator action obvious.

## Exact-Scope Interrupted Correction Recovery (v3.1.5)

v3.1.5 closes the recovery gaps found by the real v3.1.4 user-flow acceptance test.

- A new `loop` or `cycle` may resume a Reviewer-`BLOCKED` correction only when the current
  non-local Git status matches `AI_HANDOFF.md` `Changed Files` exactly. Any unrelated file
  still blocks before Claude runs.
- The Claude prompt forbids temporary helper/capture/runner/wrapper scripts, restricts edits
  to task-required files, and requires unavailable verification to be recorded as not run.
- The Windows runner invokes `npx.cmd` with a PowerShell argument array (`& ... @argList`)
  inside the bounded runner process. This supersedes the v2.10.0 `Start-Process` command-line
  quoting layer, preserves the real child exit code, and keeps timeout cleanup by terminating
  the outer runner's complete descendant tree.
- If Claude exits non-zero after already writing a protocol-valid `READY_FOR_REVIEW` handoff,
  automation continues only when `Changed Files` still equals Git status exactly.
- If an interrupted Reviewer correction changed the exact approved file set but did not update
  the handoff, a before/after content fingerprint permits a local transition to
  `READY_FOR_REVIEW`. The transition explicitly carries no verification attestation; Codex
  remains the independent Reviewer and must run the checks.
- No content change, a malformed handoff, or any extra file remains fail-closed. Recovery never
  runs `git add`, commit, push, tag, deploy, database, or secret operations.
