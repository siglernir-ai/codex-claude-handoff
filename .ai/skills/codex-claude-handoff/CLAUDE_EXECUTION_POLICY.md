# Claude Execution Policy

Since v2.3.0; expanded in v2.4.0. This file defines how the protocol records Claude Code execution context
without hard-coding provider model names into the method.

## Purpose

Codex must know how Claude Code is expected to run before it delegates implementation,
and Claude must leave enough evidence for Codex and future Claude window sessions to
reconstruct what happened.

This policy is intentionally dynamic. It describes execution profiles and evidence fields,
not a permanent list of model names.

## Model Policy Profiles

Use these profile labels in handoff notes and capture artifacts:

| Profile | Meaning |
|---|---|
| `auto` | Let the protocol derive `cheap_readonly` for investigation and `standard` for ordinary implementation. This is the backward-compatible default. |
| `inherit` | Use Claude Code's configured/default model. |
| `economy` | Short, bounded, low-risk implementation or repetitive work. |
| `standard` | Ordinary implementation. |
| `high_reasoning` | Complex, risky, architectural, security, migration, or multi-file work. Requires explicit user approval before raising cost. |
| `cheap_readonly` | Read-only investigation, summarization, or narrow mechanical checks when a cheaper profile is configured. |
| `explicit_user_choice` | The user explicitly named a model/profile for this turn. Record the user's requested value. |

The Master writes `Model Profile` in the `AI_HANDOFF.md` Status section. It selects a
capability and cost class, never a transient provider model name. `auto` resolves to
`cheap_readonly` for `NEEDS_INVESTIGATION` and `standard` for other automated
Implementer turns.

The adapter resolves the selected profile in this order:

1. Explicit `-Model` command-line choice.
2. `HANDOFF_CLAUDE_MODEL_<PROFILE>` process environment variable.
3. Project-local `.ai/skills/codex-claude-handoff/MODEL_ROUTING.json`.
4. Safe fallback to `inherit`.

`MODEL_ROUTING.json` intentionally ships with every profile mapped to `inherit`.
Projects may replace a profile value with any model identifier supported by their
current Claude Code installation. New provider models require only a local mapping
change, not a protocol release. Run `handoff.ps1 models` to inspect the effective
selection before spending budget.

When `high_reasoning` resolves to a concrete model, `cycle` and `loop` fail closed
unless the operator supplies `-AllowModelEscalation`. An explicit `-Model` value is
recorded as `explicit_user_choice`. Never infer that a requested model was actually
used unless the runtime exposes direct evidence.

## Required Claude Execution Evidence

After each Implementer turn, Claude should report these fields in its response and/or `AI_HANDOFF.md`:

- Model policy requested: `auto` / `inherit` / `economy` / `standard` / `high_reasoning` / `cheap_readonly` / `explicit_user_choice`
- Model requested via CLI: `none` or the value passed to the CLI
- Actual model observed: `unknown` unless directly exposed by Claude Code output
- Model relevance: `relevant` / `not relevant` / `unknown`
- Reason: why the model was or was not relevant for this task
- Subagent evidence: `used` / `not observed` / `unavailable`
- Subagent details: only if directly observed; do not invent
- Skills/capabilities consulted: relevant project/global Claude skills or `none needed`
- Why / decisions / risks: concise rationale for the implementation path

If evidence is not directly available, write `unknown/not exposed` or `not observed`. Strip ANSI/control noise from observed model strings before recording them. Never infer a concrete model,
subagent, or tool invocation from silence.

## Continuity Artifacts

Automated CLI Implementer turns write local, gitignored capture artifacts:

- `CLAUDE_IMPLEMENTER_LAST.md` - latest Claude Implementer turn snapshot
- `CLAUDE_IMPLEMENTER.jsonl` - append-only history of Claude Implementer turns

These artifacts are supplementary memory, not authority. `AI_HANDOFF.md` remains the source of truth for
current state. Capture artifacts must never be committed.

## Entry Reconstruction

Before acting, Claude Code should read, when present:

- `AI_HANDOFF.md`
- `NEXT_TURN.md`
- `CLAUDE_IMPLEMENTER_LAST.md`
- `CODEX_MASTER_LAST.md`
- `CODEX_REVIEW_LAST.md`
- recent `HANDOFF_LOOP.log`
- this `CLAUDE_EXECUTION_POLICY.md`
- `CAPABILITIES.md`

Codex should read `CAPABILITIES.md` and this file before delegating meaningful new implementation work to Claude.
For trivial tasks this may be quick; for new projects or risky tasks it is required.

## Subagents

The protocol does not require subagent use by default. Claude may use subagents when its environment supports
them and the task warrants delegation. The required behavior is evidence discipline:

- If subagents are used, record what was directly observed.
- If no evidence is available, record `Subagent evidence: not observed`.
- If the environment does not support subagents, record `Subagent evidence: unavailable`.
- Do not claim optimal subagent use unless there is direct evidence.

Future versions may define a project-local `.claude/agents/` set. Until then, this file requires auditability,
not forced delegation.
## Command Transparency

Since v2.4.0, automated CLI Implementer turns record sanitized invocation evidence.
This is not a raw terminal transcript. It is a safe, local record of how the handoff
adapter invoked Claude Code.

Required command evidence surfaces:

- `CLAUDE_IMPLEMENTER_COMMAND.md` for the latest human-readable sanitized invocation
- `CLAUDE_IMPLEMENTER.jsonl.commands[]` for structured append-only command evidence

Minimum `commands[]` fields:

- `cmd`: sanitized command string; redact prompt, secrets, tokens, credentials, and sensitive arguments
- `exitCode`: process exit code when available
- `purpose`: why the command was run
- `sanitized`: boolean, must be true for stored command evidence
- `redactions`: list of redacted field categories

Do not log raw secrets, tokens, credential-bearing commands, or full prompt-bearing invocations.
When in doubt, redact and preserve only the command name, purpose, and safe flags.
