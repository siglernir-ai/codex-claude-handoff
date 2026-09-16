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

The Master writes a policy profile in `AI_HANDOFF.md`; each tool resolves it
through `.ai/skills/codex-claude-handoff/MODEL_ROUTING.json` (`claudeModel` and, since
v3.10.0, `codexModel`) or a `HANDOFF_CLAUDE_MODEL_<PROFILE>` /
`HANDOFF_CODEX_MODEL_<PROFILE>` environment variable. Prefer profiles over hard-coded
model names:

- `economy` for simple, bounded implementation.
- `cheap_readonly` for investigation.
- `standard` for normal tasks.
- `high_reasoning` for publication, security, release, and architecture review.
- `inherit` when no local mapping is configured.

Run `.\scripts\handoff.ps1 models` to see the effective profile, concrete model,
and resolution source. Updating a provider model requires changing one local
mapping value, not editing the protocol.

## The Master's Own Cost

What the Master costs depends on two things:

1. **The Master's model.** Route, delegate, and review ordinary turns with the host's
   standard model at low or medium effort. Switch to the strongest model only for a
   high-value review pass. In one measured Codex session the strongest model used up
   a five-hour usage window about five times faster than the standard model on the
   same volume of input. Since v3.10.0 the profile sets this too: `master-run` and
   `review-run` pass the resolved `codexModel` to Codex, and `NEXT_TURN.md` names it
   under `Model For This Turn` for a turn you drive in a window. A concrete
   `high_reasoning` Codex model requires `-AllowModelEscalation`, like Claude.

   To route Codex without editing a shipped file, set for example
   `HANDOFF_CODEX_MODEL_STANDARD` to your standard model and
   `HANDOFF_CODEX_MODEL_HIGH_REASONING` to your strongest one. A Codex app that was
   already open reads new environment variables only after it restarts.

   **A new model means a new window.** Switching models inside a conversation resends
   the whole conversation to the new model without its cache. A new window starts from
   `NEXT_TURN.md` and `AI_HANDOFF.md` and loses nothing.
2. **Fast mode (since v3.11.1, `doctor` warns about it).** Fast mode, which the Codex app
   stores as `service_tier = "priority"` in `config.toml`, answers about 1.5x sooner and
   consumes usage at 2.5x the Standard rate on GPT-5.6 and GPT-5.5. It is the same model
   with the same reasoning, so the result is the same; only the wait is shorter. On a plan
   where the five-hour usage window runs out before the day does, Standard gets about 2.5x
   more work done per window. In one measured session a Master window on Fast went from 0%
   to 99% of the window in 17 minutes. Remove the `service_tier` line and switch Fast off in
   the Codex window, which keeps its own per-conversation setting.
3. **The size of the Master's context.** Every tool call resends the conversation, so
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
