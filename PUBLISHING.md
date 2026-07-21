# Internal Publishing Guide

This document is for project owners who want to share `codex-claude-handoff`
with colleagues inside an organization.

## Positioning

Describe the skill as:

> A supervised handoff workflow for using Codex and Claude Code in the same Git
> project. It routes work through Master, Implementer, Reviewer, and User approval
> states using local coordination files.

Do not describe it as full unattended autonomy. The workflow intentionally stops at
review, commit, push, tag, release, deploy, database, secret, and production
decisions until a human explicitly authorizes the relevant step.

## Who Should Try It

Good first users:

- Already use Codex Desktop and Claude Code.
- Work in Git repositories with clean commits.
- Are comfortable approving local commits after review.
- Want a repeatable way to split task routing, implementation, and review.

Poor first users:

- Need background automation with no manual checkpoints.
- Do not use Git.
- Cannot sign in to Claude Code on the machine.
- Expect the tool to deploy or change production systems without approval.

## Internal Rollout Checklist

Before sharing with colleagues:

1. Push the latest release commit and tag to the shared Git remote.
2. Run `scripts/protocol-tests.ps1` and keep the output summary.
3. Build the release package with `scripts/build-package.ps1`.
4. Test installation in a fresh throwaway Git repository.
5. Run `scripts/handoff.ps1 doctor` in the installed project.
6. Complete one small file-creation pilot.
7. Complete one existing-file edit pilot.
8. Share `QUICKSTART.md`, `HOW_IT_WORKS.md`, `SECURITY.md`, and this file.

## Suggested Colleague Message

```text
I am piloting codex-claude-handoff, a supervised workflow for coordinating Codex
and Claude Code in the same repo. It uses local handoff files so Codex can route,
Claude can implement, Codex can review, and the user approves commits/releases.

It is opt-in by default: select the codex-claude-handoff skill only for tasks that
should use the full workflow. Normal Codex tasks remain normal.

Start with QUICKSTART.md, then run doctor. Use a small non-production task first.
The tool stops before commit, push, release, deploy, database, and secret changes
until you explicitly approve them.
```

## Support Boundary

For an internal pilot, support one project and one task at a time. Ask users to
send:

- Operating system and shell.
- Codex Desktop version, if relevant.
- Claude Code sign-in status.
- `scripts/handoff.ps1 doctor` output.
- `scripts/handoff.ps1 work` output.
- `git status --short --branch`.

Do not ask users to share secrets, tokens, private prompts, or proprietary source
files unless your organization has already approved that support path.

## skills.sh Readiness

The repository includes skill metadata in common discovery locations. The
`skills` CLI can discover the skill, but it installs the discovery adapter, not the
complete project-local protocol tree. The official full installation path remains
the pinned bootstrap command in `QUICKSTART.md`.

Recommended checks:

```powershell
npx skills add siglernir-ai/codex-claude-handoff --list
npx skills add siglernir-ai/codex-claude-handoff --copy
```

Treat skills.sh as discovery and activation help, not as the complete installer,
unless a future packaging pass proves a full-protocol `skills add` installation.
Before broad public listing, add and verify an adapter fallback that tells users to
run the bootstrap installer when `.ai/skills/codex-claude-handoff/` is missing.

## Go / No-Go

Go for internal pilot when:

- The latest release tag is pushed.
- The test suite passes.
- Fresh install works.
- A small pilot reaches review and guarded commit guidance.
- Users understand it is supervised, not unattended.

No-go when:

- The repository is ahead of the published remote.
- The skill cannot be discovered or installed from the shared source.
- Claude Code is not authenticated.
- The working tree is dirty before the first task.
- The user expects production actions without explicit approval.
