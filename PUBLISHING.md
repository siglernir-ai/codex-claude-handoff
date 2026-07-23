# Internal Publishing Guide

This document is for project owners who want to share `codex-claude-handoff`
with colleagues inside an organization.

## Positioning

Describe the skill as:

> Codex-Claude Handoff turns two coding agents into an accountable engineering
> pair: one drives, another challenges and reviews, and neither ships alone. It
> keeps one live Git task in durable project-local state and can return rejected
> work for bounded correction before the user approves sensitive actions.

Do not describe it as full unattended autonomy. The workflow intentionally stops at
review, commit, push, tag, release, deploy, database, secret, and production
decisions until a human explicitly authorizes the relevant step.

Do not claim the project invented multi-agent dialogue. Similar review loops,
multi-model councils, and file-based collaboration protocols exist. Position this
Skill by its concrete combination of project-local state, configurable roles,
exact-scope Git checks, independent review, bounded correction, and fail-closed
human approval gates.

## Who Should Try It

Good first users:

- Already use Codex Desktop and Claude Code.
- Prefer working in VS Code with both tools pointed at the same project folder.
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
3. Refresh the standalone Skill payload with `scripts/build-skill-package.ps1`.
4. Build the release package with `scripts/build-package.ps1`.
5. Test both bootstrap and skills CLI installation in fresh throwaway Git repositories.
6. Run `scripts/handoff.ps1 doctor` in each installed project.
7. Complete one small file-creation pilot.
8. Complete one existing-file edit pilot.
9. Share `QUICKSTART.md`, `HOW_IT_WORKS.md`, `SECURITY.md`, and this file.

## Suggested Colleague Message

```text
I am piloting codex-claude-handoff, an Agent Skill that turns Codex and Claude
Code into an accountable engineering pair in the same repo: one drives or
implements, a different agent challenges and reviews, and neither ships alone.
The recommended workspace is VS Code with both tools pointed at the same project
folder. Durable local state preserves the task, exact scope, evidence, and next
actor; rejected work can return for bounded correction before the user approves
commits or releases.

This is not a native VS Code extension or unrestricted background automation; it is a
project-local protocol with bounded automation and explicit human checkpoints.

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

v3.3.1 includes a self-contained public beta Skill in both common agent discovery
locations. The Skill bundles the installer and protocol templates it needs, so
`skills add` no longer produces an adapter with missing project-local references.

Recommended checks:

```powershell
npx skills add siglernir-ai/codex-claude-handoff --list --full-depth
npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --copy
```

There is no separate package upload in this workflow. Publish the repository and
release tag, then install the Skill from the public GitHub source with the `skills`
CLI. skills.sh uses anonymous CLI install telemetry for discovery and ranking, so a
new Skill may take time to appear in search and begins with no meaningful ranking.

Before public listing, perform the install in a fresh Git repository, invoke the
bundled setup, run `doctor`, confirm no network download occurred during setup, and
complete a small supervised workflow. Describe the release as a public beta rather
than full unattended autonomy.

Suggested 30-day beta threshold:

- Five external installs.
- Two users completing a full supervised workflow.
- No unresolved critical security or data-loss issue.
- Maintenance mode instead of indefinite development if there is no demonstrated use.

The public launch copy, demo script, FAQ, visual source, and go/no-go checklist are
maintained in [`launch/`](launch/README.md). Keep launch claims aligned with the
current acceptance evidence and known limitations.

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
