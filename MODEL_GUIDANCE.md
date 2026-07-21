# Model Guidance

Use this guide to choose a practical model level for `codex-claude-handoff` work.
The goal is high-quality results without wasting expensive model capacity on
routine steps.

## Default Recommendation

Use a capable standard coding model for most work:

- Reading repository files.
- Updating documentation.
- Small implementation tasks.
- Running protocol checks.
- Preparing handoff state.
- Creating internal pilot reports.

In the user's current operating pattern, this is the right place for the normal
Codex model used for day-to-day work.

## Use a Stronger Model For

Switch to the strongest available model for short, high-value review passes:

- Final publication readiness review.
- Security and trust-model review.
- Release go/no-go decisions.
- Complex architecture changes.
- Large refactors with cross-file behavior.
- Ambiguous failures where cheaper passes disagree.

Do not keep the strongest model running for routine file inspection or mechanical
documentation edits unless the work is highly sensitive.

## Suggested Split

Use the standard model for:

```text
Create the draft, update docs, run tests, summarize evidence.
```

Use the strongest model for:

```text
Review this release as if you are blocking publication. Find safety, UX,
packaging, install, and overclaiming risks. Recommend go/no-go.
```

## Claude Code Model Evidence

Claude Code may expose model information in execution evidence, but it is not
always available through the CLI. Treat model evidence as useful telemetry, not as
a mandatory proof of correctness.

Prefer policy-based wording over hard-coded model names:

- `inherit` for normal tasks.
- `economical` for simple or repetitive work.
- `strongest available` for publication, security, release, and architecture
  review.

This keeps the workflow useful when model names change.

## Operator Rule

If token or credit budget is low, stop new feature work and spend the remaining
budget on:

1. Status check.
2. Dirty tree check.
3. Exact next user action.
4. A short continuation note for the next session.
