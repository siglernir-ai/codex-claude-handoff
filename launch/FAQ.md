# Launch FAQ

## What is codex-claude-handoff?

An Agent Skill that turns Codex and Claude Code into an accountable engineering
pair on one Git task: one agent leads or implements, a different agent challenges
and reviews, rejected work can return for bounded correction, and the user approves
sensitive actions.

## What is the main value?

The user no longer has to be the messenger, traffic controller, and sole technical
judge between two AI tools. The protocol preserves context, assigns ownership,
requires independent review, and stops at real authority boundaries. In short:
one drives, one challenges, and neither ships alone.

## Is this just a handoff or two parallel answers?

No. Session handoff skills mainly preserve context for the next session, while
parallel or council tools mainly compare independent answers. This protocol keeps
one live engineering task in durable local state and supports an
implementation-review-correction cycle. Its general question states are
two-directional but still require explicit turns today.

## Why use two agents?

The goal is separation of duties, not a claim that two models are always better.
The Implementer does not approve its own work, and shared files preserve the task,
scope, evidence, and next actor across tool boundaries.

## Can Codex and Claude Code swap roles?

Yes, with explicit user approval. Codex can implement while Claude Code leads or
reviews when the installed adapters support that binding. The invariant does not
change: Reviewer and Implementer must remain different, and unsupported automation
falls back to an explicit turn instead of being guessed.

## Is it fully autonomous?

No. It is intentionally human-in-the-loop. It stops before commit, push, tag,
release, deploy, database work, secrets, role changes, and product decisions unless
the user explicitly authorizes the relevant action.

The review/correction path can run as a bounded opt-in loop, but this is not an
unrestricted autonomous conversation. Turn count, time, budget, state, and scope
guards determine when it must stop.

## Is it a VS Code extension?

No. VS Code is the recommended shared workspace because both agents can point to
the same project folder. Coordination happens through local files, not a hidden chat
bridge or a native extension.

## Does it send my repository to another service?

The Skill itself adds no telemetry service or hosted backend. Codex and Claude Code
still operate under their own products, accounts, policies, and data handling. Read
those terms before using either tool with sensitive source code.

## Does setup download and run extra code?

The skills CLI fetches the public Skill from GitHub. First-use project setup runs a
payload bundled inside that Skill and does not download additional code. Users
should still inspect the Skill and installed files before use.

## What can the agents execute?

The protocol includes bounded adapters, state checks, timeouts, budget limits,
exact-scope review, no-op detection, and explicit approval gates. It is not a
sandbox for the entire machine, and agent tools still deserve normal code-review
and least-privilege discipline.

## What does it cost?

The Skill is open source under Apache-2.0. Codex and Claude Code usage may consume
the user's existing plan allowance or paid API/CLI budget. The demo uses an explicit
Claude budget cap of USD 2; real task cost depends on the task and account.

## Which models does it force?

It does not hard-code a permanent model name. The execution policy asks the
Implementer to use the current environment and report available model evidence when
relevant, so future model changes do not require redesigning the protocol.

## Does it work on Windows only?

The package includes PowerShell-first Windows support and Bash scripts for macOS or
Linux. The most extensively exercised path is Windows with VS Code, Codex, and
Claude Code in the same repository.

## Is it production-ready?

v3.3.1 is a public beta ready for supervised use on small, non-critical tasks. It
has extensive protocol tests and clean-install evidence, but it does not claim full
unattended production autonomy.

## What if the skills.sh page differs from GitHub?

Direct installation reads the public GitHub source, while skills.sh may temporarily
serve an older indexed copy. Compare the public `SKILL.md`, release tag, and direct
CLI discovery. Report a persistent mismatch upstream and use the GitHub release as
the source of truth until re-indexing completes.

## How do I install it?

From a clean Git project:

```powershell
npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy
```

Then select `codex-claude-handoff` through `/skills` in Codex and ask it to set up
the project. Setup explains the local changes and asks for approval.

## Where should bugs be reported?

Use the GitHub repository issues and include the operating system, installed
version, handoff state, safe command output, and whether the working tree was clean.
Never post secrets or private source code in an issue.
