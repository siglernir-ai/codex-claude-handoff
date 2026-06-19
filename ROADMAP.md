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

### v0.18.2 - Controlled Stop Routing + Release Authorization Gate

**Goal:** Route the protocol's stop situations cleanly so the User is the authority
and approval point - not the default handler for every technical stop - without new
roles, new states, or new automation.

**Includes:**
- A "Stop Routing" section in `PROTOCOL_METHOD.md` with six stop categories:
  User Release Authorization, User Decision, Operator Manual Action, Protocol
  Repair, Environment/Preflight, and Non-callable Actor - each stating who acts
  next and whether a user decision is required.
- `REVIEW_DONE` redefined as a Reviewer attestation (`MASTER.md`, "Review
  Outcomes"): Changed Files reviewed, verification checked or skips justified,
  local protocol files excluded from commit scope, no unsafe scope. After it, the
  user's step is release authorization only.
- Stop-category lines in the workflow script output (message-level only; exit
  codes and automation behavior unchanged).
- State-table and workflow wording updates across the docs.
- The future automation model stated (not implemented): Reviewer attestation ->
  User release authorization -> an authorized operator/adapter executes the
  commit/push/tag.

**Does not include:**
- New roles or states; sequence auto-advance; automatic commit/push/tag; a Codex
  adapter; any weakening of the approval boundaries.

**Exit criteria:**
- Every printed stop names its category and whether a user decision is required.
- `REVIEW_DONE` is documented everywhere as Reviewer attestation + user release
  authorization, not user technical review.
- Workflow script exit codes and automation behavior are unchanged.
- The remaining automation limitations are recorded: investigation/planning turns
  cannot be safely automated by the Claude Code CLI, and Master/Reviewer turns are
  non-callable without a Codex adapter.

---

### v0.19.0 - Adapter Registry + Automation Harness

**Goal:** Move automation decisions out of scattered hard-coded checks and into a
small adapter capability model.

**Includes:**
- Canonical `ADAPTERS.md` (+ template mirror): adapter contract, required fields,
  default local registry, and state-specific callable/manual limits.
- `handoff.ps1 adapters` and `handoff.sh adapters`: print each role, bound tool,
  callable yes/no, automatable states, manual/non-callable reason, safety limits,
  stop category, user authorization, and next enablement step.
- `cycle` and `loop` resolve callable turns through the adapter layer.
- Honest default status: Implementer bound to Claude Code is callable only for
  `READY_FOR_IMPLEMENTATION`; Codex-bound Master/Reviewer turns are manual until a
  real local adapter exists; investigation/planning/question turns remain manual.

**Does not include:**
- A fake Codex adapter, MCP/API claims, new roles, new states, automatic commit,
  push, tag, deploy, database, secrets, or product-decision automation.

**Exit criteria:**
- `adapters` command reports the resolved local registry.
- `cycle` and `loop` no longer make callable/non-callable decisions through
  scattered tool-name checks.
- Canonical/template mirrors and installers ship `ADAPTERS.md`.
- Documentation states clearly that Codex is non-callable unless a verified local
  adapter exists.

---

### v0.19.1 - Authorized Release Executor

**Goal:** Add a release-execution adapter that can perform commit/push/tag only
after explicit user release authorization.

**Includes:**
- A command that consumes Reviewer-attested `REVIEW_DONE` state and exact Changed
  Files, asks for explicit user authorization, then runs only the authorized git
  operations.
- Dry-run and scope verification before any mutating git command.
- Clear refusal when Changed Files do not match `git status`.
- PowerShell `release-check` and `release` commands; Bash reports the limitation
  honestly and does not run release mutations.
- Existing release checks before mutation: whitespace check, changed-script parser
  checks, shell syntax checks when available, and canonical/template mirror checks.
- Release audit uses the current handoff's structured `Task Actors` (actual
  Implementer and Reviewer) rather than only the global role binding, so one-off
  role assignments are audited correctly.

**Does not include:**
- Deploys, database work, secrets, production configuration, or automatic approval.
- A new role, new protocol state, fake Codex-callable adapter, or automatic
  sequence advancement.

**Exit criteria:**
- `release-check` prints the exact release plan without mutating git.
- `release` refuses without the exact authorization token, refuses outside
  `REVIEW_DONE` / `Waiting For: User`, and refuses when actual Task Actors are
  missing, ambiguous, or not independent.
- `release` stages only approved Changed Files, commits first, then creates/pushes
  the version tag only after the commit succeeds.
- Local coordination files stay excluded from release scope.

---

### v0.19.2 - Sequence Advance Command

**Goal:** Add a minimal command for advancing `AI_SEQUENCE.md` after user-approved
release checkpoints.

**Includes:**
- Validate that the current handoff completed release authorization.
- Mark the released task and select the next active task without inventing
  `SEQUENCE_*` states.
- Keep `AI_SEQUENCE.md` local and ignored.
- PowerShell `sequence-check` (dry run) and `sequence-advance` (apply); Bash refuses
  honestly and points to PowerShell.
- Verify the released commit and tag in git read-only before advancing.

**Does not include:**
- Any git mutation (commit/push/tag), deploy, database, or secret action.
- A new role, new protocol state, fake Codex-callable adapter, or editing tracked
  source/release files.

**Exit criteria:**
- `sequence-check` prints the exact local changes and mutates nothing.
- `sequence-advance` fails closed when the released version/commit/tag cannot be
  verified, when the released version is not the single active task, or when the next
  task is missing/ambiguous.
- `sequence-advance` marks the released task `released` with its checkpoint, sets the
  next task `active`, and prepares `AI_HANDOFF.md` (with `## Task Actors`) for it.
- `AI_SEQUENCE.md` and `AI_HANDOFF.md` stay local/gitignored; no tracked source or
  release file is changed by the command.

---

### v0.20.0 - Protocol Test Harness

**Goal:** Add repeatable protocol-level tests for state routing, adapter decisions,
stop categories, mirror parity, and safety boundaries.

**Includes:**
- Scripted fixtures for key states and role bindings.
- Assertions for no new roles/states, no unsafe automation, and consistent
  PowerShell/Bash status behavior.
- PowerShell-first `scripts/protocol-tests.ps1` (full suite, black-box against the real
  `handoff.ps1` using disposable temp fixtures) and a Bash companion
  `scripts/protocol-tests.sh` (honest Bash-side checks + mirror parity).
- Template mirrors of both scripts and installer enumeration.

**Does not include:**
- Any git mutation, deploy, database, or secret action; new role; or new protocol state.
- Reading or mutating the real `AI_HANDOFF.md` / `AI_SEQUENCE.md`.

**Exit criteria:**
- `scripts/protocol-tests.ps1` runs the suite and exits 0 when the protocol is healthy,
  1 on any failure, using only temporary fixtures.
- `scripts/protocol-tests.sh` verifies the Bash refusals and mirror parity and exits 0.
- Tests assert fail-closed behavior for the release and sequence guards and confirm
  dry-run commands change no files and run no git mutations.
- Canonical/template mirrors and installers ship both harness scripts.

---

### v1.0.0 - Stable Protocol Release

**Goal:** Declare the protocol stable and ready for use in production projects with a
commitment to backward compatibility, around the bounded-automation model that actually
exists.

**Includes:**
- All milestones through v0.20.0 validated with the protocol test harness and the README
  release checklist.
- Cross-platform support confirmed: PowerShell is the executor host; the Bash scripts
  cover status/next/start/commit-check/adapters and refuse the PowerShell-only executors
  honestly.
- Breaking changes from the 0.x line resolved and documented. There are none: 1.0.0 is a
  packaging release.
- Migration notes: no migration steps required (see CHANGELOG 1.0.0).
- README, CHANGELOG, and ROADMAP consistent with the released state.

**Does not include:**
- New feature additions (those go in post-1.0 releases).
- Full autonomous Codex <-> Claude dialogue (requires a verified local Codex callable
  adapter; deferred to post-1.0).

**Exit criteria (honest status):**
- All milestones through v0.20.0 validated and the safety model boundaries enforced and
  test-covered (release/sequence guards fail closed; dry runs change no files and run no
  git mutations). MET.
- No known unresolved issues from the 0.x line. MET.
- DEFERRED (intentionally not met): "used in at least one real project through a full
  autonomous loop." A full autonomous loop is not possible with the implemented
  automation - Master and Reviewer turns (Codex by default) are non-callable because no
  verified local Codex adapter exists. v1.0.0 declares the bounded-automation protocol
  stable; full autonomy remains future work and does not gate this stability release.

---

## Post-1.0 Milestones

### v1.1.0 - Codex CLI Adapter Verification

**Goal:** Determine, honestly and evidence-first, whether the local Codex CLI can serve
as a safe protocol adapter - the first concrete step toward the deferred full
autonomous loop without weakening any safety boundary.

**Includes:**
- A read-only verification record in `ADAPTERS.md` (+ template mirror): the candidate
  `codex exec` invocation shape and the criteria a future verification turn must meet
  before any Codex role/turn may be marked callable.
- Refreshed adapter-status wording in `ADAPTERS.md` and README (discovery alone is not
  sufficient).

**Does not include:**
- Marking Codex callable, automating Master/Reviewer turns, a Codex MCP/API bridge,
  new roles, new states, or any script behavior change.

**Exit criteria (honest status):**
- The candidate `codex exec` invocation shape and the callability criteria are
  recorded. MET.
- VERIFIED: a read-only `codex exec` smoke test ran successfully (read `AI_HANDOFF.md`,
  emitted JSONL, wrote `CODEX_READONLY_SMOKE_OK`, no git change), demonstrating
  read-only safety and deterministic output for a manual run. The installed CLI does
  not accept `--ask-for-approval`, so that flag was dropped from the candidate shape.
- STILL `callable: no`: no protocol wrapper/adapter has been implemented and tested, so
  the smoke test alone does not make Codex callable. A future turn must implement and
  test a safe adapter (all four criteria) before any Codex adapter is marked callable.

---

### v1.2.0 - Codex Reviewer Adapter Proof of Concept

**Goal:** Build the first real, guarded bridge from the verified read-only smoke test
into a per-turn Codex invocation wired into the workflow scripts - without weakening any
safety boundary or pretending full autonomy exists.

**Includes:**
- PowerShell `handoff.ps1 review-check` (dry run) and `review-run` (read-only execution
  after an explicit `yes` confirmation) for the Reviewer turn during `READY_FOR_REVIEW`.
- Fail-closed guards: bound Reviewer is Codex; exactly one Task Actors Implementer and
  Reviewer; actual Reviewer is Codex and != actual Implementer; Changed Files match git
  status after excluding local coordination files.
- Safe Codex CLI resolution (`CODEX_CLI` override, then PATH) verified with
  `exec --help`; invocation only via the v1.1.0-verified read-only shape (no
  `--ask-for-approval`, no bypass flags).
- Local, gitignored capture artifacts (`CODEX_REVIEW.jsonl`, `CODEX_REVIEW_LAST.md`).
- Bash refuses honestly and points to PowerShell.
- Adapter/method/README docs, protocol tests, templates, and mirrors updated.

**Does not include:**
- Automatic `AI_HANDOFF.md` state transitions from the verdict (delivered in v1.3.0 via
  `review-apply`).
- Marking any Codex role callable; automating Master turns; an MCP/API bridge; new
  roles or states; any git/commit/push/tag/deploy/db/secret action.

**Exit criteria (honest status):**
- `review-check` prints the plan and mutates nothing; `review-run` runs Codex read-only,
  captures the verdict locally, and changes no git state and no `AI_HANDOFF.md`. MET.
- Guards fail closed and are test-covered; Bash refuses honestly; mirrors are in sync. MET.
- Capture-only POC as of v1.2.0; the end-to-end callable Reviewer turn arrives in v1.3.0.

---

### v1.3.0 - Automated Reviewer Turn (review-apply)

**Goal:** Complete the Reviewer's `READY_FOR_REVIEW` turn end-to-end by applying the verdict
captured by `review-run`, without weakening any safety boundary and without making the turn
auto-runnable inside `loop`/`cycle`.

**Includes:**
- PowerShell `handoff.ps1 review-apply`: consumes `CODEX_REVIEW_LAST.md` and applies the
  local `AI_HANDOFF.md` transition (`APPROVED` -> `REVIEW_DONE` / `Waiting For: User`;
  `BLOCKED` -> `READY_FOR_IMPLEMENTATION` / `Waiting For: Implementer`), after an explicit
  `yes` (or `-Yes`). Modeled on `sequence-advance`; edits only `AI_HANDOFF.md`; no Codex
  re-invocation; no git.
- A strict four-line verdict block in the `review-run` prompt (`VERDICT`, `REVIEWER: Codex`,
  `TASK` matching the current task, non-empty `REASON`) and a fail-closed parser.
- `review-apply` re-runs every `review-run` protocol guard before any write.
- A new `AutoLoopEligible` adapter flag, distinct from `callable`. `loop` and `cycle` gate on
  `AutoLoopEligible`, so an explicit-only adapter makes `loop` STOP rather than auto-run.
- `-Yes` added to `loop` for automation/tests (all other loop guards still apply).
- Tests (`protocol-tests.ps1` section 10 + a Reviewer-adapter assertion; `protocol-tests.sh`
  refusal check), docs (ADAPTERS/PROTOCOL_METHOD/README/CHANGELOG), templates, and mirrors.

**Does not include:**
- Loop integration of Reviewer turns (deferred to v1.4.0).
- Any Master automation (a capture-only Master POC may be planned as v1.3.1); marking
  Master/Codex callable; an MCP/API bridge; new roles or states; any
  git/commit/push/tag/deploy/db/secret action; any release authorization.

**Exit criteria (honest status):**
- Reviewer/Codex `READY_FOR_REVIEW` is `callable: yes` via `review-run` + `review-apply`,
  fail-closed, edits only `AI_HANDOFF.md`, and is test-covered. MET.
- `AutoLoopEligible: no` for Reviewer/Codex: `loop` stops and `cycle` refuses a Reviewer
  turn, proven by tests. MET.
- Master/Codex remains `callable: no`; no release/git automation added. MET.

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

The loop must exit when any of the following are true. Since v0.18.2 each stop is
categorized (see `PROTOCOL_METHOD.md`, "Stop Routing"): some require a user decision
or release authorization, others are operator actions, protocol repair, or
environment stops - but the loop never continues past any of them on its own:

- `State: WAITING_FOR_USER` or `State: BLOCKED`.
- `State: REVIEW_DONE` - User Release Authorization: the user authorizes the
  reviewed release, and an operator/manual action runs the commit/push/tag.
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
