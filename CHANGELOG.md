# Changelog

All notable changes to the codex-claude-handoff protocol are documented here.
Versions follow the `VERSION` file in `.ai/skills/codex-claude-handoff/`.

## 1.2.0 - Codex Reviewer Adapter Proof of Concept

- Added a narrow, conservative Codex Reviewer proof of concept to `scripts/handoff.ps1`:
  `review-check` (dry run) and `review-run` (read-only execution after an explicit `yes`
  confirmation). They are eligible only during `State: READY_FOR_REVIEW` /
  `Waiting For: Reviewer`. This is the first per-turn Codex invocation wired into the
  workflow scripts, building on the v1.1.0 verified read-only `codex exec` shape.
- Fail-closed guards (shared `Get-ReviewPlan`): the bound Reviewer must be Codex; the
  handoff `Task Actors` must have exactly one Implementer and one Reviewer; the actual
  Reviewer must be Codex and must differ from the actual Implementer (the independent-
  review invariant is unchanged); and the `Changed Files` list must match `git status`
  after excluding local coordination files. The Changed Files / git comparison reuses the
  release-grade parser and `Test-SameFileSet`.
- Safe Codex CLI resolution: prefer the `CODEX_CLI` environment override, then probe a
  local install under `%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe`, then `codex` on
  `PATH`; only candidates that pass `exec --help` are accepted, so a PATH alias that
  exists but is not runnable is refused honestly. No user-specific path is hardcoded in
  scripts, docs, or templates. Codex is invoked only as
  `exec --cd <repo> --sandbox read-only --ephemeral --json --output-last-message <file>
  <prompt>`; never `--ask-for-approval`, `--dangerously-bypass-approvals-and-sandbox`, or
  danger-full-access.
- Capture-only by design: `review-run` saves the `--json` event stream to
  `CODEX_REVIEW.jsonl` and the Codex final verdict to `CODEX_REVIEW_LAST.md` (both local
  and gitignored), and then stops. It runs no git command and does NOT transition
  `AI_HANDOFF.md`. A human or the Master applies the actual `REVIEW_DONE` /
  `READY_FOR_IMPLEMENTATION` transition from the captured verdict; automating that is
  deferred to v1.3.0.
- Honest status: this is a POC, not a callable Reviewer adapter. The Default Local
  Registry in `ADAPTERS.md` keeps Reviewer/Codex `callable: no`, unchanged. Added a "Codex
  Reviewer POC (v1.2.0)" section to `ADAPTERS.md` (+ template mirror) and a note in
  `PROTOCOL_METHOD.md` (+ mirror) recording the POC as a guarded Operator Manual Action,
  not a callable role turn.
- Added the two capture artifacts to `.gitignore`, `templates/gitignore-snippet.txt`, both
  installers' gitignore handling, and the PowerShell clean-tree / release-scope exemption
  list, so they are never committed and never trip the `cycle`/`loop`/`release` guards.
- Bash `handoff.sh review-check` / `review-run` refuse honestly and point to the PowerShell
  POC; no Bash Codex-invocation path was added.
- Added protocol tests: `scripts/protocol-tests.ps1` covers the guard matrix (wrong state,
  non-Codex bound Reviewer, actual Reviewer == Implementer, no reviewable files, the
  protocol-guards-pass path) and that `review-run` fails closed with Environment/Preflight
  when the Codex CLI is unavailable, changes no `AI_HANDOFF.md`, and creates no commit;
  `scripts/protocol-tests.sh` covers the Bash refusals. Both harness header stamps bumped
  to v1.2.0.
- Robust prompt delivery (review follow-up fix): `review-run` now feeds the review
  prompt to Codex on stdin (`codex exec ... -`) instead of as a command-line argument.
  `Start-Process -ArgumentList` does not robustly quote a multi-word element, so the
  prompt was being split into separate argv tokens (real smoke: Codex `error: unexpected
  argument 'exactly' found`). The prompt is written to a temp file and supplied via
  `-RedirectStandardInput`; stderr is now captured and printed on non-zero exit / timeout
  for explainable failures. Added a protocol test with a fake Codex that records its
  stdin and argv, proving the multi-word prompt arrives intact on stdin and never as
  argv tokens.
- Bounded-runtime review prompt (review follow-up fix): the generated review prompt is
  now tightly scoped so the read-only review reliably finishes and writes
  `CODEX_REVIEW_LAST.md` within the timeout. It tells Codex to be fast and minimal, NOT
  to load AGENTS.md / CLAUDE.md / the codex-claude-handoff skill or other protocol/skill
  files, to inspect only `AI_HANDOFF.md`, `git status --short`, and `git diff --` of the
  Changed Files, to use `rg -- <pattern>` for ripgrep patterns beginning with `--`, and
  to end with exactly one line `VERDICT: APPROVED` or `VERDICT: BLOCKED` plus a one-line
  reason. (Previously the broad prompt led Codex to explore the whole protocol and time
  out.) Capture-only semantics, stdin delivery, and the timeout/cleanup path are
  unchanged.
- review-run reliability fixes proven by a real local Codex run (88s/57s, well under the
  timeout): (1) cache the `Start-Process -PassThru` process handle so `$proc.ExitCode` is
  read reliably - without it a SUCCESSFUL run reported a null exit code that looked like a
  non-zero failure; (2) fail closed (exit 6) if Codex exits 0 but writes no
  `CODEX_REVIEW_LAST.md`, so "success" always means a verdict was actually captured (no
  false success); (3) tighten review eligibility to `Waiting For: Reviewer` exactly, to
  match the approved scope (the bound tool-name form is no longer accepted). Added
  protocol tests for the clean-exit capture, the no-verdict fail-closed path, and the
  Waiting-For requirement.
- Bounded `review-run` with a fail-closed timeout (review follow-up fix): added
  `-TimeoutSeconds` (default 180) and ran Codex as a tracked child process via
  `Start-Process -PassThru`. On timeout `review-run` terminates the Codex process tree
  (`taskkill /T` + `Kill()`), preserves any partial `CODEX_REVIEW.jsonl` labelled
  incomplete, removes any partial `CODEX_REVIEW_LAST.md` so no incomplete output is read
  as a verdict, makes no git or `AI_HANDOFF.md` change, and exits non-zero (exit 4). Added
  a `-Yes` switch to skip the interactive confirmation for automation/tests (read-only
  capture-only regardless), and removed shell metacharacters from the review prompt so it
  passes safely as a single process argument. Added a protocol test (fake hanging Codex)
  proving the timeout kills the process, writes no verdict, and changes no git/handoff.
- No new role, no new protocol state, no MCP/API claim, and no commit/push/tag/deploy/db/
  secret automation; `review-run` reuses the existing exit-code vocabulary (4 for the
  bounded timeout). Bumped `VERSION` to 1.2.0 (canonical and template mirror).

## 1.1.0 - Codex CLI Adapter Verification

- First post-1.0 task: verified whether the local Codex CLI can serve as a safe
  protocol adapter. Outcome: a Codex CLI binary is discoverable on the machine
  (an OpenAI Codex install exposing `codex exec`, `review`, and `mcp-server`), and a
  read-only `codex exec` smoke test was run successfully (it read `AI_HANDOFF.md`,
  emitted JSONL events, wrote the final message `CODEX_READONLY_SMOKE_OK`, and left
  `git status` unchanged). Codex nonetheless remains `callable: no` for all roles and
  all states, because no protocol wrapper/adapter has been implemented and tested: a
  successful manual smoke test is necessary but not sufficient to mark a role callable.
- Added a "Codex CLI Verification (v1.1.0)" section to `ADAPTERS.md` (+ template
  mirror) recording the verified candidate `codex exec` invocation shape (`--cd`, a
  read-only `--sandbox`, `--ephemeral`, `--output-last-message`, `--json`; the installed
  CLI does NOT accept `--ask-for-approval`, so that flag is not used) and the four
  criteria a future verification turn must demonstrate and record before any Codex
  role/turn may be marked callable: read-only safety, deterministic parseable output,
  bounded approval (never `--dangerously-bypass-approvals-and-sandbox` or
  danger-full-access), and preserved Reviewer independence (Codex Reviewer admissible
  only when Codex is not also that task's Implementer).
- Refreshed the stale `ADAPTERS.md` State-Specific Note and the README Adapter Registry
  status: "no Codex CLI present" became "a discovered Codex CLI binary - even with a
  passing read-only smoke test - is not sufficient on its own without an implemented and
  tested protocol adapter." The independent-review invariant and `Task Actors` release
  audit are unchanged.
- No new role, no new protocol state, no script behavior change, and no fake
  MCP/API/Codex-callable adapter. No commit/push/tag/deploy/db/secret automation was
  added; the Default Local Registry decisions (Codex non-callable) are unchanged and
  remain covered by the existing protocol-test harness adapter checks.
- Bumped `VERSION` to 1.1.0 (canonical and template mirror) and the protocol-test
  harness header stamps to v1.1.0 (canonical and template mirror).

## 1.0.0 - Stable Protocol Release

- Declares the codex-claude-handoff protocol stable. This is a packaging and
  consistency release: it freezes the role model, states, gates, adapter contract,
  workflow scripts, and safety boundaries built through v0.20.0. No new role, state,
  automation path, or adapter capability was added.
- Validated all milestones through v0.20.0 with the protocol test harness
  (`scripts/protocol-tests.ps1` / `scripts/protocol-tests.sh`) and the README release
  checklist (VERSION mirror parity, canonical/template script parity, changelog entry).
- Documented the actual autonomy model honestly. The implemented automation is bounded:
  `cycle`/`loop` automate only the `READY_FOR_IMPLEMENTATION` Implementer turn bound to
  Claude Code; the guarded PowerShell release executor performs commit/push/tag only
  after `REVIEW_DONE`, exact-scope checks, and an explicit user authorization token; and
  `sequence-advance` updates only the local, gitignored coordination files. Master and
  Reviewer turns (Codex by default) remain non-callable because this repository has no
  verified local Codex CLI, MCP adapter, or API bridge. Investigation, planning, and
  question turns remain manual.
- Compatibility / migration: there are no incompatible breaking changes from the 0.x
  line. A project already on any 0.1x version upgrades to 1.0.0 by bumping the `VERSION`
  file (canonical and template mirror); no handoff state, role binding, script command,
  exit code, or `.gitignore` rule changed. No migration steps are required.
- Honest scope note: the original ROADMAP v1.0.0 exit criterion "used in at least one
  real project through a full autonomous loop" is intentionally NOT met and is deferred
  to post-1.0 work. Full autonomous Codex <-> Claude dialogue requires a verified local
  Codex callable adapter, which does not exist. v1.0.0 declares the bounded-automation
  protocol stable, not full autonomy. See ROADMAP.md.
- Preserved all safety boundaries: user release authorization, actual `Task Actors`
  release audit, no deploy/database/secrets/production-config automation, and no fake
  MCP/API/Codex adapter claims.
- Cleaned stale version pins in `ADAPTERS.md` State-Specific Notes (now present-tense
  current status) and bumped the protocol-test harness header stamps to v1.0.0
  (canonical and template mirror).
- Bumped `VERSION` to 1.0.0 (canonical and template mirror).

## 0.20.0 - Protocol Test Harness

- Added `scripts/protocol-tests.ps1`: a PowerShell-first, black-box protocol test
  harness. Each test builds a disposable fixture project in a temp directory and runs
  the real `handoff.ps1` against it as a child process, asserting on exit codes and
  output. Coverage: state routing, turn-ownership mismatch routing, adapter decisions,
  stop categories, release-executor guards (fail closed), sequence-advance guards (fail
  closed), mirror parity, and safety boundaries (dry runs change no files / run no git
  mutations). It never reads or mutates the real `AI_HANDOFF.md` / `AI_SEQUENCE.md`.
  Exit 0 = all passed, 1 = any failure.
- Added `scripts/protocol-tests.sh`: an honest Bash companion that verifies the
  Bash-side behavior `handoff.sh` owns (the PowerShell-only `release`/`sequence`
  executors are refused honestly and change no files) plus canonical/template mirror
  parity, and points to the PowerShell suite for full coverage.
- The harness found and this release fixes a latent crash in `handoff.ps1`: the
  release/commit scope comparison built a `HashSet` directly from a possibly-empty
  collection, which PowerShell binds as `$null`, throwing "Value cannot be null"
  instead of failing closed cleanly. `Test-SameFileSet` is now null-safe and
  `commit-check` routes through it. No behavior change for non-empty inputs.
- Added template mirrors `templates/scripts/protocol-tests.ps1` and
  `templates/scripts/protocol-tests.sh`, and added both scripts to the PowerShell and
  Bash installers' workflow-script lists (and the macOS/Linux `chmod +x` hint).
- Updated README (new "Protocol Test Harness" section + install file lists) and ROADMAP
  (v0.20.0 exit criteria). No new role, no new protocol state, no fake
  MCP/API/Codex-callable adapter, and no commit/push/tag/deploy/db/secret automation
  was added; git mutations remain only in the guarded release executor.
- Bumped `VERSION` to 0.20.0 (canonical and template mirror).

## 0.19.2 - Sequence Advance Command

- Added PowerShell `handoff.ps1 sequence-check` (dry run) and `sequence-advance`
  (apply): local-only commands that advance `AI_SEQUENCE.md` and prepare
  `AI_HANDOFF.md` after a user-approved release checkpoint, so the Sequence Owner no
  longer hand-edits both files.
- `sequence-advance` verifies the released commit and tag in git read-only (and that
  the tag points at the commit), requires the released version to be the single
  `active` task, marks it `released` with its checkpoint, marks any
  `-SupersededVersions` bundled tasks `released`, sets the next task `active`, and
  prepares a fresh `AI_HANDOFF.md` (`NEEDS_ANALYSIS` / `Waiting For: Master`, with a
  `## Task Actors` section defaulted to `TBD`). It fails closed on any missing,
  unverifiable, or ambiguous input.
- The command edits only the local, gitignored `AI_SEQUENCE.md` and `AI_HANDOFF.md`.
  It never runs git add/commit/push/tag, deploys, database, or secret actions, and no
  new git-mutation path was added. No new role or protocol state was introduced.
- Bash `handoff.sh sequence-check` / `sequence-advance` refuse honestly and point to
  the PowerShell command; no Bash sequence-mutation path was added.
- Updated adapter/method/Master docs, README, roadmap, templates, and mirrors for the
  sequence advance command.
- Bumped `VERSION` to 0.19.2 (canonical and template mirror).

## 0.19.1.1 - Release Executor Actual Actor Audit Fix

- Added structured `AI_HANDOFF.md` `Task Actors` support for release audit:
  actual Implementer and actual Reviewer are now distinct from the global role
  binding used for routing/adapters.
- Updated PowerShell `release-check` / `release` to print actual task actors and
  fail closed when the actual Implementer or Reviewer is missing, ambiguous, or
  the same tool.
- Updated docs and templates to describe `Task Actors` and the release audit
  provenance rule.
- Bumped `VERSION` to 0.19.1.1 (canonical and template mirror).

## 0.19.1 - Authorized Release Executor

- Added PowerShell `handoff.ps1 release-check -Version vX.Y.Z` to dry-run the
  guarded release plan without mutating git.
- Added PowerShell `handoff.ps1 release -Version vX.Y.Z -Message "<msg>"
  -Authorize "I_AUTHORIZE_RELEASE_vX.Y.Z"` to execute commit/push/tag only after
  `REVIEW_DONE`, `Waiting For: User`, exact Changed Files scope validation,
  Reviewer != Implementer, pre-release checks, and an exact user authorization
  token.
- Release execution stages only approved release files, excludes local coordination
  files (`AI_HANDOFF.md`, `AI_SEQUENCE.md`, `NEXT_TURN.md`, `USER_REQUEST.md`,
  `HANDOFF_LOOP.log`), commits before tagging, pushes the tag only after the commit
  path succeeds, and stops on the first failed check or git command.
- Bash `handoff.sh release-check` and `handoff.sh release` now refuse honestly and
  point to the PowerShell executor; no Bash git mutation path was added.
- Updated adapter/method docs, Master operator docs, README, roadmap, templates, and
  mirrors for the authorized release executor. No Codex-callable adapter, new role,
  new state, deploy/db/secrets automation, or sequence auto-advance was added.
- Bumped `VERSION` to 0.19.1 (canonical and template mirror).

## 0.19.0 - Adapter Registry + Automation Harness

- Added canonical `ADAPTERS.md` (+ template mirror): adapter contract, required
  fields, default local registry, and honest local status. Only Implementer bound
  to Claude Code is callable, and only for `READY_FOR_IMPLEMENTATION`; Codex-bound
  Master/Reviewer turns remain manual because no verified local Codex adapter
  exists.
- Added `handoff.ps1 adapters` and `handoff.sh adapters` to print each role's bound
  tool, callable status, automatable states, manual/non-callable reason, safety
  limits, stop category, user authorization, and next enablement step.
- Refactored `cycle` and `loop` to resolve callable/manual automation through an
  adapter resolver instead of scattered hard-coded assumptions. Behavior remains
  intentionally narrow: no fake Codex adapter and no automation for investigation,
  planning, question turns, commits, pushes, tags, deploys, databases, secrets, or
  product decisions.
- Updated protocol docs, role binding notes, README, installers, and roadmap to
  describe adapter status and the remaining v0.19.x/v0.20.0 fast path.
- Bumped `VERSION` to 0.19.0 (canonical and template mirror).

## 0.18.2.1 - Stop Routing Consistency Fix

- Fixed the `PROTOCOL_METHOD.md` Non-Contradiction Rules table (+ mirror): the
  "Automation stop semantics" row now points to the v0.18.2 "Stop Routing" section
  and its six stop categories. Workflow scripts must print one of those categories;
  exit codes remain script behavior and are not the category system.
- Bumped `VERSION` to 0.18.2.1 (canonical and template mirror).

## 0.18.2 - Controlled Stop Routing + Release Authorization Gate

- Added a "Stop Routing" section to `PROTOCOL_METHOD.md` (+ mirror) with six stop
  categories - User Release Authorization, User Decision, Operator Manual Action,
  Protocol Repair, Environment/Preflight, and Non-callable Actor - each stating who
  or what acts next and whether a user decision is required. Not every stop belongs
  to the User.
- `REVIEW_DONE` is now defined as a Reviewer attestation (`MASTER.md`, "Review
  Outcomes"): Changed Files reviewed against scope, verification checked or every
  skip justified, local protocol files excluded from commit scope, and no unsafe
  deploy/database/production-config/secrets issue. After `REVIEW_DONE` the user's
  step is Release Authorization only - approving the commit/push/tag - not re-running
  technical verification.
- Workflow scripts (`handoff.ps1`, `next-step.ps1`, `handoff.sh`, `next-step.sh`)
  now print a stop-category line at every stop they report: release authorization,
  user decision, operator action, protocol repair, environment/preflight, or
  non-callable actor. Message-level change only - all exit codes and automation
  behavior are unchanged. Added small shared helpers (`Get-StopCategoryLine` in
  PowerShell, `_stop_category` in Bash).
- Updated `REVIEW_DONE` wording across the state tables (`IMPLEMENTER.md`,
  `templates/CLAUDE.md`, `templates/AGENTS.md`, `README.md`) and the README
  Daily Workflow / Short Workflow Example / commit-check / Release Discipline
  sections: the Reviewer attests technical readiness; the user grants release
  authorization.
- Stated the future automation model in `PROTOCOL_METHOD.md` (NOT implemented):
  Reviewer attestation -> User release authorization -> an authorized
  operator/adapter may execute the commit/push/tag.
- `ROADMAP.md`: v0.18.2 milestone filled in; the loop hard-stop intro now references
  the stop categories without weakening any stop condition.
- Remaining automation limitations recorded: investigation/planning turns cannot be
  safely automated by the Claude Code CLI (cannot restrict edits to AI_HANDOFF.md
  only in non-interactive mode), and Master/Reviewer turns are non-callable without
  a Codex adapter.
- Bumped `VERSION` to 0.18.2 (canonical and template mirror).

## 0.18.1 - Sequence Artifact

- Shipped the `AI_SEQUENCE.md` artifact per the contract frozen in v0.18.0:
  a committed `templates/AI_SEQUENCE.md` with the ordered task list, per-task status
  (`pending`, `active`, `released`), release checkpoints, and sequence notes. The
  root artifact is local, gitignored, and never committed; per-task execution state
  stays in `AI_HANDOFF.md`.
- Added `AI_SEQUENCE.md` to the root `.gitignore` (anchored as `/AI_SEQUENCE.md` so
  the committed `templates/AI_SEQUENCE.md` stays tracked), to
  `templates/gitignore-snippet.txt`, and to both installers' .gitignore handling;
  both installers now also copy the template to the project root without overwriting
  an existing file.
- `PROTOCOL_METHOD.md` (+ mirror): contract wording transitioned from "planned for
  v0.18.1" to "since v0.18.1"; no method changes.
- `MASTER.md` (+ mirror): the Sequence Ownership section now states exactly when the
  Sequence Owner updates `AI_SEQUENCE.md` (after the user approves a numbered plan;
  when choosing the next task; after the user approves each release) and that it is
  never a replacement for current-task handoff state.
- `SKILL.md` (+ mirror): `AI_SEQUENCE.md` listed under required project files as a
  local sequence artifact. Skill folder `README.md` (+ mirror): root-files table row.
- `templates/AGENTS.md` + `templates/CLAUDE.md`: minimal deference wording
  (Implementer does not edit the sequence artifact).
- `README.md`: new "Sequence Artifact" section; install/safety/verify file lists and
  gitignore-rule listings now include `AI_SEQUENCE.md` (and the previously missing
  `HANDOFF_LOOP.log` in two stale spots).
- `ROADMAP.md`: v0.18.1 milestone filled in; added a `v0.18.2 - Controlled Stop
  Routing` stub (distinguishing User approval, Operator actions, Protocol Repair,
  Environment/Preflight stops, and Sequence decisions). v0.18.2 is not implemented.
- Zero behavior change: no workflow script was modified.
- Bumped `VERSION` to 0.18.1 (canonical and template mirror).

## 0.18.0 - Protocol Method Specification

- Added canonical `.ai/skills/codex-claude-handoff/PROTOCOL_METHOD.md` (+ template
  mirror): the single normative definition of the operating method. One method,
  three layers: Layer 1 is the frozen per-task handoff method (states, gates,
  invariants - quoted with their source files, never restated); Layer 2 is the
  sequence layer (multi-task ordering as a "Sequence Owner" DUTY of the Master role,
  not a fourth role); Layer 3 maps lifecycle phases (Specification, Architecture,
  Tooling & Capability Plan, Release, Sequence update) onto existing states and
  gates as labels - a lifecycle phase is never a new state, role, or process.
- Vocabulary made official: Operator = a manual action category performed by the
  user (never an AI role); Environment/Preflight Stop and Protocol Repair = stop
  categories mapping to the existing automation exit codes (1/3/4 and 6).
  Director = reserved term, explicitly not a role in this version.
- Defined the `AI_SEQUENCE.md` contract (local, gitignored, ordering/progress/release
  checkpoints only, never crosses a REVIEW_DONE checkpoint without user approval,
  never committed). The artifact itself ships in v0.18.1.
- Added one-line deference references in `SKILL.md` (folder table row + role-model
  note), `MASTER.md` (new "Sequence Ownership" section), `IMPLEMENTER.md`,
  `ROLE_ASSIGNMENT.md` (new "Duties Note"), `templates/AGENTS.md`, and
  `templates/CLAUDE.md`.
- Fixed the stale `ROLE_ASSIGNMENT.md` Tooling Note to cover `loop` as well as
  `cycle`/`run-next`.
- Updated `README.md` (new "Protocol Method" section; install/skip/verify file lists
  include the new file), `ROADMAP.md` (v0.18.0 milestone + v0.18.1 stub; v1.0.0
  wording), and both installers to ship `PROTOCOL_METHOD.md`.
- Zero behavior change: no workflow script (`handoff.ps1/.sh`, `next-step.ps1/.sh`)
  was modified.
- Bumped `VERSION` to 0.18.0 (canonical and template mirror).

## 0.17.0 - Autonomous Loop Skeleton (Callable-Agent Loop)

- Added `handoff.ps1 loop [-MaxTurns N] [-BudgetUsd N] [-SessionBudgetUsd N]`: a bounded
  loop manager that routes each turn by State -> Role -> Tool, runs only callable safe
  turns, re-reads `AI_HANDOFF.md` after every automated turn, and stops cleanly with a
  clear reason. Defaults: MaxTurns 3, BudgetUsd 2 (per turn), SessionBudgetUsd 6.
- The only callable automated turn is `READY_FOR_IMPLEMENTATION` / Implementer bound to
  Claude Code - the same turn `cycle` automates. Master, Reviewer, and User turns are
  never automated: the loop prepares `NEXT_TURN.md`, prints the next actor and paste
  instruction, and stops with exit 0. Full Codex <-> Claude autonomy still requires a
  Codex callable adapter (future work; ROADMAP updated to say so honestly).
- One fail-closed confirmation per loop session (exact `yes`; null/EOF/empty/other
  cancels with exit 2). Argument validation: MaxTurns >= 1, BudgetUsd > 0,
  SessionBudgetUsd >= BudgetUsd (violations exit 1).
- Session budget enforced as worst-case authorized spend: a turn starts only if
  authorized-so-far + BudgetUsd <= SessionBudgetUsd; budget info is printed before
  confirmation and at every stop.
- Hard stops: non-callable next actor, unrecognized state (exit 6), Waiting For mismatch
  (exit 6, NEXT_TURN.md routed to User), Reviewer == Implementer (exit 1), dirty tree
  including untracked files (exit 1), missing npx/Claude (exit 3), NEXT_TURN.md refresh
  failure (exit 4), Claude non-zero exit (exit 5), MaxTurns reached (exit 0), session
  budget cap (exit 0). No new exit codes were introduced.
- Added a local append-only ASCII loop log `HANDOFF_LOOP.log` (session parameters, per-turn
  pre/post state, Claude exit codes, final stop reason). Added the file to `.gitignore`,
  `templates/gitignore-snippet.txt`, the clean-tree exemption list, and both installers'
  .gitignore handling. It must never be committed.
- Refactored shared automation helpers out of `Invoke-Cycle` so `cycle` and `loop` use one
  implementation: `Get-WorkingTreeState`, `Test-ClaudeAvailable`, `Invoke-ClaudeTurn`, and
  a shared local-handoff-files exemption list. `cycle` and `run-next` behavior is
  unchanged (one turn, confirmation, exit codes, messages).
- Bash `handoff.sh`: `loop` prints the shared blocked-automation message and exits 1
  (PowerShell/pwsh required); usage and header updated.
- Updated `README.md` (loop section: scope, hard stops, budget semantics, log, exit
  codes), `MASTER.md` and `templates/AGENTS.md` operator tables, and the ROADMAP v0.17.0
  milestone wording (loop skeleton, not full autonomous dialogue).
- Bumped `VERSION` to 0.17.0 (canonical and template mirror).

## 0.16.1 - Cycle Safety Hardening

- Confirmation guard now fails closed: `cycle` / `run-next` proceed only when the
  confirmation value is a non-null string whose trimmed value is exactly `yes`. Null
  (EOF, redirected no-input, non-interactive), empty, whitespace, or any other value
  cancels with exit code 2 and no method-call error.
- Clean working tree guard now includes untracked files: the preflight uses
  `git status --short --untracked-files=all` and blocks on any tracked or untracked
  change. Only the local handoff files (`AI_HANDOFF.md`, `NEXT_TURN.md`,
  `USER_REQUEST.md`) are exempt.
- Role invariant enforced in preflight: `cycle` / `run-next` block with exit code 1 if
  the Reviewer and the Implementer resolve to the same tool, before the Claude Code
  preflight and before confirmation.
- Updated stale canonical/template docs after v0.16.0: `MASTER.md` and
  `templates/AGENTS.md` now describe `cycle` as the primary bounded automation command
  with `run-next` as its alias, and state precisely what `handoff.ps1` automates (one
  confirmed Implementer turn) and what it never does (Master/Reviewer turns, commit,
  push, deploy). `ROLE_ASSIGNMENT.md` tooling note updated to `cycle` and documents
  the enforced invariant.
- Updated the README `cycle` eligibility step to include the role invariant and the
  untracked-files-included clean-tree semantics.
- Bumped `VERSION` to 0.16.1 (canonical and template mirror).

## 0.16.0 - Bounded Single-Command Orchestrator

- Promoted the bounded single-turn automation in `handoff.ps1` to a primary `cycle` command.
  `cycle` runs at most one approved Claude Code Implementer turn, re-reads `AI_HANDOFF.md`,
  prepares the Reviewer handoff (or reports the next actor), and stops. It never runs a
  second tool turn and never automates the Reviewer or the Master.
- `run-next` remains as a fully supported alias of `cycle` - both dispatch to one shared
  `Invoke-Cycle` implementation (no duplicated orchestration logic).
- Improved post-turn reporting: for non-review post-turn states, `cycle` resolves and prints
  the next actor (tool + role) via the role binding instead of a generic message.
- Added exit code 6: the Implementer turn succeeded but the post-turn handoff is
  inconsistent (`Waiting For` mismatch or unrecognized state). Full exit-code contract:
  0 success, 1 blocked, 2 cancelled, 3 prerequisite missing, 4 NEXT_TURN.md failure,
  5 Claude Code error, 6 post-turn handoff inconsistency.
- Extracted a shared `Read-HandoffState` helper in `handoff.ps1`, used at script init and
  in the post-turn re-read, removing duplicated Status-section parsing.
- `handoff.sh`: `cycle` and `run-next` now print a shared blocked message and exit 1;
  automation requires PowerShell (`pwsh` on macOS/Linux).
- Clarified ROADMAP v0.16.0: `cycle` prepares the Reviewer prompt and stops; it does not
  execute the Reviewer turn. Exit criteria updated accordingly.
- Updated `README.md`: `cycle` documentation with `run-next` as alias, post-turn behavior,
  exit-code table, and Bash limitation note.
- Bumped `VERSION` to 0.16.0 (canonical and template mirror).

## 0.15.0 - Cross-Platform Installation and CLI Hardening

- Added `scripts/handoff.sh`: Bash equivalent of `handoff.ps1` for macOS/Linux. Supports
  `status`, `next`, `start`, and `commit-check` with full role-binding, mismatch detection,
  and Changed Files comparison. `run-next` is blocked with a message pointing to `handoff.ps1`
  or a manual paste workflow; a cross-platform equivalent is planned for v0.16.0.
- Added `scripts/next-step.sh`: Bash equivalent of `next-step.ps1`. Self-contained;
  supports `--prepare-file` (writes `NEXT_TURN.md`). `--copy-prompt` is a no-op with a note.
- Added `scripts/install.sh`: Bash equivalent of `install.ps1` for macOS/Linux. Copies root
  protocol files, skill files, and workflow scripts without overwriting; creates or updates
  `.gitignore` with all three handoff rules.
- Updated `scripts/install.ps1` to also install `scripts/handoff.sh` and `scripts/next-step.sh`
  into target projects.
- Updated `templates/gitignore-snippet.txt` to list all three handoff rules: `AI_HANDOFF.md`,
  `NEXT_TURN.md`, and `USER_REQUEST.md` (previously only `AI_HANDOFF.md`).
- Mirrored all three new scripts to `templates/scripts/` for the install flow.
- Updated `README.md` with cross-platform usage, Bash install instructions, and a note
  that `run-next` requires PowerShell (`pwsh` on macOS/Linux).
- Bumped `VERSION` to 0.15.0.

## 0.14.0 - Roadmap and Release Discipline

- Added `ROADMAP.md` at the repository root: a plain-English description of the long-term
  vision, proposed milestones (v0.14.0 through v1.0.0), and a safety model for the planned
  autonomous dialogue loop (v0.17.0). Each milestone includes goal, scope, and exit criteria.
- Added a "Release Discipline" section to `README.md`: links to `ROADMAP.md` and includes a
  release checklist that agents and maintainers can follow before bumping a version.
- Updated the "v0.3.0 Out of Scope" section in `README.md` to note that deferred items are
  now tracked as future roadmap milestones.
- Bumped `VERSION` to 0.14.0 (canonical and template mirror).

## 0.13.0 - Multi-Agent Role Assignment (role-neutral protocol)

- Introduced a role layer: the protocol is now written in terms of three roles -
  **Master**, **Implementer**, and **Reviewer** - bound to concrete tools in the new
  `.ai/roles/ROLE_ASSIGNMENT.md`. Roles can be reassigned with user approval without
  rewriting the protocol; this is the foundation for swapping which tool is Master.
- Default binding is behaviorally identical to before: Master = Codex, Reviewer = Codex,
  Implementer = Claude Code. Invariant: the Reviewer must never be the same tool as the
  Implementer.
- Added role protocol files `MASTER.md` (Master + Reviewer) and `IMPLEMENTER.md`
  (Implementer) to the canonical skill folder. `CODEX.md` and `CLAUDE.md` became thin
  entry pointers that resolve each tool's current role and send it to the right role file.
- Neutralized `SKILL.md`, `CAPABILITIES.md`, the skill `README.md`, `templates/AGENTS.md`,
  `templates/CLAUDE.md`, `templates/AI_HANDOFF.md`, the root `README.md`, and both discovery
  adapters to role tokens. `CAPABILITIES.md` keeps tool strengths tool-keyed and adds the
  default role binding.
- Renamed the dialogue states `QUESTION_FOR_CODEX` -> `QUESTION_FOR_MASTER` and
  `QUESTION_FOR_CLAUDE` -> `QUESTION_FOR_IMPLEMENTER`. The old names are still accepted by
  the workflow scripts as backward-compatible aliases.
- Made the workflow scripts role-aware: `next-step.ps1` and `handoff.ps1` resolve the
  expected actor by mapping State -> Role -> Tool via `.ai/roles/ROLE_ASSIGNMENT.md`, and
  `handoff.ps1 status` now prints the current role binding. `run-next` blocks unless the
  Implementer is bound to Claude Code (only Claude Code has a local CLI).
- Updated `install.ps1` to ship `.ai/roles/ROLE_ASSIGNMENT.md`, `MASTER.md`, and
  `IMPLEMENTER.md`, and updated the README install/verify file lists.
- Bumped `VERSION` to 0.13.0.

## 0.12.4 - Two-Way Dialogue States

- Added two-way dialogue states so Codex and Claude Code can resolve scoped questions without escalating to the user: `QUESTION_FOR_CODEX`, `QUESTION_FOR_CLAUDE`, and `RE_GATE_REQUESTED` (Claude can flag mid-implementation that a task is riskier or larger than scoped).
- Added a "Two-Way Dialogue" section to `CODEX.md`, `CLAUDE.md`, and `templates/AGENTS.md`, and added the three states to every Allowed States table.
- Added a `Dialogue / Open Questions` section to the `AI_HANDOFF.md` template.
- Wired the new states into `next-step.ps1` (ExpectedWaiting map + action branches) and `handoff.ps1` (ActionMap).
- Preserved the no-auto-loop rule: every dialogue exchange is a discrete turn, and commit stays blocked while a dialogue state is active.
- Repo-wide ASCII cleanup: converted the remaining em-dashes and layout arrows to ASCII so the repo is fully ASCII.
- Bumped `VERSION` to 0.12.4.

## 0.12.3 - Capability Profile + Consultation Reflex

- Added `CAPABILITIES.md` to the canonical shared skill folder: an agent capability profile
  describing what Codex, Claude Code, the User, and future agents are good at, and when to
  consult each one.
- Added a "When Claude Adds Value" section to `CODEX.md` and reframed consultation guidance from
  "Codex may ask Claude" to "Codex should consult Claude by default when correctness depends on
  current repo behavior, local implementation details, or verification constraints."
- Added a one-line consult-Claude nudge to the Codex-facing prompts in `handoff.ps1` (start) and
  `next-step.ps1` (NEEDS_ANALYSIS).
- Added a "Skill Location Distinction" section to `README.md` and a skill-location note to
  `templates/CLAUDE.md`; `handoff.ps1 status` now reports where the installed protocol lives.
- Wired `CAPABILITIES.md` into `install.ps1` and the README install/verify file lists.
- Bumped `VERSION` to 0.12.3.

## 0.12.2 - Install workflow scripts into target projects

- The installer now copies `scripts/handoff.ps1` and `scripts/next-step.ps1` into target
  projects (no-overwrite), so the documented workflow commands work immediately after install.
- Updated README install and verification guidance.

## 0.12.1 - Fix shared skill adapter formatting

- Fixed YAML frontmatter and replaced non-ASCII (em-dash) punctuation in the adapter and shared
  skill files so they are clean, valid Markdown using ASCII punctuation only.

## 0.12.0 - Shared skill architecture

- Introduced the canonical shared skill folder `.ai/skills/codex-claude-handoff/`
  (`SKILL.md`, `CODEX.md`, `CLAUDE.md`, `README.md`, `VERSION`) as the single source of truth.
- Added lightweight discovery adapters under `.agents/skills/` (Codex) and `.claude/skills/`
  (Claude Code) that point to the canonical folder.
- Updated the installer to ship the shared folder and both adapter stubs without overwriting
  existing files.
