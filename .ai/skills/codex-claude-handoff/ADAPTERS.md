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
| Reviewer | Codex | no | none | Run `handoff.ps1 next` or `handoff.sh next`, then paste the generated prompt into Codex. | Manual review only; independent-review invariant still applies; no release action without user authorization. | Non-callable Actor | no for paste; yes for release actions |

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
  manual in v0.19.0. The current Claude Code CLI invocation cannot be safely
  restricted to handoff-only edits in non-interactive mode.
- Master and Reviewer turns remain manual until a real local adapter for the
  bound tool exists and is verified.
- Codex is not callable in this repository in v0.19.0. No Codex CLI, MCP adapter,
  API bridge, or external adapter is present in the local protocol files.
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
