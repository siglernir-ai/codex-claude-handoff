# Codex-Claude Handoff - Roadmap

This document describes the intended direction of the protocol from its current state
through a stable v1.0.0 release.

The long-term goal is a safe, role-based multi-agent workflow where the Master, Implementer,
and Reviewer can run bounded autonomous dialogue with minimal manual prompt-copying, while
preserving the user as the approval point for commits, pushes, deploys, database operations,
secrets, and product decisions.

## What Is Already Complete (through v0.13.0)

- Role model established: Master, Implementer, and Reviewer roles bound to concrete tools
  in `.ai/roles/ROLE_ASSIGNMENT.md`. Default: Master = Codex, Reviewer = Codex,
  Implementer = Claude Code.
- Role invariant enforced: Reviewer must never be the same tool as the Implementer.
- Role-aware workflow scripts: `handoff.ps1` and `next-step.ps1` resolve the expected actor
  via State -> Role -> Tool using the binding file.
- Protocol gates: Investigation Gate, Planning Gate, Verification Gate, unsafe command rules.
- Two-way dialogue states: `QUESTION_FOR_MASTER`, `QUESTION_FOR_IMPLEMENTER`,
  `RE_GATE_REQUESTED`.
- Decision Router: six-path advisory-first routing for natural user requests.
- `run-next` single-turn MVP: automates one Claude Code implementation turn (budget-capped,
  Bash blocked, no git operations).
- Mismatch guards: mismatched `Waiting For` values surface as a User action instead of
  silently routing to the wrong tool.
- Shared canonical skill folder with discovery adapters for both tools.
- PowerShell install script.

## Proposed Milestones

### v0.14.0 - Roadmap and Release Discipline

**Goal:** Make the roadmap and release process explicit and repeatable before further
automation work begins.

**Includes:**
- This ROADMAP.md file.
- A release discipline checklist in README.md.
- CHANGELOG.md entry for 0.14.0.
- Version bump to 0.14.0.

**Does not include:**
- Any protocol behavior changes.
- Autonomous dialogue or loop automation.
- Cross-platform installation implementation.
- Orchestration CLI.

**Exit criteria:**
- A reader can trace the path from v0.13.0 to autonomous dialogue without asking for
  missing strategy.
- Every future release can follow the README release checklist without ad-hoc decisions.
- Changelog and version files say 0.14.0.

---

### v0.15.0 - Cross-Platform Installation and CLI Hardening

**Goal:** Make install and workflow scripts work reliably on macOS and Linux in addition
to Windows PowerShell, and harden the scripts enough for unattended or scripted use.

**Includes:**
- Shell/Bash equivalents of `handoff.ps1` and `next-step.ps1`, or a cross-platform runner.
- Path and line-ending normalization for non-Windows environments.
- A `--check` or `--dry-run` mode for the installer.
- Input validation: missing files, bad state values, and missing dependencies produce
  clear error messages instead of unexpected behavior.
- Updated README with cross-platform install instructions.

**Does not include:**
- Autonomous dialogue loop.
- Orchestration CLI.
- Automatic model switching.

**Exit criteria:**
- Install and all workflow commands run without error on Windows, macOS, and Linux.
- Scripts handle missing or malformed `AI_HANDOFF.md` without crashing.
- README install instructions cover all three platforms.

---

### v0.16.0 - Bounded Single-Command Orchestrator

**Goal:** Add a single command that runs one full handoff cycle (Implementer turn followed
by a Reviewer prompt) within explicit safety boundaries, without requiring the user to
copy prompts between tools.

**Includes:**
- A new `handoff.ps1 cycle` command that runs one Implementer turn, then generates and
  displays the Reviewer prompt. `cycle` and `run-next` share one implementation;
  `run-next` remains as a backward-compatible alias.
- Hard turn limit: at most 1 Implementer turn per cycle invocation. The Reviewer turn is
  prepared (prompt + `NEXT_TURN.md`), not executed - the Reviewer turn remains manual.
- State validation before each step: if state or actor does not match, the cycle aborts
  with a clear message before any turn executes.
- A distinct exit code for post-turn handoff inconsistency, so future orchestration can
  rely on exit codes instead of parsing output.
- No automatic git operations; the user still runs `commit-check` and commits manually.

**Does not include:**
- Multi-turn autonomous loop.
- Automatic Reviewer or Master execution.
- Automatic model switching or token budgeting.
- Shared memory layer.
- Event-driven or file-watcher orchestration.

**Exit criteria:**
- `handoff.ps1 cycle` takes a state from `READY_FOR_IMPLEMENTATION` to `READY_FOR_REVIEW`
  with one command and prepares the Reviewer prompt without user prompt-copying. The
  Reviewer turn itself, and the path to `REVIEW_DONE`, remain manual.
- A state mismatch aborts cleanly before any turn runs.
- A post-turn handoff inconsistency stops the cycle with a distinct exit code and routes
  resolution to the user.
- No automatic git operations occur.
- The manual single-turn workflow continues to work independently of `cycle`.

---

### v0.17.0 - Autonomous Loop Skeleton (Callable-Agent Loop)

**Goal:** Add a bounded loop manager that runs callable turns automatically within a turn
budget and safety perimeter, stopping cleanly whenever the next actor is not callable or
the user's approval is required.

**Honest scope:** v0.17.0 is the loop skeleton, not full autonomous Codex <-> Claude Code
dialogue. The only callable automated turn is an approved Implementer turn
(`READY_FOR_IMPLEMENTATION`) bound to Claude Code, because only Claude Code has a local
CLI. Master and Reviewer turns (Codex by default) have no callable adapter yet - when one
of them is the next actor, the loop prepares `NEXT_TURN.md`, prints the paste instruction,
and stops. Full autonomous dialogue requires a Codex callable adapter, which is future
work beyond v0.17.0.

**Includes:**
- A `handoff.ps1 loop` command that runs callable turns automatically until a hard stop
  condition is reached.
- Configurable maximum turns per session (default: 3).
- Per-turn and per-session spending budget caps (worst-case authorized spend).
- Per-turn state log written to a local file (not committed).
- All hard stop conditions in the safety model enforced (see below).

**Does not include:**
- Automatic commit, push, deploy, database operations, secrets, or production config changes.
- Bypass of the user approval point for any action listed in the safety model.
- Automatic model switching.
- Persistent shared memory between sessions.

**Exit criteria:**
- The loop stops automatically at every hard stop condition listed in the safety model.
- Turn log is written locally and never committed.
- Budget cap is respected per turn and per session.
- The user can run a single turn manually at any point without the loop interfering.
- Safety model invariants hold throughout a full test run.

---

### v0.18.0 - Protocol Method Specification

**Goal:** Define the operating method formally - one per-task core with a sequence
layer and lifecycle labels over it - so the skill teaches exactly one method.

**Includes:**
- A canonical `PROTOCOL_METHOD.md` (+ template mirror): method layers, the lifecycle
  mapping to existing states, vocabulary (Sequence Owner duty, Operator action
  category, Environment/Preflight Stop, Protocol Repair), precedence rules, and the
  `AI_SEQUENCE.md` contract.
- One-line deference references from the role files and entry docs.
- Installer support for the new canonical file.

**Does not include:**
- Any behavior change to the workflow scripts.
- A Director role, new states, or the `AI_SEQUENCE.md` artifact itself.

**Exit criteria:**
- All protocol docs describe one method; the contradiction-audit checks are clean.
- Fresh installs receive `PROTOCOL_METHOD.md`.

---

### v0.18.1 - Sequence Artifact

**Goal:** Ship the `AI_SEQUENCE.md` artifact per the contract frozen in v0.18.0.

**Includes:**
- A committed `templates/AI_SEQUENCE.md` (ordered task list, per-task status
  `pending`/`active`/`released`, release checkpoints, sequence notes).
- Gitignore rules (repo, snippet, both installers) - the root artifact is local and
  never committed.
- Installer support: copy the template to the project root without overwriting.
- README "Sequence Artifact" section and local-file list updates.
- A manually-run first sequence: this release itself, dogfooded as a local file.

**Does not include:**
- Sequence automation, auto-advance, or workflow-script changes.
- A Director role or `SEQUENCE_*` states.

**Exit criteria:**
- Fresh installs receive `AI_SEQUENCE.md` (root, ignored) and the gitignore rule.
- The contract in `PROTOCOL_METHOD.md` reads "since v0.18.1".
- Workflow scripts have zero diff.

---

### v0.18.2 - Controlled Stop Routing (stub)

**Goal:** Distinguish and route the protocol's stop situations cleanly, without new
roles or automation: User approval authority, Operator/manual adapter actions,
Protocol Repair, Environment/Preflight stops, and Sequence decisions each get an
explicit routing description so tools and users always know which kind of stop they
are in and who acts next.

---

### v1.0.0 - Stable Protocol Release

**Goal:** Declare the protocol stable and ready for use in production projects with a
commitment to backward compatibility.

**Includes:**
- All milestones through v0.18.x validated.
- Full cross-platform support confirmed.
- Any breaking changes from the 0.x line resolved and documented.
- A migration guide if any protocol behavior changed incompatibly.
- README, CHANGELOG, and ROADMAP consistent with the released state.

**Does not include:**
- New feature additions (those go in post-1.0 releases).

**Exit criteria:**
- The protocol has been used in at least one real project through a full autonomous loop.
- All safety model guarantees hold in practice.
- No known unresolved issues from the 0.x line.

---

## Safety Model for Autonomous Dialogue

These boundaries apply to any automated turn in v0.16.0 and especially v0.17.0. Every item
in the "must stop for the user" list is a hard stop, not a soft guideline.

### What can run automatically

- Reading files, searching code, inspecting project state.
- Writing and editing source files within the approved task scope.
- Updating `AI_HANDOFF.md` and `NEXT_TURN.md`.
- Running read-only verification commands (`git status`, `git diff`, lint, typecheck, tests
  where the project supports them).
- Generating and routing prompts between tools.

### What must stop for the user

- Any `git` command that modifies history or the remote: `git add`, `git commit`, `git push`,
  force push, rebase, amend.
- Deploy commands (any tool, any environment).
- Live database migrations, destructive data operations, database resets.
- Secret or environment variable changes.
- Production configuration changes.
- File deletion outside the approved task scope.
- Scope expansion beyond what the user approved for the current session.
- Business or product decisions the Master cannot resolve using existing approved scope.

### Hard stop conditions for the loop

The loop must exit and wait for the user when any of the following are true:

- `State: WAITING_FOR_USER` or `State: BLOCKED`.
- `State: REVIEW_DONE` (user reviews result and commits).
- Turn budget exceeded (configurable; default maximum 3 turns per loop session).
- Spending budget exceeded (per-turn or per-session cap).
- State mismatch detected (`Waiting For` does not match the expected actor).
- An unsafe command is required.
- An unrecognized state is encountered.
- Any tool exits with a non-zero code during an automated turn.

### Invariants that must hold throughout

- Reviewer != Implementer (the same tool may not review its own work).
- No role may self-approve commits or deploys.
- No role swap without explicit user approval.
- The user remains the final approval point for all commits, pushes, and production actions.
