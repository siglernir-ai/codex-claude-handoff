# Live Demo Evidence

This evidence supports the product's central claim: two coding agents can work on
one accountable task with explicit ownership, independent review, fail-closed
scope checks, and a user approval gate. It does not claim unrestricted autonomous
dialogue or unattended production release.

## Scope

The public-beta demo was run on 2026-07-23 in a disposable Git repository created
specifically for the recording. The repository began with a clean baseline commit.
`codex-claude-handoff` was installed directly from the public GitHub repository for
Codex and Claude Code, and the bundled setup reported protocol version `3.3.0` and
`Doctor result: PASS`.

The live task requested exactly one new file, `HANDOFF_DEMO_RESULT.md`, and required
the workflow to stop at `REVIEW_DONE` before commit.

## Observed Workflow

1. Codex Master routed the task to `READY_FOR_IMPLEMENTATION`.
2. Claude Code created the requested file and transitioned to
   `READY_FOR_REVIEW`.
3. The Reviewer preflight failed closed because Claude annotated the Changed Files
   entry as `HANDOFF_DEMO_RESULT.md (new; the sole task deliverable)` instead of
   recording the exact Git path.
4. The local coordination entry was corrected to the exact path. The task file was
   not changed during this repair.
5. Codex Reviewer inspected the file read-only and returned `VERDICT: APPROVED`.
6. `review-apply` transitioned the local state to
   `REVIEW_DONE / Waiting For: User`.
7. Final Git status contained exactly one untracked task file. No task commit,
   push, tag, release, deploy, database, or secret action was run.

The edited demo video removes waiting time but does not hide the failed-closed
Reviewer preflight or the one-line coordination repair.

## Final Deliverable

```markdown
# Task

This is the v3.3.0 supervised handoff demo.

# Implementer

Claude Code created this file through the handoff.

# Safety

No commit, push, tag, release, deploy, database, or secret action was run.
```

## Raw Transcript Integrity

The raw local transcripts are intentionally not committed because they contain
machine-local paths and verbose agent captures. Their SHA-256 hashes are:

| Transcript | Bytes | SHA-256 |
|---|---:|---|
| `01-start.txt` | 1,940 | `EE7B6A79AAFFE5BC1CCB080738F59E635914ACC0801E4E9775134392400A1BA4` |
| `02-live-loop.txt` | 21,798 | `57CBBCCB2EEC2271C486A1A71B55FD22C8CD160865B8DB88E01A65BDE855647E` |
| `03-review-resume.txt` | 7,150 | `8CF0AAD56AD11BBADD39BD51DB3EF54F26F19BFDCC0F14D8EDE4D154DAF4E112` |
| `04-review-apply-and-final.txt` | 7,718 | `DD449F90464C968C7507FAA18A89E7B17B4DDA39B4CBC338AA75FFC1E78F04C9` |

## Budget and Command Boundary

The Claude Implementer turn used a declared maximum budget of USD 2 and a
240-second timeout. The captured invocation was sanitized and included safe mode,
prompt redaction, Bash disallowance, no session persistence, and project/local
settings isolation. The capture reported exit code 0 and no timeout.
