# Commands

Run every command from the project folder, in PowerShell:
`.\scripts\handoff.ps1 <command>`. With no command you get a menu.

## The five you need

| Command | What it does |
|---|---|
| `work` | Show where things stand and your next step. |
| `start "<request>"` | Begin a new task from a plain request. |
| `roles -Window` | Open the roles window: who does what, and any running turn. |
| `stop` | Stop a turn that is running now. |
| `doctor` | Check that everything is healthy. |

On Windows you can also double-click `HANDOFF.cmd` in the project folder.
It opens the roles window, and the setup picker first if setup is not done.

## Everything else

Each command has one line here. `handoff.ps1 <unknown>` prints the same list.

Where you are and what is next:

- `status` - current state, role binding and commit status.
- `user-next` - the single next user action.
- `next [-Clip]` - write NEXT_TURN.md and say where to paste it.
- `wait [-TimeoutSeconds N]` - wait for a background run, then print its result.

Roles and setup:

- `setup [-Players "<tool[,tool]>"] [-Master "<tool>"] [-Window] [-Yes]` - choose the players and the Master.
- `roles [-WindowOff] [-SetRole <role> -SetTool <tool>] [-ReviewIndependence <separate-tool|fresh-context>] [-Yes]` - show or change who holds each role.
- `adapters` - which roles the tool can run itself and which are manual.
- `models [-ModelProfile P] [-Model M] [-CodexModel M] [-CodexEffort E]` - which models would run.
- `doctor -CheckUpdates` - also compare with the latest version on GitHub.

Turns the tool runs for you:

- `cycle [-BudgetUsd N] [-TimeoutSeconds N] [-ModelProfile P] [-Model M] [-AllowModelEscalation] [-Yes]` - one bounded turn, then the next handoff.
- `run-next [-BudgetUsd N] [-TimeoutSeconds N] [-Yes]` - alias of cycle.
- `loop [-MaxTurns N] [-BudgetUsd N] [-SessionBudgetUsd N] [-TimeoutSeconds N] [-ModelProfile P] [-Model M] [-AllowModelEscalation] [-IncludeMaster] [-IncludeReviewer] [-Yes]` - a bounded series of turns; never commits.

Review and Master captures:

- `review-check` - dry-run the Reviewer capture plan.
- `review-run [-TimeoutSeconds N] [-CodexModel M] [-CodexEffort E] [-AllowModelEscalation] [-Yes]` - run a read-only review and capture its verdict.
- `review-apply [-Yes]` - apply the captured verdict to AI_HANDOFF.md.
- `master-check` - dry-run the Master capture plan.
- `master-run [-TimeoutSeconds N] [-CodexModel M] [-CodexEffort E] [-AllowModelEscalation] [-Yes]` - run a read-only Master analysis and capture its route.
- `master-apply [-Yes]` - apply the captured route to AI_HANDOFF.md.

Commit and release (each needs your explicit approval):

- `commit-check [-Message "<msg>"]` - dry-run the guarded commit plan.
- `commit-approved -Message "<msg>" -Authorize "I_AUTHORIZE_COMMIT"` - create the approved local commit.
- `release-check -Version vX.Y.Z` - dry-run the guarded release plan.
- `release -Version vX.Y.Z -Message "<msg>" -Authorize "I_AUTHORIZE_RELEASE_vX.Y.Z"` - run the authorized release.

The task plan:

- `start "<request>" -Clip` - also copy the Master prompt to the clipboard.
- `task-next [-NextTask "<task>"] [-Yes]` - close the finished task and open the next one.
- `sequence-add -NextTask "<task>"` - add a pending task to AI_SEQUENCE.md.
- `sequence-check -ReleasedVersion vX.Y.Z -Commit <sha> -Tag vX.Y.Z [-NextTask "<task>"]` - dry-run the sequence advance.
- `sequence-advance -ReleasedVersion vX.Y.Z -Commit <sha> -Tag vX.Y.Z -NextTask "<task>" [-SupersededVersions "vA.B.C"]` - advance the plan after a release.

## In Bash

`bash scripts/handoff.sh <command>` has these commands:
`status`, `next`, `start`, `adapters`, `setup` and `commit-check`.
It names some of the others and says that they need PowerShell. Any other
command, work, roles and stop among them, does not exist there: of the five, only
`start` runs in Bash.
`handoff.ps1` is the authority for a commit.
