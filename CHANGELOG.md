# Changelog

All notable changes to the codex-claude-handoff protocol are documented here.
Versions follow the `VERSION` file in `.ai/skills/codex-claude-handoff/`.

## 3.1.4 - UTF-8 Capture Integrity

- Fixed `master-apply` and `review-apply` on Windows PowerShell 5.1 by reading
  Codex `output-last-message` artifacts explicitly as UTF-8. Codex writes these
  files without a BOM, so the previous default read corrupted Hebrew and other
  non-ASCII task text before the anti-stale comparison.
- Kept the exact TASK anti-stale guard and all existing safety boundaries intact;
  the fix changes decoding only and does not weaken capture validation.
- Added BOM-less UTF-8 non-ASCII regression coverage for both Master and Reviewer
  apply paths and kept canonical/template scripts byte-for-byte synchronized.
- Hardened the Windows hanging-runner fixture so version detection checks only
  the leading arguments instead of expanding the complete prompt through `%*`;
  this prevents the acceptance harness itself from stalling before its marker.
- Forward-tested the candidate in a clean Node.js project: a Hebrew request ran
  through Codex Master, Claude Code Implementer, and Codex Reviewer; 11 product
  tests passed; commit gating stopped at the User. A risky Hebrew auth/database/
  deploy request routed to `PLAN_REQUIRED` without invoking Claude or changing
  source files.

## 3.1.3 - Final Acceptance Cleanup

- Stabilized the Windows timeout partial-progress fixture by giving the nested
  PowerShell -> `npx.cmd` runner enough time to create its deliberate source edit
  before the bounded turn times out.
- Preserved the production timeout behavior and safety boundary; this release only
  removes a cold-host false negative from the protocol acceptance harness.
- Kept the canonical and template harnesses byte-for-byte synchronized.
- Repaired the malformed `Commands run` item in the README Verification Gate.
- Removed obsolete `pending Reviewer-run tests` qualifiers from completed v1.4.0
  roadmap criteria now covered by the green acceptance suite.

## 3.1.2 - Start Opens a Clean New Task

- Improved `handoff.ps1 start` so it prepares `AI_HANDOFF.md` for a new task when
  the previous handoff is complete or at initial setup and the working tree has no
  non-local changes.
- `start` now sets `State: NEEDS_ANALYSIS`, `Waiting For: Master`, `Current Task`
  from the user request, and `Task Actors: TBD`, so `work` immediately points to
  Codex/Master instead of showing stale completed-task guidance.
- If non-local source changes are present, `start` leaves `AI_HANDOFF.md` unchanged
  and warns the user instead of clobbering an in-progress task.
- Added protocol coverage for clean restart and dirty-tree protection.
## 3.1.1 - First-Run Work Guidance

- Improved `handoff.ps1 work` and `handoff.ps1 user-next` for a fresh install.
- When the handoff is still at `WAITING_FOR_USER / Initial setup`, the commands now
  tell the user to start a first task with `handoff.ps1 start "..."` instead of
  sending them to inspect `AI_HANDOFF.md` manually.
- Added protocol coverage for the first-run guidance path.
## 3.1.0 - One-Command Install and Beginner Onboarding

- Added root `install.ps1` for one-command installation into a target project.
- The installer copies the tracked template protocol files, creates the target
  directory when needed, warns when the target is not a Git repository, updates
  `.gitignore` with local coordination-file exclusions, and blocks overwrites
  unless `-Force` is supplied.
- Added `QUICKSTART.md` for the shortest install-to-first-task path.
- Added `HOW_IT_WORKS.md` to explain the shared-folder model, Codex/Claude roles,
  safety gates, and the current supervised automation boundary.
- Updated README onboarding so new users start with install, `doctor`, and `work`
  instead of digging through protocol history.
- Added protocol tests for installer success, no-overwrite safety, and user-facing
  next-step output.

## 3.0.0 - Productized Supervised Workflow

- Added `handoff.ps1 doctor`, a read-only local health check that reports OK/WARN/INFO
  lines for Git detection, `AI_HANDOFF.md` status parsing, protocol version, role
  binding, working tree status after local coordination exclusions, `npx`, and Codex
  CLI availability when the existing helper can check it.
- Added `handoff.ps1 work`, a read-only daily workflow view that prints State,
  Waiting For, Current Task, and the exact next action.
- `work` points tool turns to the standard `.\scripts\handoff.ps1 next -Clip` and
  prints the guarded `commit-approved` command at `REVIEW_DONE / Waiting For: User`.
- Updated dispatch, help text, and the interactive menu to expose `work` and `doctor`.
- Added protocol tests proving `work` / `doctor` print the expected user-facing
  output and do not mutate `AI_HANDOFF.md` or create git commits.
- Documented v3.0.0 as productization for supervised human-in-the-loop real use, not
  unattended autonomy, and synced templates.

## 2.11.0 - Timeout Partial Progress Repair Guidance

- Added explicit repair guidance when a Claude Code `cycle` or `loop` times out after modifying source files but before transitioning `AI_HANDOFF.md`.
- Timeout remains fail-closed with exit code 4; the command now distinguishes "plain timeout" from "partial progress that needs Reviewer/repair".
- The guidance tells the user not to commit yet and to open Codex as Reviewer/repair to inspect the diff and approve, block, or repair the local handoff state.
- Added protocol coverage for a fake Claude timeout that writes a source file before hanging.
## 2.10.0 - Windows Claude CLI argv Quoting

- Fixed automated Claude Implementer turns on Windows PowerShell 5.1 by explicitly quoting every `npx` argument before `Start-Process` launches `npx.cmd`.
- Flattened the user prompt to a single command-line-safe line before passing it to `-p`, avoiding `cmd`/batch newline and word-splitting edge cases.
- Preserved the v2.6.0 no-op guard, v2.8.0 `--setting-sources "project,local"`, v2.9.0 `--append-system-prompt`, timeout child PID tracking, and command redaction behavior.
- Documented the live v2.9.0 failure mode where Claude received only `are`, and added protocol coverage proving the system prompt and user prompt arrive as single argv values.
## 2.9.0 - Claude CLI System Prompt Grounding

- Added `--append-system-prompt` to automated Claude Implementer turns with a redacted system prompt that reinforces non-interactive headless behavior at higher authority than the user prompt.
- Preserved v2.8.0 `--setting-sources "project,local"`, `-p` prompt delivery, safety flags, timeout handling, and the v2.6.0 no-op guard.
- Kept `--bare` deferred because it requires user-approved headless API-key/apiKeyHelper auth on this OAuth machine.
- Documented the behavior in `ADAPTERS.md` and added protocol tests for the system-prompt flag, guard phrases, and redacted command transparency.
## 2.8.0 - Claude CLI Context Isolation

- Added `--setting-sources "project,local"` to automated Claude Implementer turns to avoid user-global Claude context and memory hijacking headless `cycle` runs.
- Kept the runtime process argument as a single `project,local` value while making command-transparency output PowerShell copy/paste safe with quotes.
- Preserved OAuth-friendly behavior by not using `--bare`, and kept `-p` prompt delivery, safety flags, timeout handling, and no-op guard behavior unchanged.
- Documented the isolation behavior in `ADAPTERS.md` and added protocol tests for the runtime argument and quoted command-transparency form.
## 2.7.0 - Claude CLI Prompt Grounding

- Strengthened the automated Claude Implementer prompt with an explicit non-interactive/headless directive.
- The prompt now tells Claude not to greet, ask what to work on, ask for plugin choices, wait for input, or treat `cycle` as an interactive session start.
- Preserved existing invocation flags, `-p` prompt delivery, no-op guard behavior, and Claude Execution Evidence capture.
- Documented the behavior in `ADAPTERS.md` and added protocol tests that assert the grounding directive is present.
## 2.6.0 - Cycle No-Op Guard

- Added a fail-closed no-op/no-progress guard for automated Claude Implementer turns through `cycle`, `run-next`, and `loop`.
- Exit-0 Claude turns that do not transition the handoff and do not change non-exempt source files now stop with exit code 7 instead of looking successful.
- Source changes without a handoff transition are treated as incomplete protocol repair cases and stop with exit code 6.
- `loop` stops after the first no-op rather than repeating the same Implementer turn and burning budget.
- Documented the guard in `ADAPTERS.md` and added focused protocol coverage for cycle no-op, loop no-op, incomplete turns, and legitimate transitions.
## 2.5.0 - User Next Guidance

- Added `handoff.ps1 user-next`, a read-only user-facing command that prints the single
  next action for the current handoff state.
- At `REVIEW_DONE / Waiting For: User`, `user-next` prints the exact guarded
  `commit-approved` command with a generated commit message and the required authorization
  token, while preserving the no-push/no-tag/no-deploy safety boundary.
- For tool-owned states, `user-next` points the user to the next tool and suggests
  `handoff.ps1 next -Clip` to refresh `NEXT_TURN.md` and copy the handoff prompt.
- Tests: `protocol-tests.ps1` covers REVIEW_DONE commit guidance and implementation-state
  next-tool guidance.
## 2.4.0 - Command and Model Evidence

- Added local command transparency for automated Claude Implementer turns via
  `CLAUDE_IMPLEMENTER_COMMAND.md` and a structured `commands` array in
  `CLAUDE_IMPLEMENTER.jsonl`.
- Command evidence is sanitized by design: prompts, secrets, tokens, credentials,
  budget values, and sensitive arguments are redacted rather than logged raw.
- Strengthened model evidence with `source` and `confidence` fields and explicit
  `unknown/not exposed` behavior when the actual model is not directly visible.
- Claude Implementer prompts now ask for model source/confidence and ANSI/control-noise
  cleanup instead of accepting noisy or guessed model names.
- Tests: `protocol-tests.ps1` covers command capture creation, JSONL command/model fields,
  timeout command capture, and clean-tree exemption for the new local artifact.
## 2.3.0 - Claude Execution Policy and Continuity Capture

- Added `CLAUDE_EXECUTION_POLICY.md` to define dynamic model-policy labels (`inherit`,
  `standard`, `high_reasoning`, `cheap_readonly`, and `explicit_user_choice`) without
  hard-coding vendor model names into the protocol.
- Claude Code Implementer turns now write local, gitignored continuity artifacts:
  `CLAUDE_IMPLEMENTER_LAST.md` and `CLAUDE_IMPLEMENTER.jsonl` with prompt, stdout,
  stderr, exit code, timeout status, state, waiting-for, and current task.
- The Claude Implementer prompt now asks Claude to reconstruct recent CLI/window context
  from local captures and to include a concise execution-evidence block covering model
  relevance, observed/requested model information, subagent evidence, consulted skills,
  decisions, and risks. The protocol explicitly forbids inventing evidence.
- Installers and `.gitignore` snippets now include the Claude Implementer capture files
  and the local `IMPLEMENTER_CLI_BRIEF.md` research note.
- Tests: `protocol-tests.ps1` asserts Claude capture creation on successful turns,
  timeout capture on killed turns, and clean-tree exemption for the new local artifacts.
## 2.2.0 - Window Mode Approved Commit

- Added `handoff.ps1 commit-approved`, a guarded local commit executor for Window Mode after
  `REVIEW_DONE` / `Waiting For: User`.
- `commit-approved` requires a commit message and the exact `I_AUTHORIZE_COMMIT` token, checks
  that actual Reviewer and Implementer are present and different, verifies `Changed Files` equals
  `git status` after excluding local coordination files, then runs only `git add` and `git commit`.
- `commit-check` is now the dry-run gate for the same approved-commit plan and fails closed when
  the handoff state, actor audit, or changed-file scope is not safe.
- No push, tag, release, deploy, database, secret, or local coordination-file commit behavior is
  automated by this feature.
- Bash refuses `commit-approved` honestly and points to the PowerShell executor.
- Tests: `protocol-tests.ps1` covers dry-run safety, missing authorization, missing message,
  successful approved commit, actor-invariant blocking, and changed-file mismatch blocking.
## 2.1.1 - Windows npx Runner Resolution

- Fixed the bounded Claude Code runner on Windows after the v2.1.0 child-process hardening:
  the inner runner now resolves `npx.cmd` first, then falls back to `npx`, before launching
  the Claude Code Implementer turn.
- This preserves the v2.1.0 child PID tracking and timeout cleanup while avoiding `%1 is not
  a valid Win32 application` failures on Windows shells where plain `npx` resolves to a
  non-executable shim.
- No protocol-state, adapter, release, git, deploy, database, or secrets behavior changed.

## 2.1.0 - Opt-in Master Loop Integration

- Added `handoff.ps1 loop -IncludeMaster`, a per-session opt-in that can run the Codex
  Master's `NEEDS_ANALYSIS` turn inside the loop by chaining the existing guarded
  `master-run` capture and `master-apply` transition.
- The default loop remains conservative: without `-IncludeMaster`, it still stops at the
  Master turn and prints the operator handoff. `cycle` still never auto-runs Master turns.
- A Master turn counts against `-MaxTurns`, uses the existing read-only Codex invocation,
  edits only local `AI_HANDOFF.md` through `master-apply`, and adds no git add/commit/push,
  release, deploy, database, secret, or role-swap behavior.
- This is the first "talk to Codex, let the loop route onward" foundation slice: operators
  can combine `-IncludeMaster` and `-IncludeReviewer` for an explicitly authorized
  Master -> Implementer -> Reviewer loop session that still stops at User/release decisions.
- Tests: `protocol-tests.ps1` adds opt-in Master loop coverage proving the default-off stop,
  the opt-in transition to `READY_FOR_IMPLEMENTATION` / `Waiting For: Implementer`, the
  `MaxTurns` stop before Claude when capped, and no git commit creation.

## 2.0.2 - Reviewer New File Diff Guidance

- Updated the read-only `review-run` prompt so Codex can review new/untracked files without
  requiring the operator to run `git add -N`.
- When `git status` marks a Changed File as untracked or new and `git diff -- <file>` is empty
  or insufficient, Codex is instructed to inspect that file's current content directly as the
  diff equivalent.
- The instruction explicitly preserves read-only behavior: no `git add`, no `git add -N`, no
  index mutation, no working-tree mutation, no commit/push/tag/deploy/db/secrets behavior.
- Added a regression assertion that the `review-run` stdin prompt includes the new/untracked
  file guidance and the no-index-mutation guard.

## 2.0.1 - Master Apply Command

- Added `handoff.ps1 master-apply`: it consumes the recommendation captured by `master-run`
  (`CODEX_MASTER_LAST.md`) and applies the corresponding local `AI_HANDOFF.md` transition.
- Updated `master-run` to require a strict six-line recommendation block with a `TASK:` line,
  giving `master-apply` an anti-stale guard before it writes anything.
- `master-apply` supports `READY_FOR_IMPLEMENTATION`, `NEEDS_INVESTIGATION`, `PLAN_REQUIRED`,
  and `BLOCKED`. Non-`BLOCKED` recommendations must route to `Waiting For: Implementer` and
  name concrete Task Actors matching the current role binding; `BLOCKED` must route to
  `Waiting For: User`.
- Fail-closed guards block missing, malformed, stale, or contradictory captures, missing actors,
  `Reviewer == Implementer`, role-binding mismatches, and wrong starting state. On every blocked
  path, `AI_HANDOFF.md` is left unchanged.
- Hardened PowerShell subprocess startup against Windows process environments that expose both
  `Path` and `PATH`; `handoff.ps1` and the protocol test harness normalize the process
  environment before using child-process runners.
- Master/Codex is now `callable: yes` for `NEEDS_ANALYSIS` only via explicit
  `master-run` + `master-apply`, while `Auto-loop: no` remains unchanged. `loop` and `cycle`
  still never auto-run Master turns.
- Bash refuses `master-apply` honestly and points to PowerShell. No git add/commit/push/tag,
  release, deploy, database, secret, or role-swap automation was added.
- Tests: `protocol-tests.ps1` adds section 12 for `master-apply` success and fail-closed cases;
  adapter tests now assert Master/Codex `callable: yes` / `Auto-loop: no`.

## 2.0.0 - Safe Agent Process Runner

- Replaced the direct Claude Code Implementer `npx` invocation with a bounded PowerShell process runner used by `cycle`, `run-next`, and `loop`.
- The runner starts a real process handle, captures stdout/stderr, enforces `-TimeoutSeconds`, kills the process tree on timeout, and fails closed without treating a timeout as a successful handoff transition.
- Preserved the existing Claude Code safety flags: `--permission-mode acceptEdits`, `--disallowed-tools "Bash"`, `--max-budget-usd`, `--no-session-persistence`, and `--output-format text`.
- Added explicit `cycle -Yes` support for scripted automation/tests while keeping interactive `yes` as the default confirmation path.
- Added PowerShell protocol tests with fake fast and hanging `npx` commands proving success capture, safety flags, timeout exit, no false `AI_HANDOFF.md` transition, and hanging-process termination.
- No Master automation, no `master-apply`, no release semantic changes, no Bash Claude runner, and no commit/push/tag/deploy/db/secrets automation were added.

## 1.4.0 - Human Intervention Minimization (opt-in Reviewer loop)

- Added an opt-in Reviewer automation mode to `handoff.ps1 loop`: `loop -IncludeReviewer`.
  Without the flag, `loop` behaves exactly as in v1.3.0 - it stops at the Reviewer turn (and
  every other non-Implementer turn). With the flag, and ONLY when the bound and actual next
  actor is the Codex Reviewer at `READY_FOR_REVIEW`, `loop` runs the already-proven, guarded
  Reviewer sequence in-session instead of stopping: `review-run` (read-only Codex capture)
  then `review-apply` (consume the captured verdict, edit only `AI_HANDOFF.md`), forcing their
  non-interactive path because the operator authorized the loop session.
- Verdict routing inside the loop: `APPROVED` -> `REVIEW_DONE` / `Waiting For: User`, and the
  loop stops at that non-loop-eligible User turn (release authorization stays the User's);
  `BLOCKED` -> `READY_FOR_IMPLEMENTATION` / `Waiting For: Implementer`, and the loop continues
  under the existing `MaxTurns`/budget rules without involving the user. A Reviewer turn counts
  against `-MaxTurns` like any automated turn.
- **Adapter truth unchanged:** Reviewer/Codex stays `callable: yes` / `Auto-loop: no` in the
  `adapters` view. `-IncludeReviewer` is a per-session operator opt-in, not a change to
  `AutoLoopEligible`. `cycle` still never auto-runs a Reviewer turn, and Master/Codex remains
  `callable: no` / `Auto-loop: no` with no `master-apply` and no loop/cycle integration.
- The session-start clean-tree gate is relaxed whenever a `loop` session begins directly at the
  Codex Reviewer's `READY_FOR_REVIEW` turn (the working tree is expected to carry the changes
  under review) - in both modes. Without `-IncludeReviewer` the loop just stops cleanly at that
  non-loop-eligible Reviewer turn (exit 0), so there is no automated turn for the gate to protect;
  with `-IncludeReviewer`, `review-run`/`review-apply` still enforce Changed Files == git status.
  The clean-tree requirement is unchanged for every normal Implementer-first session and the
  per-iteration Implementer recheck.
- All fail-closed guards reused: any `review-run`/`review-apply` guard violation, or a
  malformed/stale/missing verdict, stops the loop with no handoff transition. No git
  add/commit/push/tag, no deploy/db/secrets, no bypass/danger sandbox flags; local artifacts
  stay gitignored. PowerShell-only; Bash `loop` refuses honestly and points to PowerShell.
- Tests: `protocol-tests.ps1` adds section 12 (default `loop` still stops at the Reviewer turn
  even with a runnable fake Codex present; opt-in APPROVED -> `REVIEW_DONE`/User then stop;
  opt-in BLOCKED -> `READY_FOR_IMPLEMENTATION`/Implementer then stop on MaxTurns without
  involving the user or running Claude; malformed verdict fails closed; none create a git
  commit; `cycle` still refuses a Reviewer turn) - 14 new checks (expected 93 PowerShell and
  13 Bash checks total once run). Bumped `VERSION` to 1.4.0 (canonical and template mirror);
  updated `ADAPTERS.md` and `PROTOCOL_METHOD.md` (+ mirrors).

## 1.3.1 - Codex Master Capture POC (master-check / master-run)

- Added a narrow, conservative Codex Master capture proof of concept to
  `scripts/handoff.ps1`, the Master-side equivalent of the v1.2.0 Reviewer capture POC:
  `master-check` (dry run) and `master-run` (read-only Codex execution after an explicit
  `yes`, or `-Yes`). Eligible only during `State: NEEDS_ANALYSIS` / `Waiting For: Master`
  with the bound Master tool Codex; Task Actors may be TBD (the Master turn is expected to
  recommend them).
- `master-run` is **capture-only**: it invokes Codex read-only
  (`exec --cd <repo> --sandbox read-only --ephemeral --json --output-last-message <file> -`,
  prompt on stdin), captures a structured routing recommendation, and never changes
  `AI_HANDOFF.md` or runs git. There is intentionally **no `master-apply`**. A human or the
  Master applies any gate/actor decision manually.
- The prompt is tightly bounded (inspect only `AI_HANDOFF.md`, `AI_SEQUENCE.md` if present,
  `git status --short`, and narrowly the protocol docs) and asks Codex to end with a strict
  five-line recommendation block (`MASTER_RECOMMENDATION` / `WAITING_FOR` / `IMPLEMENTER` /
  `REVIEWER` / `REASON`).
- Reuses the v1.2/v1.3 machinery: the runnable Codex CLI resolver, stdin prompt delivery,
  `-TimeoutSeconds` bound with a process-tree kill, and fail-closed exits (1 blocked guard,
  3 CLI unavailable/failed start, 4 timeout, 5 non-zero Codex exit, 6 exit-0-with-no-capture).
- New local, gitignored capture artifacts `CODEX_MASTER.jsonl` and `CODEX_MASTER_LAST.md`,
  added to the clean-tree exemption list, `.gitignore`, the template gitignore snippet, and
  both installers.
- **Adapter truth: Master/Codex remains `callable: no`** and `Auto-loop: no` - this is a
  documented POC, not an end-to-end callable Master turn, and there is no `AutoLoopEligible`
  change. `loop` and `cycle` never run Master turns.
- Bash `handoff.sh master-check` / `master-run` refuse honestly and point to PowerShell.
- Tests: `protocol-tests.ps1` adds section 11 (master-check guards: state/Waiting For,
  bound Master, Task Actors TBD allowed; master-run fail-closed on unavailable CLI, timeout,
  exit-0-no-capture; stdin delivery vs argv; clean-exit capture success; capture-only =
  no handoff change) plus a strengthened Master `callable: no` / `Auto-loop: no` assertion.
  `protocol-tests.sh` adds the master-check/master-run honest-refusal checks. 79 PowerShell
  checks and 13 Bash checks pass. Bumped `VERSION` to 1.3.1 (canonical and template mirror);
  updated `ADAPTERS.md` and `PROTOCOL_METHOD.md` (+ mirrors).

## 1.3.0 - Automated Reviewer Turn (review-apply)

- Added `handoff.ps1 review-apply`: it consumes the verdict captured by `review-run`
  (`CODEX_REVIEW_LAST.md`) and applies the corresponding LOCAL `AI_HANDOFF.md` transition
  fail-closed - `APPROVED` -> `REVIEW_DONE` / `Waiting For: User`; `BLOCKED` ->
  `READY_FOR_IMPLEMENTATION` / `Waiting For: Implementer` (recording the reason). It does
  NOT re-invoke Codex, runs no git, edits only `AI_HANDOFF.md`, and requires an explicit
  `yes` (or `-Yes` for automation). Modeled on `sequence-advance`.
- Tightened the `review-run` review prompt to require a strict four-line verdict block
  (`VERDICT:` APPROVED/BLOCKED, `REVIEWER: Codex`, `TASK:` the current task verbatim,
  `REASON:` one line) so the captured verdict is machine-parseable. `review-run` remains
  strictly capture-only.
- Strict, fail-closed verdict parsing (`Get-VerdictFromCapture`): refuses unless the capture
  has exactly one valid `VERDICT` (case-sensitive APPROVED/BLOCKED), `REVIEWER: Codex`, a
  `TASK:` matching the current Current Task (anti-stale guard), and a non-empty `REASON:`.
  `review-apply` also re-runs every `review-run` protocol guard (state, bound/actual Reviewer
  is Codex and != actual Implementer, Changed Files == git status) before any write.
- Adapter model now separates `callable` from loop/cycle eligibility via a new
  `AutoLoopEligible` flag. `loop` and `cycle` gate on `AutoLoopEligible`, never on `callable`,
  so an explicit-command-only adapter makes `loop` STOP rather than auto-run a turn.
- Reviewer/Codex is now `callable: yes` for `READY_FOR_REVIEW` (via `review-run` +
  `review-apply`) but `AutoLoopEligible: no`: it is never auto-run by `loop`/`cycle`. The
  `adapters` command prints the new `Auto-loop` line. Master/Codex remains `callable: no`.
  Loop integration of Reviewer turns is deferred to v1.4.0; a capture-only Master POC may be
  planned as v1.3.1.
- Added `-Yes` to `loop` (skip the session confirmation for automation/tests; all other loop
  safety guards still apply).
- Bash `handoff.sh review-apply` refuses honestly and points to PowerShell.
- Tests: `protocol-tests.ps1` adds section 10 (review-apply APPROVED/BLOCKED transitions;
  fail-closed on missing/malformed/multiple/unknown-token verdict, empty reason, wrong
  reviewer, stale TASK; guard reuse for wrong state, Changed Files mismatch, equal actors;
  `loop` stops at a Reviewer turn; `cycle` refuses it) plus a Reviewer-callable/Auto-loop
  adapter assertion. `protocol-tests.sh` adds the `review-apply` honest-refusal check.
  62 PowerShell checks and 11 Bash checks pass. Bumped `VERSION` to 1.3.0 (canonical and
  template mirror); updated `ADAPTERS.md` and `PROTOCOL_METHOD.md` (+ mirrors).

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
