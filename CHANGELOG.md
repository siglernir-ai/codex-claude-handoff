# Changelog

All notable changes to the codex-claude-handoff protocol are documented here.
Versions follow the `VERSION` file in `.ai/skills/codex-claude-handoff/`.

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
