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
| Master | Codex | no | none | Run `handoff.ps1 next` or `handoff.sh next`, then paste the generated prompt into Codex. | Manual turn only; no source edits unless the user explicitly asks; no commit/push/tag/deploy/db/secrets automation. | Non-callable Actor | no for paste; yes for protected actions |
| Implementer | Claude Code | yes | `READY_FOR_IMPLEMENTATION` only | `npx --yes @anthropic-ai/claude-code -p "<prompt>" --permission-mode acceptEdits --disallowed-tools "Bash" --max-budget-usd N --no-session-persistence --output-format text` via `handoff.ps1 cycle` or `handoff.ps1 loop`. | Explicit `yes` confirmation; Reviewer != Implementer; clean tree except local handoff files; Bash disallowed; budget cap; no commit/push/tag/deploy/db/secrets automation. | Non-callable Actor for unsupported Implementer states; Environment/Preflight when `npx` or Claude Code is unavailable | yes, explicit confirmation before each `cycle` or loop session |
| Reviewer | Codex | no | none | Run `handoff.ps1 next` or `handoff.sh next`, then paste the generated prompt into Codex. A read-only review-output capture POC exists (`handoff.ps1 review-check` / `review-run`, since v1.2.0) but does NOT make Reviewer callable - see "Codex Reviewer POC" below. | Manual review only; independent-review invariant still applies; no release action without user authorization. | Non-callable Actor | no for paste; yes for release actions |

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
- Master and Reviewer turns remain manual until a real local adapter for the
  bound tool exists and is verified.
- Codex is not callable in this protocol. A discovered Codex CLI binary - even with a
  passing read-only `codex exec` smoke test - is not sufficient on its own: no protocol
  wrapper/adapter has been implemented and tested, and no MCP adapter or API bridge is
  wired into the workflow scripts. See "Codex CLI Verification" below. Since v1.2.0 a
  read-only Codex Reviewer POC (`review-check` / `review-run`) wires a guarded per-turn
  Codex invocation into the scripts, but it is capture-only and does NOT make any Codex
  role callable. See "Codex Reviewer POC" below.
- Since v0.19.1, `release-check` and `release` are PowerShell-only. Bash reports the
  limitation honestly and does not run release git mutations.

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
the current resolved role registry plus the release-executor capability for the
local project.

Release execution is not a role turn and does not approve work. It is a guarded
operator action after the Reviewer has attested technical readiness and the user
has supplied the exact release authorization token.

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

Codex nonetheless remains `callable: no` for all roles and all states, exactly as in
the Default Local Registry, because a successful manual smoke test is necessary but not
sufficient: no protocol wrapper/adapter has been implemented and tested. Nothing wires a
per-turn Codex invocation into the workflow scripts with enforced read-only sandboxing,
output capture, and Reviewer independence (criterion 4). The verified candidate
invocation shape above is recorded for that future adapter turn. Note: the installed CLI
does NOT accept `--ask-for-approval`, so that flag is not part of the shape; a
config-based approval mechanism may be recorded later only if directly verified. Until a
tested adapter records passing evidence for all four criteria, no Codex adapter may be
marked callable.

## Codex Reviewer POC (v1.2.0)

Since v1.2.0 the workflow scripts include a narrow, conservative proof of concept for
invoking Codex as Reviewer during `READY_FOR_REVIEW`. It is the first real bridge from
the verified read-only smoke test (v1.1.0) into a per-turn Codex invocation wired into
the scripts. It is deliberately capture-only.

| Capability | Callable | Eligible state | Invocation | Safety limits | Stop category when unavailable | User authorization required |
|---|---|---|---|---|---|---|
| Codex Reviewer POC (read-only review capture) | POC available, NOT a full callable Reviewer | `READY_FOR_REVIEW` with `Waiting For: Reviewer` | Dry-run: `handoff.ps1 review-check`. Run: `handoff.ps1 review-run` (explicit `yes` confirmation). | Bound Reviewer is Codex; exactly one Task Actors Implementer and one Reviewer; actual Reviewer is Codex and != actual Implementer; Changed Files match git status after excluding local coordination files; Codex run only as `exec --cd <repo> --sandbox read-only --ephemeral --json --output-last-message <file> -` with the review prompt delivered on stdin (never as an argv token, so a multi-word prompt is not split); never `--ask-for-approval`, `--dangerously-bypass-approvals-and-sandbox`, or danger-full-access; no git add/commit/push/tag; no deploy/db/secrets; no `AI_HANDOFF.md` state change. | Environment/Preflight when the Codex CLI cannot be resolved or `exec --help` fails; PowerShell only (Bash refuses honestly). | yes, explicit `yes` confirmation before `review-run` |

Status: this is a POC, not a callable Reviewer adapter. The Default Local Registry above
still records Reviewer/Codex as `callable: no`, and that is intentional and unchanged. The
POC demonstrates a wired, guarded, read-only Codex invocation that captures a review
verdict to local artifacts; it does NOT complete the Reviewer's protocol responsibility
end-to-end:

- It does not transition `AI_HANDOFF.md` (no automatic `REVIEW_DONE` or
  `READY_FOR_IMPLEMENTATION`). A human or the Master reads the captured verdict and
  applies the state transition manually. Automating that transition from a structured
  Codex verdict is deferred to v1.3.0.
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
`git status`, and the Changed Files' diffs, and to end with one line `VERDICT: APPROVED`
or `VERDICT: BLOCKED` plus a one-line reason.
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
