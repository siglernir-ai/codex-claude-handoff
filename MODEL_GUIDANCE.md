# Model Guidance

Use this guide to choose a practical model level for `codex-claude-handoff` work.
The goal is high-quality results without wasting expensive model capacity on
routine steps.

## Default Recommendation

Use the `standard` capability profile for most work:

- Reading repository files.
- Updating documentation.
- Small implementation tasks.
- Running protocol checks.
- Preparing handoff state.
- Creating internal pilot reports.

Use `economy` for short, bounded, low-risk implementation and `cheap_readonly`
for investigation or summarization. The profile is stable even when provider
model names change.

## Use a Stronger Model For

Select `high_reasoning` for short, high-value review passes:

- Final publication readiness review.
- Security and trust-model review.
- Release go/no-go decisions.
- Complex architecture changes.
- Large refactors with cross-file behavior.
- Ambiguous failures where cheaper passes disagree.

Do not keep a high-cost mapping active for routine inspection or mechanical
documentation edits. A concrete `high_reasoning` Claude mapping requires
`-AllowModelEscalation`.

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

The Master writes a policy profile in `AI_HANDOFF.md`; the adapter resolves it
through `.ai/skills/codex-claude-handoff/MODEL_ROUTING.json` or a
`HANDOFF_CLAUDE_MODEL_<PROFILE>` environment variable. Prefer profiles over
hard-coded model names:

- `economy` for simple, bounded implementation.
- `cheap_readonly` for investigation.
- `standard` for normal tasks.
- `high_reasoning` for publication, security, release, and architecture review.
- `inherit` when no local mapping is configured.

Run `.\scripts\handoff.ps1 models` to see the effective profile, concrete model,
and resolution source. Updating a provider model requires changing one local
mapping value, not editing the protocol.

## The Master's Own Cost

The profiles above control what the Claude Implementer costs. What the Master costs
depends on two other things, and `MODEL_ROUTING.json` sets neither:

1. **The Master's model.** Route, delegate, and review ordinary turns with the host's
   standard model at low or medium effort. Switch to the strongest model only for a
   high-value review pass. In one measured Codex session the strongest model used up
   a five-hour usage window about five times faster than the standard model on the
   same volume of input.
2. **The size of the Master's context.** Every tool call resends the conversation, so
   ten small reads of a large context cost more than one focused read. Follow the
   `Context Budget` section of `MASTER.md`: take state from `NEXT_TURN.md` and the
   `AI_HANDOFF.md` sections it maps, look protocol rules up by heading, delegate
   repository investigation to the Implementer, and start a fresh window for each
   protocol turn.

## Operator Rule

If token or credit budget is low, stop new feature work and spend the remaining
budget on:

1. Status check.
2. Dirty tree check.
3. Exact next user action.
4. A short continuation note for the next session.
