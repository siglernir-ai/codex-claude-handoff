# Product Decisions

Durable record of decisions the user has confirmed. This file **accumulates**; nothing
here is reset when a new task opens, and it is **never reset by `start`**.

## Why this file exists, separately from AI_HANDOFF.md

`AI_HANDOFF.md` holds the state of **one live task**, and `handoff.ps1 start` archives
and replaces it for the next task. That is correct for execution state and wrong for
product knowledge: the decisions that shape a product are made in advisory conversation,
and the Master is told - correctly - not to write advisory answers into the task state.

The result, before this file existed, was that the cheapest knowledge survived and the
most expensive evaporated. A protocol can record precisely which file changed on which
turn, and still lose who the product is for, which platform it targets, and what happens
to a user's data - because those were decided in a conversation and never written down.

## What belongs here

- A decision the user **confirmed**, in their own terms.
- The reason, when the reason is what makes the decision reusable.
- The date, so a later decision can supersede an earlier one.

## What does not belong here

- A suggestion, a recommendation, or an option that was raised and not chosen.
- Task state, changed files, verification, or review outcome - those are `AI_HANDOFF.md`.
- Anything the user did not confirm. An agent's own conclusion is not a decision.

## Recording rule

Append; do not rewrite. When a decision replaces an earlier one, add the new entry and
mark the old one superseded with the date - a decision that was reversed is itself worth
knowing. Never delete an entry to make the record tidier.

---

## Decisions

<!-- Newest first.

## YYYY-MM-DD - <the decision in one line>

**Decision:** what was decided, in the user's terms.
**Why:** the reason, when it makes the decision reusable.
**Scope:** what it applies to, and what it explicitly does not.

-->

_No decisions recorded yet._
