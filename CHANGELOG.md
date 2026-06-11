# Changelog

All notable changes to the codex-claude-handoff protocol are documented here.
Versions follow the `VERSION` file in `.ai/skills/codex-claude-handoff/`.

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
