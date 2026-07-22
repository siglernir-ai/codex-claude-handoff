---
name: codex-claude-handoff
description: Install, diagnose, or run the supervised project-local Codex to Claude Code to Codex handoff protocol. Use only when the user explicitly selects or names codex-claude-handoff, requests setup, or asks for the full handoff workflow; do not trigger for ordinary project tasks. On first use, request approval before installing the bundled protocol.
license: Apache-2.0
metadata:
  status: public-beta
  version: "3.3.0"
---

# Codex-Claude Handoff

Run this skill only after explicit user activation. It coordinates a supervised
Codex -> Claude Code -> Codex review workflow and keeps the user as the approval
point for sensitive actions.

## First use

Check for `.ai/skills/codex-claude-handoff/SKILL.md` in the project root.

If it is missing:

1. Explain that setup copies project-local protocol files and updates `.gitignore`.
2. Obtain explicit user approval before running setup.
3. On Windows, run the bundled `scripts/setup.ps1`. Prefer the copy under
   `.agents/skills/codex-claude-handoff/`; fall back to `.claude/skills/`.
4. On macOS/Linux, run the bundled `scripts/setup.sh` from the same locations.
5. Do not download or execute any additional remote code. The setup payload is
   bundled inside this skill.
6. Report the doctor result and tell the user which stable files should be
   reviewed and committed. Do not commit them automatically.

## Installed workflow

When the canonical protocol exists:

1. Read `.ai/roles/ROLE_ASSIGNMENT.md` and confirm the current role.
2. Read `.ai/skills/codex-claude-handoff/SKILL.md` for the shared protocol index.
3. Read `.ai/skills/codex-claude-handoff/CODEX.md` when acting as Codex, or
   `.ai/skills/codex-claude-handoff/CLAUDE.md` when acting as Claude Code.
4. Read `AI_HANDOFF.md` and continue according to its current state.

## Safety

- This is a public beta intended for supervised, human-in-the-loop use.
- Never commit, push, tag, release, deploy, change a database, or change secrets
  without the protocol's exact user authorization.
- Keep local coordination and evidence files out of Git.
- If setup, role binding, scope, or state is inconsistent, stop and report the
  blocker instead of guessing.
