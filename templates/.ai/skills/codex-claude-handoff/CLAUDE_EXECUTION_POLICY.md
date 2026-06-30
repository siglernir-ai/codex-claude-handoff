# Claude Execution Policy

Since v2.3.0. This file defines how the protocol records Claude Code execution context
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
| `inherit` | Use Claude Code's configured/default model. This is the default. |
| `standard` | Ordinary implementation. The runner may still use `inherit` unless the user configures a concrete model. |
| `high_reasoning` | Complex, risky, architectural, security, migration, or multi-file work. Requires explicit user approval before raising cost. |
| `cheap_readonly` | Read-only investigation, summarization, or narrow mechanical checks when a cheaper profile is configured. |
| `explicit_user_choice` | The user explicitly named a model/profile for this turn. Record the user's requested value. |

The protocol should prefer `inherit` unless the user or a local project policy overrides it.
Do not hard-code transient model names into the protocol method. If a concrete CLI model flag is used,
record it as evidence for that turn.

## Required Claude Execution Evidence

After each Implementer turn, Claude should report these fields in its response and/or `AI_HANDOFF.md`:

- Model policy requested: `inherit` / `standard` / `high_reasoning` / `cheap_readonly` / `explicit_user_choice`
- Model requested via CLI: `none` or the value passed to the CLI
- Actual model observed: `unknown` unless directly exposed by Claude Code output
- Model relevance: `relevant` / `not relevant` / `unknown`
- Reason: why the model was or was not relevant for this task
- Subagent evidence: `used` / `not observed` / `unavailable`
- Subagent details: only if directly observed; do not invent
- Skills/capabilities consulted: relevant project/global Claude skills or `none needed`
- Why / decisions / risks: concise rationale for the implementation path

If evidence is not directly available, write `unknown` or `not observed`. Never infer a concrete model,
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