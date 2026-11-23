## 3.19.0 - Five Commands, One Click

- **The information was there; nobody could find the five commands that matter.** The
  no-command menu listed 17 actions, and the usage text 28 commands, several of them as
  paragraphs. A new user could not tell what to type, and opening the roles window meant
  typing a command.
- **One table in `handoff.ps1` is the command card.** Five entries, in order: `work`,
  `start "<request>"`, `roles -Window`, `stop`, `doctor`, each with a one-line summary of what
  it does for the user. The menu and the usage text print it; nothing else defines it.
- **The menu shows the five, then `6. More...` and `7. Exit`.** `More` lists the other
  fourteen actions of the old menu, under their old labels, then `Back to the five` and
  `Exit`. Every action the menu had is still reachable and runs the same function as before.
  `stop` is new to the menu. Item 3 sets `-Window` and runs `Invoke-Roles`, the code path of
  `roles -Window`. A menu choice is now routed through one switch, `Invoke-MenuAction`.
- **The usage text prints the card first, then every other command on one line.** The
  paragraph-long lines were cut to one line each. No command and no flag of a signature was
  dropped; the flags of the card's own commands (`doctor -CheckUpdates`, `start ... -Clip`,
  the other forms of `roles`) have lines of their own.
- **`COMMANDS.md`** is a new root document the installers copy into the project. It holds the
  card as a two-column table, then every command on one line in six groups, then the Bash
  commands. `handoff.sh` usage gained one line that points to it. The suite holds it to the
  code: the five rows must match the table in order and wording, every command it names
  must be a dispatch entry of `handoff.ps1`, every dispatch entry must appear both in it and
  in the usage text, and every Bash command it names must be a working (not refusing) entry
  of `handoff.sh`. A future command cannot be added without documenting it.
- **`HANDOFF.cmd` opens the right window with a double-click.** It runs
  `handoff.ps1 roles -Window` from its own folder. On exit 14 (setup required) it runs
  `setup -Window`, and after a save runs `roles -Window` again; exit 2 from setup (the user
  cancelled) ends quietly. Any other failure stays on screen behind a `pause`; success closes
  without one. It owns no rules: it compares exit codes 0, 2 and 14 and nothing else. ASCII,
  CRLF (`.gitattributes` now has `*.cmd text eol=crlf`), no absolute path. It enters its
  folder once with `pushd "%~dp0"` and names `scripts\handoff.ps1` relative to it: started
  through a quoted relative path from another folder, cmd resolves `%~dp0` again after a
  change of folder, so a second use would point at a folder that does not exist. `pushd`
  also maps a network path to a drive letter, and if it fails the launcher stops on screen
  instead of running from the wrong folder.
- **The launcher never dirties Git.** `/HANDOFF.cmd` is in the gitignore snippet, so a fresh
  install ignores it and an upgrade appends the line to an existing `.gitignore`. It is also
  on the coordination exclusion list (`$LocalHandoffFiles`), so a project whose `.gitignore`
  lost the line does not have `cycle` refuse, and the file never enters a commit plan; being
  on that list also puts it in the read-only boundary, so a Master or Reviewer turn cannot
  rewrite what a double-click runs.
- **The installers place it on Windows.** `install.ps1` creates it on a fresh install and on
  an upgrade; `-NoLauncher` skips it (also through `bootstrap.ps1` and `scripts/install.ps1`).
  The closing text names it in one line. `install.sh` skips it by name, because it copies the
  whole template tree.
- **`install.ps1 -VsCodeTask` is opt-in.** It writes `.vscode/tasks.json` with one task,
  `HANDOFF: open window`, that runs the launcher when the folder opens, with a quiet
  presentation, only when the file does not exist. An existing file is left byte for byte,
  and the task is printed to add by hand. The launcher is gitignored and Windows-only, but
  the task file may be committed, so the task runs it only on Windows (`cmd.exe /d /c if
  exist HANDOFF.cmd (call .\HANDOFF.cmd) else (exit /b 0)`) and is the `true` no-op on
  macOS and Linux: a fresh clone or a teammate without the launcher opens the folder
  without an error. The explicit `.\` keeps it working when `NoDefaultCurrentDirectoryInExePath`
  is set. The installer says so, and that VS Code asks once to allow automatic tasks. Combined with `-NoLauncher` it
  is refused before anything is installed. Without the flag nothing under `.vscode` is
  touched.
- **Fixed: the setup picker's subtitle was cut off** at 125% scaling. It now reads
  `Nothing runs until you save. Change it later with setup.`
- **Kept: the standard style for a disabled Master choice.** Its disabled text is embossed
  grey, which looked smeared on the dark background. `FlatStyle = 'Flat'` was tried and
  rejected in review: on this background it draws disabled text near-black, unreadable.
  The embossed grey stays until a readable alternative is drawn and seen on a screen.
- **`COMMANDS.md` and the Bash usage tell the truth about Bash.** Of the five, only `start`
  runs in `handoff.sh`; `work`, `roles` and `stop` do not exist there (once setup is done
  they answer `Unknown command`), they are not refusals that point to PowerShell.
- **Docs.** `README.md`, `QUICKSTART.md` and `START_HERE.md` name the card and the launcher
  where a new user looks; the suggested install commit adds `COMMANDS.md`.
- **What the tests prove.** The card, the dispatch, `COMMANDS.md` and the usage text agree,
  parsed from the files, not from a second list. The menu shows the five first and `More`
  reaches status, adapters and setup; item 3 prints what `roles -Window` prints and writes
  the same setting. A fresh install places the launcher (CRLF, ASCII, no absolute path) and
  `git status` does not list it; an upgrade of a project in the previous layout adds the
  launcher and `COMMANDS.md`, appends the ignore line, and changes no other file;
  `-NoLauncher` skips it; `install.sh` does not install it. Run through `cmd /c` with input
  from NUL and windows off, the launcher exits 0 in a configured project and, in a pending
  project, takes the exit-14 branch and ends. Against a stand-in `handoff.ps1`, every branch
  (0; 14 then 0 then 0; 14 then 2; 14 then a failure; a failure after setup; any other code)
  calls what it should and pauses only on a failure. Started from its parent folder through
  a quoted relative path, it still finds `handoff.ps1` (the launcher this release first had
  failed that). An un-ignored launcher leaves `doctor` clean, `cycle` running and the commit
  plan without it. `-VsCodeTask` writes valid JSON with the Windows-only, guarded task when
  the file is absent and leaves an existing one byte-identical. The changed picker script
  parses.
- **Seen on a screen, before the review fixes:** in a fresh install, a double-click on
  `HANDOFF.cmd` opened the setup picker, a save opened the roles window, and closing it
  closed the console. The subtitle was seen whole. The launcher as it ships (with `pushd`)
  was then run through `cmd.exe` by the tests, not double-clicked again; the picker's
  standard style is the one seen on a screen in v3.18.0.
- **Not verified:** cancelling setup from a double-click, and the VS Code task inside VS
  Code (its presentation and the one-time prompt). The guard command was run through
  `cmd.exe` with and without a launcher present, not from VS Code.

## 3.18.0 - The First Choice Is Yours

- **A fresh install ran on a binding nobody chose.** Installing gave every project Master =
  Codex, Reviewer = Codex, Implementer = Claude Code, silently. Which tools work on a
  project, and which one leads, is the user's decision. It is now asked for, never assumed.
- **One line in `.ai/roles/ROLE_ASSIGNMENT.md` records it.** The shipped file says
  `Setup: pending`. `handoff.ps1 setup` writes `Setup: complete` with the chosen binding.
  No line means configured: every install made before v3.18.0, and every upgrade of one,
  behaves exactly as before. Any other value, or a second line, fails closed through the
  role checkpoint (exit 12), and only `setup` repairs it, when it is the only problem.
- **Until setup is done, work commands stop with exit code 14** and one instruction,
  `.\scripts\handoff.ps1 setup`. That includes the no-command menu and every form of
  `roles`. `doctor` warns (it does not fail), `status` says NOT CONFIGURED instead of
  showing the template's binding, and `models` runs. Nothing was started and nothing was
  changed, and the message says so.
- **`handoff.ps1 setup [-Players "<tools>"] [-Master "<tool>"] [-Window] [-Yes]`.** One rule,
  for every way in. Two players: the Master's tool implements and the other tool reviews,
  so the Master and the Reviewer are different tools. One player: that tool holds every role
  under `Review Independence: fresh-context`, and the plan says plainly that a single-vendor
  review is weaker than two vendors. Unknown tools, a Master who is not a player, an empty
  list and two players without a Master are refused by name. setup writes the three rows,
  the review line, `Setup: complete` and a Role Swap History row in one swap of the file,
  and moves the install's Task Actors so `work` runs clean straight after. If the second
  write fails (for example `AI_HANDOFF.md` is open in another program), the role file is
  restored byte for byte, no temp file is left, and setup can simply be run again. In Bash
  an interrupt between the two writes is handled the same way; setup's work files live in
  `.ai/handoff-history/`, which Git ignores; and if even the restore fails, setup says it
  failed part-way, keeps the saved original there and prints the one command that puts it
  back. A folder setup cannot write is named as such. `HANDOFF_TEST_SETUP_FAIL` exists for
  the test suite only: it can make Bash setup fail at a chosen step, never pass. It is refused
  while a turn runs. A pending project is set up only from the untouched install state:
  setup does not adopt a record written before the players were chosen, such as a
  hand-written `REVIEW_DONE`, and says how to keep it and start clean (move `AI_HANDOFF.md`
  into `.ai/handoff-history/`, re-run the installer with `-Force`, run setup). A configured
  project reconfigures only at a finished task (`REVIEW_DONE` or `BLOCKED`, Waiting For:
  User), whose Task Actors are never rewritten; setup then names `start` as the next step,
  because `work` stops on role drift until `start` retires that record.
- **A picker window on Windows, flags everywhere else.** Without `-Players`, setup opens a
  small dialog in the style of the roles indicator: tick the players, choose the Master. The
  tools found on the machine are ticked first, using the checks `doctor` already makes; no
  Master is ever preselected, and Save stays disabled until the choice is valid. The window
  owns no rules: every result it can show is computed by setup beforehand, and Save returns
  the choice to the same code path as `-Players ... -Master ... -Yes`. Where no window can
  open (no console, an agent's shell, `HANDOFF_BACKGROUND_NO_WINDOW`), a person at a console
  gets a short numbered prompt, and anything else gets the flag form and exit 1. A picker
  that fails is reported as a failure (exit 3), never as a cancel (exit 2), and never falls
  back to a console prompt. The roles indicator has a `setup` button, which runs
  `setup -Window`.
- **The installers ask, or take the answer up front.** `install.ps1` (and `bootstrap.ps1`,
  and `scripts/install.ps1`) accept `-Players`, `-Master` and `-NoSetupWindow`; `install.sh`
  accepts `--players` and `--master`. A fresh install opens the picker at the end when a
  person can use it, and otherwise prints NOT CONFIGURED and the command. A bad flag fails
  the install and says why. Whether a project is new is decided before anything is copied,
  from the role file, because the Skill's own setup passes `-Force` on a first install. An
  upgrade carries the project's own Setup line, or none, and refuses an invalid one.
- **`bash scripts/handoff.sh setup --players <list> --master <tool> [--yes]`.** The same
  rules and the same file, from Bash, so a Linux machine without PowerShell can leave the
  pending state. Bash sets up the untouched install state only: reconfiguring a project
  after its first task needs `pwsh scripts/handoff.ps1 setup`, because the `start` recovery
  that retires the finished record exists only there. `handoff.sh` and both `next-step`
  helpers apply the same gate; in Bash only `status` and `setup` are exempt, as in
  PowerShell, so `adapters` no longer shows the template binding as if it had been chosen.
- **The stop never hands an agent a ready-made choice.** The exit-14 and exit-12 blocks,
  the refusals and the installers' notices show placeholders (`-Players "<Claude Code, Codex,
  or both>" -Master "<one of the players>"`) and say that an agent must ask the user. Where
  usage text and the docs show a concrete command, it is labelled an example and sits next
  to that sentence.
- **Agents ask; they never choose.** `SKILL.md` tells an agent that installs the protocol to
  ask the user for the players and the Master, then run setup with flags, and never to edit
  the Setup line by hand. The Skill's setup scripts say when setup is pending.
- **Fixed: `roles -SetRole` on a fresh install blocked every later command.** The swap left
  the install's template Task Actors behind, and the next command stopped on role drift.
  In the untouched install state the Task Actors now follow the binding. `-SetTool` must now
  name a known tool: a placeholder such as `TBD`, `User` or an unknown name is refused.
- **Fixed: a typographic quote could break a generated window script.** PowerShell also ends
  a single-quoted string at U+2018..U+201B, so a project folder named with one broke the
  indicator and the picker, and a crafted name could add a command. Values are now escaped
  with the parser's own escaper.
- **Fixed (security scan): `handoff.sh` accepted an unknown tool.** Under `fresh-context`, a
  name the registry does not know, used for both Reviewer and Implementer, passed the Bash
  role checkpoint, and `handoff.sh commit-check` printed ALLOWED. Bash now rejects an
  unknown bound tool or Task Actor, as `handoff.ps1` does, and compares canonical identities,
  so an alias such as `Codex Window` is not drift. It reads Task Actors in every form
  `handoff.ps1` reads (`*` or `-`, any spacing, any letter case) and role rows in any letter
  case; before, `* Implementer: Codex` was invisible to Bash and a self-review read ALLOWED.
  Bash's section and Status readers were ported line by line from `Get-SectionLines` and
  `Read-HandoffState`, and Bash `commit-check` now makes the commit audit of
  `Get-CommitPlan` on the lines `Get-TaskActors` reads (exactly one distinct Implementer and
  Reviewer, and not one tool under `separate-tool`) besides the checkpoint's own reading. A
  blocked Bash `commit-check` exits non-zero, as PowerShell does. For a file containing a
  character from a fixed refuse set (Unicode spaces, control characters, a lone CR, U+200B,
  a U+FEFF that is not the BOM, and four letters .NET folds to ASCII: U+212A, U+017F,
  U+0130, U+0131), Bash `commit-check` and `setup` refuse before reading anything else,
  name the line and the character, and point to `handoff.ps1`. The refusal covers the whole
  file: one no-break space in a free-text note is enough, and removing it is the way on
  where PowerShell is not installed. What is tested: a differential table of 42 handoff
  files, run through both shells, in which Bash never says ALLOWED or exits 0 where
  PowerShell refuses and the legitimate ones (CRLF, a BOM, no final newline, Hebrew text)
  pass in both; its rows cover heading spellings, repeated and fenced headings, empty,
  missing and renamed sections, duplicate Reviewers, `*` and mixed bullets, duplicated
  Status, lower-case keys, and the Unicode and lone-CR cases; and every character of the
  refuse set is refused in three positions. The Bash scripts set `LC_ALL=C` themselves, so
  the caller's locale does not reach their readers. This is a tested set, not a proof:
  `handoff.ps1` remains the authority for a commit, and the known gaps below name a class
  the refuse set does not cover. Other Bash commands (`status`, `next`, `start`, `adapters`) and `next-step.sh` only
  route, and are not guarded. A second copy of `_canonical_tool` was removed.
- **Fixed: the Skill's `setup.sh` always failed** at its last step with "Unknown command:
  doctor": `handoff.sh` has no doctor. It runs `status` now, and `install.sh` names `status`
  instead of `doctor` in its closing lines. Both setup scripts suggest an install commit
  without a stale version number.
- **Fixed: a `-Force` upgrade glued the binding table to the next line.** `install.ps1`'s
  row pattern ran on through the line break, so the blank line under the table disappeared
  and `Review Independence:` rendered as a table row. Two upgrades in a row now give the
  same file.
- **Docs.** The entry pointers and the README no longer claim a default binding. To fit the
  Master's context budget, the role file lost one redundant sentence ("This note is not the
  authority: run `handoff.ps1 adapters` ..."); the line above it says the same.
- **Not verified:** against a live Codex or a live Claude Code turn. The picker window was
  generated and parsed, never opened or clicked, by the author or by the tests. Bash was
  run only under Git Bash on Windows. The console prompt (setup without flags at a person's
  console) was not exercised by a test.
- **Known gaps, tracked for a later release.** The gate guarantees that an install never
  runs on a binding nobody chose; it does not defend against someone who edits or deletes
  the role file by hand. A broken Setup line (two `Setup: pending` lines, say) sends
  PowerShell `setup` down the configured path, so at a hand-written `REVIEW_DONE` it
  reconfigures where Bash refuses; and a deleted role file returns both shells to the
  built-in default binding, past the gate, with only `doctor` reporting FAIL. `commit-check`
  still accepts placeholder Task Actors (`TBD`) at `REVIEW_DONE` when the binding has two
  tools. Bash `commit-check` reads Changed Files with an exact heading match and, when that
  list does not match `git status`, still says ALLOWED with only a WARNING where
  PowerShell refuses; use `handoff.ps1 commit-check` for the guarded result. `next-step.sh`
  routing can differ from `handoff.ps1` on a file with a character from the refuse set.
  `handoff.ps1` compares headings with `-eq`, which is culture-sensitive: it ignores
  invisible characters (a soft hyphen U+00AD, joiners, direction marks, variation
  selectors) and equates some ligatures with plain letters. None of those is in the refuse
  set, so on a hand-crafted file with such a character inside a `## Status` or
  `## Task Actors` heading, Bash `commit-check` still says ALLOWED where PowerShell
  refuses. This is as old as v3.17.0; `handoff.ps1 commit-check` gives the guarded result.
  In Bash `setup`, a signal that lands after `AI_HANDOFF.md` is written and before setup
  finishes restores the role file and says nothing was changed, although `AI_HANDOFF.md`
  is already the new one; running setup again completes it.

## 3.17.0 - A Fresh Context, Not a Second Vendor

- **Someone with only one tool could not get a review at all.** The protocol required the
  Reviewer to be a different vendor from the Implementer, so a user with only Claude Code,
  or only Codex, was stopped at the first role checkpoint. The real requirement was never
  two vendors. It is that the Reviewer never shares a context with the Implementer.
- **One line in `.ai/roles/ROLE_ASSIGNMENT.md` now says how that is enforced.**
  `Review Independence: separate-tool` is today's rule and the default; an absent line
  means the same. `Review Independence: fresh-context` lets one tool hold both roles. Any
  other value, or a second line, blocks every role-dependent command. The shipped file
  declares `separate-tool`, and both installers carry the project's own line across an
  upgrade, so installing or upgrading changes nothing.
- **`handoff.ps1 roles -ReviewIndependence <separate-tool|fresh-context>`** changes it under
  the same guards as a role swap: refused while a turn runs, refused for a Reviewer the
  harness cannot run, and `separate-tool` refused while one tool still holds both roles. It
  writes a Role Swap History row. A role file with no history table now gets one, for this
  command and for `roles -SetRole`; before, a swap on a fresh install said "Recorded in the
  Role Swap History table" and recorded nothing.
- **With one tool in both roles, only the harness verdict counts.** `review-run` already
  starts the Reviewer as its own read-only process. Under `fresh-context` it also appends
  one record to `REVIEW.jsonl` with the task, the SHA-256 of the capture and the SHA-256 of
  every file the Reviewer was told to verify. `review-apply`, `commit-check`,
  `commit-approved` and `release-check` require that record, an APPROVED capture for the
  current task that has not changed since, the `review-apply` record, and the same bytes on
  disk. A `REVIEW_DONE` written in a chat window is refused. With two different tools,
  `fresh-context` behaves exactly like `separate-tool`.
- **What that check proves, and what it does not.** It proves the verdict is the one
  `review-run` captured for this task, unedited, applied by `review-apply`, over the exact
  files being committed. It is not a cryptographic proof: the files are local, and anything
  with write access to the project could forge them. And one vendor reviewing its own
  vendor's work is a weaker check than a second vendor. Two tools remain the recommended
  setup, and the docs now say so.
- **The self-review guard reads the role, not only the tool.** When one tool holds both
  Implementer and Reviewer, the tool name in `- Actor:` cannot tell an Implementer turn from
  a Master that did the work itself. A review may then proceed only when Last Update is an
  Implementer record: an Actor line naming the Implementer role (with or without a tool
  name), and not a leftover review record. This guard reads a label the agent writes itself.
  It stops a Master that records its own work honestly; it cannot catch a false label.
- **Commit and release cannot be reached around the harness check.** The single-vendor
  check applies when either the Task Actors or the binding put one tool in both roles, and
  both actors must be named tools, so a placeholder such as `TBD` no longer skips it.
  `review-apply` records the SHA-256 of the capture it applied, and commit and release
  compare it, so a leftover plan review cannot stand in for an unapplied code verdict.
  `status`, `user-next` and `work` no longer offer a commit that `commit-check` would refuse.
  `cycle` and `loop` stop if an Implementer turn edits `.ai/roles/ROLE_ASSIGNMENT.md`, and
  `loop` re-reads the review rule every turn.
- **The line is read the same way everywhere.** Key and value are read without regard to
  letter case by `handoff.ps1`, `handoff.sh`, both `next-step` scripts, both installers and
  the roles window. An invalid or duplicated line can be repaired with
  `roles -ReviewIndependence <value>` when it is the only problem, and the roles window shows
  it as invalid.
- **Said out loud.** `roles`, `doctor`, `work`, `status`, the review plan, `commit-check` and
  the Reviewer's `NEXT_TURN.md` each print one line naming a single-vendor review. `roles`
  and `doctor` also print an advisory, never a block, when Master and Reviewer are the same
  tool while two tools are bound - the long-standing default: a Reviewer from a different
  tool than the Master questions the plan as well as the code. `handoff.sh` and `next-step`
  mirror the rule and the `NEXT_TURN.md` section; a single-vendor commit is verified by
  `handoff.ps1 commit-check` only. The roles window shows the active rule.
- **Not verified against a live Codex or Claude Code.** The tests run the harness path
  against a stand-in for the Codex CLI. No real review was run for this release.

## 3.16.0 - An Effort Level Outlives a Model

- **A model name in a Codex mapping goes stale.** Claude Code has floating aliases, so a
  profile mapped to one keeps working when the model behind it is replaced. Codex has none:
  a concrete name in `MODEL_ROUTING.json` or `HANDOFF_CODEX_MODEL_<PROFILE>` breaks the day
  the vendor retires that model, and the mapping has to be found and fixed by hand.
- **A profile now also maps to a Codex reasoning effort.** `codexEffort` in
  `MODEL_ROUTING.json`, `HANDOFF_CODEX_EFFORT_<PROFILE>` in the environment, or `-CodexEffort`
  for one command, in that reverse order of precedence. The levels are `minimal`, `low`,
  `medium`, `high` and `xhigh`, and they stay valid across model generations. Automated
  Codex turns (`master-run`, `review-run`, the Codex Implementer) pass the resolved level
  as `-c model_reasoning_effort=<level>`. Effort and model are independent: map either one
  alone. The shipped file keeps every `codexEffort` on `inherit`, so installing changes
  nothing.
- **The list of levels is closed.** The value becomes part of the `codex exec` command
  line, so anything that is not one of the five levels blocks the turn before Codex starts,
  in `handoff.ps1` and in `handoff.sh` alike.
- **A concrete effort on `high_reasoning` is a cost escalation.** It needs
  `-AllowModelEscalation`, exactly as a concrete model does. An effort named on the command
  line is the user's own choice and needs no second approval.
- **`models`, `doctor` and `NEXT_TURN.md` name it.** `models` prints the resolved effort,
  its source and the override order; `doctor` reports it; `NEXT_TURN.md` carries a
  `Codex reasoning effort` line for a Codex turn driven in a window. An effort mapping on
  its own also clears the INERT notice. New protocol tests cover resolution, the closed
  list, the cost gate, the arguments each automated turn passes, and parity between the
  two shells.
- **Not verified against a live Codex.** The tests run against a stand-in for the Codex
  CLI and check the exact arguments passed. No real `codex exec` call was made for this
  release, so confirm the five level names against your installed Codex before mapping one.

## 3.15.1 - The Handoff File Stays Small

- **A real project's `AI_HANDOFF.md` reached 1.2 GB.** Windows PowerShell 5.1 reads a file
  with no BOM as ANSI. When Claude Code or Codex saved the handoff without a BOM, the next
  `Get-Content` in `handoff.ps1` misread every non-ASCII character, and `Set-Content` wrote
  the misread text back. Each such save doubled every em dash and Hebrew letter. Every read
  in `handoff.ps1`, `next-step.ps1` and `build-package.ps1` now says `-Encoding UTF8`, so a
  read-write cycle no longer changes the text, with or without a BOM.
- **`task-next` keeps only the standing sections.** It archived the finished task and then
  kept every dated note and every `Last Update (previous ...)` in the working copy, so the
  file grew with every task and every turn read all of it. After archiving it now keeps the
  template sections, `Plan` and any `Session Authorization ...` section; it resets `Done`,
  `Verification` and `Plan` to `- None yet`. The full text stays in `.ai/handoff-history/`.
- **`doctor` and `next` name the problem.** `doctor` fails on double-encoded text and warns
  when the file is over 256 KB; `next` prints the same notice. Eight new protocol tests.

## 3.15.0 - Who Holds Which Role, In Front of You

- **The binding that decides everything lived in a Markdown table.** Who implements and who
  reviews decides what may run and whose verdict counts, and the only way to see or change
  it was to open `.ai/roles/ROLE_ASSIGNMENT.md` and edit a table by hand - which also meant
  the Role Swap History row was skipped every single time.
- **`handoff.ps1 roles`** prints who holds each role, the rule that binds them and the state.
  **`roles -SetRole <role> -SetTool <tool>`** changes one role under the protocol's own
  guards: it refuses while a turn is running, refuses any swap that would make the Reviewer
  the Implementer, moves `Task Actors` with the binding when a task is in flight, and writes
  the history row itself.
- **`roles -Window`** opens a small always-on-top indicator (Windows): the project, the
  current task, a running turn with its elapsed time, and the three roles with a swap button
  each. While a turn runs the buttons are disabled, because that is the rule. The window owns
  no rules - every swap shells out to the command above. `roles -WindowOff` closes it, and
  the setting is remembered per project in `HANDOFF_UI.json` (local, gitignored).
- **The installer asks once** whether to show the indicator, and `work` names it once for a
  project that has never answered.
- **A review needs to know whose work it is.** `review-run` and `review-check` now refuse
  when `## Last Update` records no `- Actor:` for changes under review. A Master that
  implemented the work itself must say so - and then the self-review guard from v3.13.0
  applies. Anonymous changes were how three tasks reached review with no independent look.
- **Which model fills a strength class is answered at mapping time.** The protocol never
  shipped model names; now `MASTER.md` and `MODEL_GUIDANCE.md` also say how to find one:
  ask the tool what it offers today, prefer floating aliases over dated identifiers, and
  never trust a model name from an old file without confirming the tool still accepts it.

## 3.14.1 - A Denial Is Not a Database

- **The new database gate blocked a task that ruled the database out in its own words.** The
  task read "Write migration SQL file 009 and update TypeScript source ... No database
  access, no bucket creation, no migration apply - source files only", and the check matched
  "migration apply" without seeing the "no" in front of it. A sentence carrying a negation no
  longer counts as execution.
- **An explicit declaration ends the guessing.** `- Authorized Operations: none` in the
  Status section says this task needs no database; the gate steps aside and the turn prompt
  still forbids database access. The refusal now names that line too.

## 3.14.0 - The Work Continues

- **A finished task became a question to the user, every time.** `AI_SEQUENCE.md` shipped as
  a template and was never filled, so when a task closed there was nothing to move to; one
  Master went looking for the next task in the user's personal notes outside the project.
  `MASTER.md` also told it to stop at the task boundary, which was written for cost and read
  as "stop working". The rule is now **end the window, not the work**, with an explicit list
  of the only legitimate stops: a product decision, a deviation from the approved plan, an
  action needing authorization, an empty plan, or a real blocker - each one named, with what
  the user has to do.
- **The plan lives in the project.** `handoff.ps1 sequence-add -NextTask "..."` appends a
  pending task to `AI_SEQUENCE.md`, replacing the shipped placeholders on first use.
  `handoff.ps1 task-next` closes the finished task and opens the next one in a single
  guarded operation: it archives `AI_HANDOFF.md` to `.ai/handoff-history/`, writes the new
  Status, **resets `Changed Files`**, marks the plan rows, and regenerates `NEXT_TURN.md`.
  Opening a task by hand is what left the previous task's files declared, and the next
  Implementer turn was spent asking about it. `work` shows the next pending task and the
  command that opens it.
- **A tool with no usage left is a named stop.** When a turn fails and the provider's
  message reports a usage limit, `cycle` and `loop` print a `Provider Quota` stop with the
  reset time when one is given, and say the turn did not run and nothing was lost.
- **The output names the tool that actually ran.** "Checking Claude Code availability" and
  "Claude Code turn complete" were printed for Codex turns too, and a Master reported the
  wrong tool to its user. Every turn message now names the Implementer that took the turn.
- **`work` leads with the command.** For a role whose turn the protocol can run end to end,
  `work` now prints that command first and the copy-and-paste path second. The old order
  sent an agent Master to paste a prompt for a turn it could have run, and it improvised the
  turn by hand instead.

## 3.13.0 - Authorized Work, Generated Briefs, and Waiting

Three defects from one real session, in which the roles had just been swapped so that
Claude Code was Master and Reviewer and Codex was Implementer.

- **An approved database task could not be dispatched at all.** The automated Implementer
  turn's prompt forbids database access unconditionally, so the Implementer correctly
  refused work the user had authorized, and the turn was spent reaching `BLOCKED`. The
  authorization now lives in the handoff: `- Authorized Operations: database` in the
  `Status` section makes the turn's prompt allow exactly that work, bounded to disposable
  data, no reset or backfill, no schema or policy change beyond the task, cleanup, and
  recorded commands. Without that line, `cycle` and `loop` refuse a task that reads as
  database execution **before** spending a turn, and say what the user has to authorize.
  A task that merely writes a migration file still runs: the check needs a database noun
  and an execution verb in the same sentence.
- **A Master that hand-wrote `NEXT_TURN.md` looked like a Master that ran the protocol.**
  `next` now stamps the brief it generates with a hash of its own content, and `work` and
  `doctor` report a brief that was hand-written or edited afterwards. `MASTER.md` says
  plainly that the protocol is driven through its commands.
- **A background run told an interactive Master to hand the window back.** v3.11.0's
  instruction fits a Codex window, whose tool call cannot wait minutes. Claude Code can:
  the new `handoff.ps1 wait` blocks until the run finishes and prints its exit code, the
  handoff state and the last lines of its log, and a Claude Code agent is now told to use
  it instead of ending its turn. Nothing polls, and the user is not asked to check.
- **A tool could review work it had performed itself.** When the automated turn was
  blocked, the Master did the work in its own session; `Task Actors` still named the other
  tool as Implementer, so every existing actor check passed. `review-run` and
  `review-check` now also compare the Reviewer with the actor `AI_HANDOFF.md` records for
  the last turn, and refuse a self-review.

## 3.12.0 - The Push Is Yours, and Now You See It

- **Commits piled up unpushed.** The protocol never pushes, by design: `commit-approved`
  makes a local commit and says so. But nothing ever pointed the user back at the push,
  and one real project collected 20 local commits over three weeks. A first push that
  size publishes weeks of work at once, and where the host deploys on push, it deploys
  all of it.
- **The count is now in front of the user.** `commit-approved`, `work` and `status` say how
  many local commits wait for a push and give the command; `doctor` reports it as
  information. A branch that was never pushed gets `git push -u origin <branch>`. The
  reminder warns that a push can also deploy. It compares with the local upstream ref,
  so it runs no network command, and it never pushes.
- The Bash `status` carries the same reminder.
- `MASTER.md`: after a commit, the Master tells the user in one line how many commits wait
  for their push, and never pushes.

## 3.11.1 - Fast Is Not Further

- **Fast mode was spending the usage window 2.5x faster for the same answers.** The Codex
  app stores Fast as `service_tier = "priority"` in `config.toml`, and every window then
  runs on it. Per OpenAI's documentation GPT-5.6 and GPT-5.5 consume usage at 2.5x the
  Standard rate in Fast mode; the model and its reasoning are unchanged, only the wait is
  shorter. After a usage reset a Master window on Fast went from 0% to 99% in 17 minutes.
  When the usage window is the limit, Fast buys minutes and costs hours.
- **`doctor` warns when Fast mode is set** in the Codex user configuration (`CODEX_HOME`,
  default `~/.codex`) or the project's `.codex/config.toml`. It reads only the top-level
  `service_tier` line and prints only its value, because both files can hold MCP keys.
- `MODEL_GUIDANCE.md` explains what Fast changes and what it does not.

## 3.11.0 - Launch and Leave

- **v3.10.1's rule against checking on a running command was only words, and it did not
  hold.** The next Master window read "Do not babysit automated commands", started `loop`
  with a one-second wait, and then checked on it every minute. 23 of its 44 calls were
  those checks, each resending 50,000-80,000 tokens, and the five-hour usage window went
  from 17% to 98% in 19 minutes. An agent tool cannot wait longer than about a minute per
  call, so any command that runs for ten minutes invites the same loop.
- **From an agent window, long commands now start in the background and return at once.**
  `cycle`, `run-next`, `loop`, `review-run` and `master-run` detect an agent shell -
  `CODEX_CI` or `CODEX_SANDBOX*` for Codex, `CLAUDECODE` for Claude Code, or a `codex` or
  `claude` process above the shell - and relaunch themselves as a detached process with
  the same arguments. The call returns in about two seconds with nothing left to wait on,
  and prints `AGENT: END YOUR TURN NOW`. The run is created through WMI, so a tool that
  kills its command's process tree cannot take the run with it; `Start-Process` is the
  fallback.
- **The run reports itself.** It records `HANDOFF_BACKGROUND.json` (process, start time,
  finish time, exit code) and writes its output to `HANDOFF_BACKGROUND.log`; both are
  local, gitignored and exempt from the clean-tree check. Windows shows a notification
  when it ends. `status` and `work` show the run or its result, and `stop` terminates it.
- **One run at a time.** A second long command while a run is alive is refused, from an
  agent or a terminal, instead of racing it on the same `AI_HANDOFF.md`.
- **A background run cannot ask for confirmation,** so without `-Yes` it is not started,
  and the agent is told to ask the user first.
- **A person at a terminal is not affected.** Their shell has no agent above it and the
  command runs in the foreground as before. `HANDOFF_RUN_MODE=foreground` forces the old
  behaviour anywhere; `HANDOFF_RUN_MODE=background` forces the new one.
- `MASTER.md` and `NEXT_TURN.md` now describe what the command does instead of asking for
  restraint.

## 3.10.1 - A Window Is Not a Loop

- **A Master window used up a five-hour usage window in 48 minutes on the standard model.**
  Entering the protocol cost about 6,000 tokens, as v3.8.0 intended, but the person asked
  the Master to keep going, and it drove two whole tasks - about ten protocol turns - in
  one conversation. The context grew from 21,000 to 140,000 tokens and every call resent
  it: 116 calls and 9.8 million input tokens. Four protocol defects multiplied the calls.
- **Review works in a product repository.** `review-run` looked only for this project's
  own `scripts/protocol-tests.ps1`. Anywhere else the evidence said "not run", so every
  automated review returned BLOCKED, and the Master installed dependencies, ran builds and
  read whole diffs in its own window to get past it. With no protocol suite, `review-run`
  now runs the project's `typecheck` and `test` scripts from `package.json` outside the
  sandbox and gives the Reviewer their exit codes and last lines. Lint is not run, because
  a backlog that predates the task would block every review. A plan review runs no checks
  at all, since there is no code yet, and says so.
- **Implementer turns get ten minutes.** `cycle` and `loop` default to 600 seconds. At 180 a
  turn that edited four files was killed halfway, and the partial work took a review and a
  correction round to repair. An explicit `-TimeoutSeconds` still wins.
- **`Changed Files` accepts the notes agents write.** "- `path` (a note)" and "- path (new)"
  now name the path, in both shells. Twice the scope check failed on an annotation and a
  turn was spent removing it. A filename that really ends in a parenthesis is kept whole.
- **One window, one protocol turn.** `NEXT_TURN.md` tells the actor to run an automated
  command once with a long wait instead of checking on it repeatedly - 35 of the 116 calls
  did only that - and to open a new window for the next task. `MASTER.md` adds three rules:
  do not babysit commands, stop at the task boundary, and do not do the harness's work. A
  long unattended chain belongs in `loop -IncludeMaster -IncludeReviewer` in a terminal,
  where every turn is a fresh, small `codex exec`.
- **The merged `.claude/settings.json` keeps a clean layout.** Windows PowerShell 5.1 wrote
  it with padded, column-aligned properties; the installer now writes two-space JSON, the
  layout `install.sh` already wrote.

## 3.10.0 - The Model Follows the Task

- **Every Codex turn ran on whatever model the Codex configuration named.** The Master
  picks a capability profile for each task, but only Claude read it. `master-run`,
  `review-run` and the Codex Implementer called `codex exec` with no model, so a task
  marked `high_reasoning` was routed and reviewed on the standard model, and a window
  left on the strongest model ran ordinary turns on it. In one measured session that
  used up a five-hour usage window in three minutes.
- **One profile now resolves to one model per tool.** `MODEL_ROUTING.json` gains
  `codexModel` beside `claudeModel`, and `HANDOFF_CODEX_MODEL_<PROFILE>` overrides it the
  way `HANDOFF_CLAUDE_MODEL_<PROFILE>` does for Claude. `-CodexModel` sets it for one
  command. Every shipped value stays `inherit`, so installing changes nothing until you
  map a model.
- **Automated Codex turns pass the resolved model.** `master-run`, `review-run` and the
  Codex Implementer add `--model` for a concrete value and print the model they run on.
  A concrete `high_reasoning` Codex model requires `-AllowModelEscalation`, the same cost
  gate Claude has had since v3.4.0.
- **`NEXT_TURN.md` names the model for a turn you drive in a window.** A
  `Model For This Turn` section gives the profile and the model for the actor's own
  tool, in both shells. When a model is mapped, it says to start a new window on it
  rather than switch models inside the conversation: a switch resends the whole
  conversation to the new model without its cache, and a new window loses nothing
  because the state is in `AI_HANDOFF.md`.
- **`models` and `doctor` report the Codex model and its source**, and INERT now means
  that neither tool has a route to a concrete model.
- **The Bash suite no longer reads the machine's routing.** Like the PowerShell suite
  since v3.8.0, it clears `HANDOFF_*_MODEL_*` for its own process. A user with routing
  activated saw their own model where the fixtures expected none.

## 3.9.0 - Keys Stay Out of Reach

- **An agent opened a credential file, and nothing in the protocol noticed.** On a real
  project an Implementer read `.mcp.json` against an explicit written instruction, and a
  live access token and an API key went into that session. A person found it afterwards
  by reading the handoff. The rule existed only as a sentence in a prompt, and a
  sentence is not a boundary. Three mechanisms now enforce it for every install, with
  nothing for the user to configure.
- **The installer keeps Claude Code out of credential files.** Both installers add deny
  rules to `.claude/settings.json` so Claude Code's file tools cannot open `.env`,
  `.env.local`, `.env.*.local`, `.env.production`, `.mcp.json` or `.codex/config.toml`.
  The programs that use those files still load them; only the agent is kept out, and
  `.env.example` stays readable. The rules live in one shipped file,
  `CREDENTIAL_READ_DENY.txt`, that both installers read. An existing settings file is
  merged and never replaced; one that cannot be parsed is left untouched and reported.
  This changes Claude Code's behavior in the project by design: to let Claude read one of
  these files, remove its rule from `permissions.deny`. Codex exposes no documented
  per-path read deny, so this layer covers Claude Code only.
- **Every automated turn is checked for a leaked credential.** After `cycle`, `loop`,
  `review-run` and `master-run`, the turn's local captures are searched for credential
  shapes. A match is redacted in place and the run stops with exit 13 and a Security stop
  category that names the file and the kind of credential, never the value. Rotation is
  still the user's job: a key that passed through an agent session is exposed whatever
  happens to the file. Shapes cannot match inside a longer word, so ordinary text such as
  a hyphenated task name does not trip the gate.
- **`doctor` reports literal keys in MCP configuration that Git never sees.** The v3.6.0
  check covered tracked files only, so a key in an ignored `.mcp.json` was invisible to
  it. `doctor` now reports literal credentials in `.mcp.json`, `.codex/config.toml`,
  `.vscode/mcp.json` and `.cursor/mcp.json`, recommends browser login or an environment
  variable referenced by name, and reports missing deny rules. Values are never printed.
- **One list of credential shapes.** `doctor`, the tracked-file check and the leak gate
  share it, and it now recognizes Supabase secret keys and Google's `AQ.` API keys.
- **The rule is written where each role reads it.** `MASTER.md` gains a `Credential Files`
  section, `IMPLEMENTER.md` a rule, and every automated agent prompt forbids opening
  credential files and says to record a missing connection as a blocker for the user.

## 3.8.0 - A Master That Reads Less

- **A Master turn loaded the whole protocol before it did anything.** Measured on a real
  project, one Codex session spent about 40,000 tokens - 17% of a five-hour usage window -
  reading `SKILL.md`, `MASTER.md`, `PROTOCOL_METHOD.md`, `ADAPTERS.md` and the execution
  policy in full, then resent that context on every later tool call. The window ran out
  three minutes later. The window entry path told the agent to "always read SKILL.md", and
  the index listed every document. The automated Master prompt had been lean since v2.0.1;
  the path a person actually drives had not. The entry path now reads `ROLE_ASSIGNMENT.md`,
  `NEXT_TURN.md` and the `AI_HANDOFF.md` sections the turn needs, and looks every other
  rule up by section heading.
- **`MASTER.md` has a `Context Budget` section.** Look protocol rules up instead of
  reading documents; delegate repository investigation to the Implementer instead of
  reading application source; search before reading and keep each tool result bounded;
  route ordinary turns on the standard model; start a fresh window per protocol turn. The
  budget never relaxes a safety gate.
- **`NEXT_TURN.md` carries a line-numbered map of `AI_HANDOFF.md`**, in both shells, so the
  next actor can read one section instead of the whole file.
- **Implementer investigation reports are bounded** to about 800 words with `file:line`
  citations, because the Reviewer reads them on its own budget.
- **`MODEL_GUIDANCE.md` covers the Master's own cost** - its model and its context size,
  neither of which `MODEL_ROUTING.json` controls.
- **A test measures what the entry path tells the agent to read in full**, resolved to the
  files that ship, and fails if a heavy protocol document returns to that path or the
  mandatory reads grow past about 6,000 tokens.

## 3.7.0 - A Place To Put What Was Decided

- **The protocol had nowhere to record a decision, so it recorded none.** `AI_HANDOFF.md`
  holds one live task and `start` archives and replaces it; the Master is told, correctly,
  not to write advisory answers into task state. With no second destination the cheapest
  knowledge survived and the most expensive evaporated: a brainstorming session that
  settled a product's audience, platform, media retention and approval flow left no trace
  in any file, and the next session - a different tool, a fresh window - searched the
  project and found only the technical task. `DECISIONS.md` now ships with the protocol.
  It accumulates, `start` never resets it, and it is tracked by Git, because product
  decisions belong in the project's history and must be readable by a tool that was not
  in the room. The Master's entry prompt and `MASTER.md` both carry the duty to append to
  it when the user confirms something, **including in an advisory turn that never opens a
  task** - which is the case the file exists for.
- **An upgrade no longer deletes what the project added to `ROLE_ASSIGNMENT.md`.** The
  merge rebuilt the file from the template and substituted only the three role rows, so a
  Role Swap History table - which `ROLE_ASSIGNMENT.md` itself instructs the user to keep
  ("record what changed, when, and that the user approved it") - was destroyed on every
  `-Force` upgrade, silently. Three swap histories were reconstructed by hand in one day
  before anyone noticed. Sections the template does not have are carried across and
  re-inserted after the section they followed, in both installers.
- **`work` asks the adapter registry before sending you to copy and paste.** For a turn
  the registry can run end-to-end - `NEEDS_INVESTIGATION` for a Claude Code Implementer,
  automated since v3.5.0 - the one command whose whole job is to name the single next
  action was still printing "open the tool and use the standard handoff prompt". It now
  names `cycle` for auto-loop-eligible turns and still offers the manual path. The
  explicit-command adapters are deliberately not promoted over the paste: those drive the
  Codex CLI, which not every install has.
- **A test asserts the built Skill package matches `templates/` byte for byte.** v3.5.2
  shipped a package whose `gitignore-snippet.txt` predated v3.5.0 because the build step
  was not re-run before the release, and nothing compared the two. A release that forgets
  to build ships the previous release's content under the new version number.
- Every fix above is mirrored in the Bash installer and the Bash suite, which grew from
  28 checks to 32. The v3.6.1 lesson - that a fix touching one shell reintroduces the
  disagreement the repository already forbids - was applied while writing these, not after.

## 3.6.1 - Both Shells, One Answer

- **v3.6.0 exempted the role file in PowerShell and not in Bash.** `handoff.ps1` stopped
  counting `.ai/roles/ROLE_ASSIGNMENT.md` as a project change so a role swap would not
  block the turn it enables. `handoff.sh commit-check` keeps its own hardcoded
  `LOCAL_IGNORED` list and never got the entry, so Bash blocked a commit PowerShell
  allowed, on the same repository, over the same file. The repository already states the
  rule this broke - "both gates must agree on what a changed file is; two parsers meant
  two answers" - and a fix that touched one parser reintroduced exactly that. A test now
  asserts the Bash list carries the entry.
- **`handoff.sh commit-check` warns about tracked credential files.** It is the one Bash
  command that inspects what is about to be committed, and clearing a protocol stop with
  a bulk `git add -A` is precisely how a live token reaches history. PowerShell gained
  this warning in v3.6.0 through `doctor` and the dirty-tree stop; Bash had nothing at
  the moment it mattered most. Name-based only - Bash does not read file contents here -
  covering `.mcp.json`, `.codex/config.toml` and `.env`.
- `handoff.sh` reported itself as v1.3.1 until v3.6.0 and now tracks the release version.

## 3.6.0 - Guards That Were Only Pretending

- **The clean-tree gate was quietly the most dangerous instruction in the protocol.**
  `cycle` and `loop` refuse to run on a dirty tree, print every blocking file, and say
  "Commit, stash, revert, or remove these files." Facing a list of eighty files, the
  operator's path of least resistance is `git add -A` - and an agent MCP configuration
  holds an API token in plain text, because neither `.mcp.json` nor `.codex/config.toml`
  can read a value from `.env`. This protocol stops before commit, push, tag, release,
  deploy, database and secret actions. Burying a live credential in Git history was the
  one sensitive action it was actively nudging people toward.
- **The installer now ignores both agent credential files.** `/.mcp.json` and
  `/.codex/config.toml` join the managed `.gitignore` block, so an upgrade adds them to
  an existing install through the same line-by-line reconciliation added in v3.5.0. The
  protocol requires both agents in one repository; their credential files are in play by
  its own design, which makes them its business to protect.
- **`doctor` reports tracked files that look like they carry credentials**, by known
  filename and by high-confidence token pattern - Supabase, OpenAI, GitHub, Google,
  Slack, private keys. Tracked, specifically: an untracked `.env` is a local file, while
  a tracked one is already one commit from permanent history. It warns rather than
  fails, because an existing project may have had such a file for years and doctor
  breaking on discovery helps nobody. Template names - `.env.example` and friends - are
  exempt, so the check does not cry wolf on the file that exists to be committed.
- **The dirty-tree stop now names the risk instead of implying the fix.** When a
  blocking file matches, the stop adds an explicit warning not to clear it with a bulk
  `git add -A`. Same gate, same rules; it just no longer stays silent at the exact
  moment its own instruction is most likely to be followed carelessly.
- **`review-apply` accepted a verdict from a tool that did not hold the Reviewer role.**
  v3.5.0 announced that the captured-verdict guard had been changed from "REVIEWER must
  be Codex" to "REVIEWER must be the bound Reviewer", and called the new form strictly
  stronger. The `review-apply` path was never changed; it still compared against the
  literal string `Codex`. Under a swapped binding it was wrong in both directions at
  once - it accepted a capture signed by Codex while Claude Code held the Reviewer role,
  and it would have refused the legitimate capture the bound Reviewer produced. Applying
  a verdict from a tool that does not hold the Reviewer role defeats the single
  invariant this protocol exists to enforce: that no agent is the sole reviewer of its
  own work. It now compares against the bound Reviewer and fails closed when the binding
  cannot be resolved.
- **The test that was supposed to prove the v3.5.0 claim asserted only a non-zero exit
  code.** It passed for four releases because the fixture's edited role file left the
  tree dirty and an unrelated guard failed first. An exit code is not a reason. It now
  asserts the refusal message, and a companion test covers the other half the hardcoded
  form would have broken: the bound Reviewer's own capture must be accepted under a
  swapped binding. Surfaced only because exempting the role file from the clean-tree
  gate removed the accident that was standing in for the guard.

- **The Bash companion still described the pre-3.5.0 world.** `handoff.sh` resolved
  adapters by asking which vendor filled the seat - `role = Implementer AND tool =
  Claude Code`, `role = Master AND tool = Codex`, `role = Reviewer AND tool = Codex`.
  Under a swapped binding all three fell through to "no verified local callable
  adapter", telling the operator their configuration was unsupported when the
  PowerShell path supports it. The conditions now key on the role alone, which is what
  "permission follows the role" means, and `handoff.sh adapters` prints the same
  six-row matrix as `handoff.ps1` so the symmetry is checkable from either shell. Its
  header still said v1.3.1.
- The credential detector's own test no longer ships a literal token-shaped string; the
  probe value is assembled at runtime. A public repository that trips its own detector,
  or GitHub push protection, would be its own worst advertisement.

- **A role swap no longer blocks the turn it exists to enable.** Swapping roles edits
  `.ai/roles/ROLE_ASSIGNMENT.md`, which is tracked on purpose - it records who holds
  which role and belongs in project history. But the edit dirtied the working tree, the
  clean-tree gate then refused the automated turn the swap was performed to make
  possible, and the only way through was a commit the user had to approve separately,
  for a change they had already approved. The protocol's own configuration change was
  blocking the protocol. The file now sits in the same list as the local coordination
  files, which exempts it from the gate and simultaneously adds it to the read-only
  boundary snapshot - so a Master or Reviewer turn still cannot rewrite the binding it
  is meant to obey. The commit gate is untouched; there is simply nothing left that
  requires a commit first. Reported by a user whose swap-back to Codex stalled on it.
- Found by leaking a Supabase account token into a project's local history while
  clearing this very stop, during a live pilot of the protocol.

## 3.5.3 - The Version The Agent Reads

- **Every v3.5.2 install announced itself as 3.3.2.** The two `SKILL.md` files that ship
  to installers - `templates/.agents/...` and `templates/.claude/...` - carried
  `version: "3.3.2"` in their frontmatter while `VERSION` advanced through 3.4.x and
  3.5.x. That frontmatter is what an agent loads when it picks up the skill, so asking
  Codex or Claude Code which version was installed returned a number three releases
  stale. `VERSION`, `doctor` and `handoff.ps1` all reported 3.5.2 correctly; the one
  surface a user can read without running a command did not.
- **A test for exactly this already existed and did not catch it.** v3.4.1 added "the
  public Skill version matches the canonical VERSION file" precisely so a stale literal
  could not hide a mismatch. It reads the repository's *own* Skill entry point, which is
  bumped every release and therefore always passed. The shipped copies under
  `templates/` were never covered. The check now asserts both shipped `SKILL.md` files
  against the shipped `VERSION`, which is the pair the installer actually delivers.
  Measuring the convenient copy instead of the shipped copy was not a test of the
  property it named.
- **`ROLE_ASSIGNMENT.md` still described the pre-3.5.0 world.** Its Tooling Note claimed
  `cycle` and `loop` automate only `READY_FOR_IMPLEMENTATION`, only for an Implementer
  bound to Claude Code, and that a Codex Implementer blocks and must be run manually.
  v3.5.0 made all six role/tool combinations callable and v3.5.0 also automates
  `NEEDS_INVESTIGATION`; the note was refreshed by the installer on every upgrade and
  kept restating the old limits. It now points at `handoff.ps1 adapters` as the
  authority rather than restating the registry in prose that ages.
- **The shipped Skill package was stale against its own templates.** The packaged
  `gitignore-snippet.txt` still lacked the seven role-named capture files that v3.5.0
  introduced, so an install through the Skill package left `REVIEW_LAST.md`,
  `MASTER_LAST.md`, `IMPLEMENTER_LAST.md` and their event logs untracked-but-unignored.
  Installing from the repository templates was unaffected, which is why it went unseen.
  Rebuilding the package as part of this release corrects it; nothing asserts that the
  built package matches `templates/`, and that check is still missing.
- Found by running the protocol against a real project and asking the Master a
  one-sentence question: which version is installed.

# Changelog

All notable changes to the codex-claude-handoff protocol are documented here.
Versions follow the `VERSION` file in `.ai/skills/codex-claude-handoff/`.

## 3.5.2 - One Answer About Routing, From Every Command

- `doctor` and `models` now give the same activation guidance. v3.5.1 taught the INERT
  detector about environment overrides and updated the `models` message, but left
  `doctor` naming `MODEL_ROUTING.json` as the only way to activate routing - and that
  file is the one that ships to every installer, so it is the route most operators
  should NOT take. Both commands now name the environment route first and say plainly
  that it touches no tracked file.
- `doctor`'s INERT line no longer describes the state as a property of
  `MODEL_ROUTING.json`; it reports what is actually true, that no profile resolves to a
  concrete model by any route.

## 3.5.1 - Routing Status Tells the Truth

- `models` and `doctor` no longer report routing as INERT while simultaneously resolving
  a concrete model. The documented override order is `-Model`, then
  `HANDOFF_CLAUDE_MODEL_<PROFILE>`, then `MODEL_ROUTING.json`, then inherit - but the
  INERT check read only the file. Activating routing through the environment, which is
  the way to activate it *without* editing a file that ships to every installer,
  produced a report that contradicted itself in adjacent lines: "Claude model: sonnet /
  source: environment HANDOFF_CLAUDE_MODEL_STANDARD", followed by "INERT ... every turn
  runs on whatever model Claude Code is already using". INERT now means what it says -
  every route to a concrete model is closed - and an override whose value is literally
  `inherit` correctly does not clear it.
- The INERT guidance names the environment route alongside the file, so the option that
  does not require editing a shipped default is discoverable.

## 3.5.0 - Symmetric Role Adapters

- **Permission now follows the role, not the tool.** Until this release the permission a
  turn ran under was in practice a property of the vendor: Codex was always invoked
  read-only because Codex only ever held Master or Reviewer, and Claude Code was always
  invoked write-enabled because it only ever held Implementer. Nothing stated the rule -
  it was an accident of who sat where, and it would have handed a Reviewer write access
  the moment the roles were swapped. The rule is now written once, in
  `Get-RolePermission`, and every adapter and invocation reads it: Master and Reviewer
  are read-only, Implementer is write-enabled, whichever tool holds the role.
- **All six role/tool combinations are callable.** Master, Reviewer and Implementer, each
  held by either Codex or Claude Code. Previously three of the six were automated and the
  other three fell back to manual copy-paste, so the roles were swappable in name while
  the automation ran in one direction only. `handoff.ps1 adapters` now prints the full
  matrix, independent of the current binding, so the symmetry is checkable rather than
  promised.
- Claude Code can hold the Master and Reviewer roles. Its read-only turns disable the
  file-writing tools at the CLI (`Bash,Edit,Write,NotebookEdit`), state the restriction in
  both the prompt and the system prompt, and compare the working tree after the turn. A
  read-only turn that changed anything fails and its capture is discarded - a verdict from
  a reviewer that touched the work is worth less than no verdict at all.
- Codex can hold the Implementer role, invoked with `--sandbox workspace-write`, never
  with `--ask-for-approval` and never with `--dangerously-bypass-approvals-and-sandbox`.
  A NEEDS_INVESTIGATION turn keeps `workspace-write`: it has to record its findings in
  AI_HANDOFF.md and transition the state, so a read-only sandbox would have deadlocked a
  state advertised as callable. Source-read-only never meant "writes nothing" - it is a
  boundary no sandbox mode expresses, and it is enforced after the turn, identically for
  both tools, by the same check that has always bounded the Claude Implementer. The
  exact-scope check runs after the turn for both tools as well. Caught by the Codex
  Reviewer while reviewing this release.
- Captures are named after the role that produced them - `REVIEW_LAST.md`,
  `MASTER_LAST.md`, `IMPLEMENTER_LAST.md` and their event logs - instead of after the
  vendor. A vendor-named capture would have become a false statement the first time the
  roles were swapped. Legacy `CODEX_*` and `CLAUDE_IMPLEMENTER_*` files are still read
  when no role-named capture is present, so an install that upgrades mid-task keeps
  working.
- The captured-verdict guard now requires REVIEWER to match the **bound Reviewer** rather
  than to be Codex. That was always the check it meant to make, and it is strictly
  stronger: it also refuses a capture produced by the wrong tool, which the old form would
  have accepted.
- `review-apply` no longer records "Reviewer (Codex)" regardless of who reviewed. After a
  swap that was a false entry in the audit record.
- The read-only boundary is measured by file CONTENT, not by the set of changed file
  names. A Reviewer runs on a dirty tree by definition, so a name-set comparison would
  have let a read-only turn edit a file that was already dirty and pass unnoticed - the
  reviewer could have rewritten the very code it was reviewing. Every changed file and
  every local coordination file is hashed before and after the turn; a differing hash, a
  vanished path or a new path all fail the turn. Found by the Codex Reviewer while
  reviewing this release.
- The release dry run now reports what will actually happen. `release-check` printed
  "ready for explicit authorization" and then exited 1, because the ready path fell off
  the end of the function and inherited the exit status of the last internal probe -
  anything gating on the exit code read a successful dry run as a failure. It exits 0
  explicitly now. Separately, the printed command list always named `git add` and
  `git commit`, including on the already-committed path where the executor deliberately
  skips both; the dry run is the one thing an operator reads before authorising an
  irreversible action, so it now prints the commands that will really run.

- **Upgrade fix:** `install.ps1` added the `.gitignore` block only when it was missing
  entirely, so a project installed before this release would never have received the new
  local capture names. Those files would then be untracked-but-not-ignored, and the very
  next `review-run` would fail its own exact-scope guard on artifacts the protocol itself
  had just written. The installer now reconciles the ignore list line by line, adding only
  what is missing and preserving everything already there.

## 3.4.4 - Reviewable Planning Gate

- `review-run` gains a plan mode. The Master can route a task to PLAN_REQUIRED, asking
  for a plan to be reviewed before implementation, but `review-run` previously refused
  whenever Changed Files was empty - so the Master could send you to a gate the Reviewer
  could not open. Plan mode is entered automatically when Changed Files is empty and
  AI_HANDOFF.md carries a non-empty `## Plan` section, and the Reviewer is asked to judge
  scope boundaries, acceptance criteria and honesty of the out-of-scope list rather than
  to hunt for code defects that do not exist yet.
- An approved PLAN transitions to READY_FOR_IMPLEMENTATION, not REVIEW_DONE. Approving a
  plan authorizes work; it does not finish it.
- Plan-mode evidence is the SHA-256 of AI_HANDOFF.md, verified by the Reviewer the same
  way changed files are, so a plan edited after the evidence was produced fails closed.
- An empty Changed Files list with no Plan section still refuses. Nothing to review is
  still nothing to review.
## 3.4.3 - Adoption and Efficiency

- Exact-scope paths now compare case-SENSITIVELY. `Test-SameFileSet` used
  `OrdinalIgnoreCase`, so on a case-sensitive filesystem two different files compared
  equal in the check that decides what gets committed and released. When two sets differ
  only by letter case the mismatch message now says so, because "does not match" printed
  over two lists that look identical is not actionable.
- Activating model routing is one guarded command:
  `handoff.ps1 models -Activate -Standard <model> [-CheapReadonly <model>] ...`. It writes
  only the profiles named, preserves the rest and the file's `_readme`, and re-reads the
  result before replacing the live configuration so an unparseable file can never become
  active. It refuses with no mapping and refuses to edit an unparseable file. The shipped
  configuration still maps every profile to `inherit`: installing changes no behavior and
  no vendor model name ships with the protocol.
- The Bash exact-scope parser is now executed, not just asserted about.
  `scripts/protocol-tests.sh` builds throwaway repositories and runs `handoff.sh
  commit-check` against spaced, non-ASCII, nested and renamed paths, checks that an
  undeclared file still blocks, and checks that a failing `git status` blocks rather than
  approving a partial set. The PowerShell suite runs the Bash suite when an interpreter is
  present and reports SKIPPED - never passed - when it is not.
## 3.4.2 - First-run Clarity

- Inert model routing is now visible. `models` and `doctor` report INERT when every
  profile in `MODEL_ROUTING.json` resolves to `inherit`, and name the file to edit.
  Shipped defaults are unchanged: installing still alters no behavior, and concrete
  provider model names are still deliberately not shipped.
- A running turn can be seen and stopped. A local gitignored `HANDOFF_RUN.json` records
  an in-flight automated turn; `status` and `doctor` report it; `handoff.ps1 stop` ends
  it without touching Git or task state. A marker is identified by process id AND start
  time, so a recycled id is never mistaken for the recorded turn, and a marker that
  cannot be positively identified reads as stale rather than live.
- The release executor is reachable again. When the working tree is clean, `release`
  verifies scope against the file set of HEAD instead of failing on an empty
  `git status`, so `commit-approved` followed by `release` now works. `user-next` at
  REVIEW_DONE names both paths.
- Added `START_HERE.md`, a first-run orientation page: what the protocol is and is not,
  the roles and the user's sole approval authority, a first task end to end, the four
  blocks a newcomer actually hits with the command that resolves each, how to stop, and
  how to remove only the paths the protocol owns.
## 3.4.1 - Identity, History and Packaging Hardening

- Added a canonical tool-identity layer (`Resolve-ToolIdentity`, `Test-SameToolIdentity`)
  with an explicit registry and legacy display aliases. Every role gate, adapter
  lookup and capture comparison now resolves identity instead of comparing display
  text, so one tool under two names can no longer satisfy the Reviewer != Implementer
  invariant. An unrecognized identity is rejected, never guessed.
- Added archive-before-reset. `start` copies the outgoing `AI_HANDOFF.md` byte-for-byte
  into the gitignored `.ai/handoff-history/`, verifies it by SHA-256, writes sidecar
  metadata, and refuses to reset when the archive cannot be written.
- Added a narrow guarded recovery path for terminal role drift, and rewrote the role
  checkpoint failure message so it describes that path instead of advising a manual
  rewrite of a finished record.
- Replaced the hand-rolled `.gitignore` scan with `git check-ignore`, removing a false
  warning on correctly configured repositories.
- Hardened exact-scope path handling. Both PowerShell parsers and the Bash parser now
  read `git status --porcelain=v1 -z`, share one encoding-explicit UTF-8 capture that
  does not depend on the console codepage, discard rename and copy source fields, and
  fail closed on a failed `git status`. Non-ASCII and spaced paths are handled exactly.
- Added a packaging gate. `release-check` and `release` now refuse a version whose ZIP
  and `.sha256` do not exist in `dist/` and agree with each other.
- `bootstrap.ps1` installs from the published release asset and verifies its SHA-256
  before extracting. A missing asset, missing or malformed checksum, name mismatch or
  hash mismatch aborts before anything is written.
- `doctor -CheckUpdates` now reports the latest source tag, whether a GitHub Release
  exists for it, and whether the required ZIP and checksum assets are attached, as
  three separate results. A tag without a release is a WARN, not a PASS.
- `next` now surfaces the callable automated route alongside the manual paste, and
  `user-next` prints a runnable command including the repository path.
## 3.4.0 - Dynamic Model Resolver

- Added stable `auto`, `economy`, `cheap_readonly`, `standard`, and
  `high_reasoning` capability profiles without freezing provider model names.
- Added project-local `MODEL_ROUTING.json`, environment overrides, explicit
  one-turn model selection, and safe fallback to the host's configured model.
- Made Master routing capture and preserve the selected capability profile in
  `AI_HANDOFF.md`.
- Added `handoff.ps1 models` and doctor diagnostics for read-only model-routing
  transparency.
- Added fail-closed approval for concrete `high_reasoning` cost escalation and
  structured evidence for the adapter-requested profile and model.
- Added focused resolver, precedence, malformed-config, CLI argv, evidence, and
  escalation-guard tests.

## 3.3.2 - Public Package Frontmatter Hardening

- Replaced colon-sensitive inline descriptions with YAML-safe folded scalars in
  every public Skill entry point and nested release mirror.
- Added regression coverage that rejects public Skill frontmatter which could be
  skipped by the skills CLI parser.
- Updated pinned setup paths, package metadata, and release guidance to v3.3.2.

## 3.3.1 - Public Positioning and Discovery

- Reframed the public Skill as a supervised, bounded cross-agent collaboration
  protocol rather than a discovery adapter, session-summary handoff, or parallel
  answer generator.
- Centered the public promise on an accountable engineering pair: one agent drives
  or implements, a different agent challenges and reviews, and neither ships alone.
- Clarified that Reviewer-blocked implementation correction can run in a bounded
  loop, while general two-way question states still require explicit turns.
- Added concise human-facing differentiation: live task coordination, independent
  review, durable project state, exact-scope checks, fail-closed behavior, and user
  approval gates.
- Documented user-approved role flexibility while preserving the invariant that
  Reviewer and Implementer must differ and noting that automation depends on
  verified adapters.
- Expanded discovery metadata with `multi-agent`, `cross-agent`, implementation,
  code-review, and human-in-the-loop language without renaming the Skill.
- Added a verified live-demo package and evidence record for public sharing, plus
  platform-specific launch copy for LinkedIn, Reddit, Hacker News, X, Discord, and
  direct messages.

## 3.3.0 - skills.sh Public Beta Packaging

- Replaced the discovery-only adapters with portable, explicitly activated Skill
  entry points that can install or run the project-local protocol.
- Bundled an offline installer and project templates inside both Codex and Claude
  Code Skill locations so `npx skills add` produces a self-contained package.
- Added first-use setup scripts for PowerShell and Bash. Setup requires a Git
  repository, requests user approval through the Skill workflow, runs `doctor`, and
  performs no Git or production action.
- Added OpenAI Skill interface metadata with implicit invocation disabled.
- Licensed the project under Apache-2.0 and included the license in release packages.
- Added packaging, mirror, no-network, clean-install, and skills CLI acceptance
  coverage for the public beta.

## 3.2.2 - VS Code Shared Workspace Guidance

- Documented VS Code as the recommended workspace for using Codex and Claude Code on
  the same project folder.
- Clarified that the protocol coordinates through local handoff files and is not a
  native VS Code extension or unrestricted background chat bridge.
- Mirrored the guidance in the skill, quick start, operating model, adapter registry,
  and internal publishing documentation.

## 3.2.1 - Doctor Version Hardening

- Hardened `handoff.ps1 doctor` to validate required installed protocol components
  and reject missing or malformed local version metadata.
- Added opt-in `doctor -CheckUpdates` comparison against stable GitHub release tags.
- Added explicit doctor result codes for invalid local installs, available updates,
  and unavailable remote checks while keeping the check read-only.

## 3.2.0 - Internal Publication Readiness

- Added an internal publishing guide for colleagues, including positioning,
  onboarding steps, support boundaries, and a go/no-go checklist.
- Added security and trust guidance that explains local coordination files, approval
  boundaries, secrets, and what users should review before running the workflow.
- Added model-selection guidance so operators can use economical models for routine
  work and reserve stronger models for final publication, security, and release
  reviews.
- Included the publication documents in the release package and added package
  coverage for them.

## 3.1.11 - Safe In-Place Updates

- Changed `install.ps1 -Force` and `scripts/install.sh --force` to preserve existing
  `AI_HANDOFF.md` and `AI_SEQUENCE.md` instead of resetting live coordination state.
- Preserved the current role binding across updates while still refreshing the
  managed instructions in `ROLE_ASSIGNMENT.md`.
- Added installer regression coverage for handoff, sequence, role-binding, and
  managed-file refresh behavior.

## 3.1.10 - Runtime Role Synchronization Checkpoint

- Made `ROLE_ASSIGNMENT.md` the authoritative role-binding source.
- Added a mandatory turn-start checkpoint that fails closed on stale Task Actors
  or a Reviewer/Implementer invariant violation.

## 3.1.9 - Current-Folder Installation and Slash Activation

- Simplified the public Windows installation journey to one pasted PowerShell command
  that installs into the current project folder without asking the user to edit or
  repeat a project path.
- Changed the PowerShell and Bash installer completion guidance to open `/skills` and
  select `codex-claude-handoff`, matching the visible Codex skill-selection workflow.
- Clarified skill metadata so `/skills` selection, `$codex-claude-handoff` mentions,
  explicit naming, and full-protocol requests remain valid activation boundaries.
- Added regression coverage requiring `/skills` guidance and rejecting the obsolete
  `$codex-claude-handoff`-only installer message.
- Rebuilt the release package so its README, quick start, installer output, versioned
  bootstrap, ZIP, and checksum all contain the corrected beginner journey.

## 3.1.8 - Explicit Activation and Installable Packaging

- Changed the default project installation from always-on root instructions to an
  explicit, task-scoped skill activation. Users select `$codex-claude-handoff` only
  for work that should run through the full protocol; ordinary Codex tasks remain
  ordinary.
- Narrowed all Codex, canonical, and Claude skill descriptions so they trigger only
  when the user explicitly selects or names the skill, or requests the full handoff
  protocol.
- Added `install.ps1 -AlwaysOn` for project owners who intentionally want root
  `AGENTS.md` and `CLAUDE.md` integration. It is no longer the default.
- Added `-DisableAlwaysOn` as a fail-closed migration for older installs. It removes
  only bundled root instructions whose hashes still match the package and refuses to
  delete customized project files.
- Stopped copying package-only protocol test harnesses and installer snippets into
  target projects.
- Added a pinned `bootstrap.ps1` downloader for first-time Windows installation and
  rewrote the Quick Start around the actual stranger journey: one-time Claude login,
  project install, baseline commit, doctor, explicit activation, and normal opt-out.
- Added regression coverage for opt-in installation, always-on installation, host
  `AGENTS.md` preservation, package-only exclusions, bootstrap delegation, and pinned
  version validation.

## 3.1.7 - Autonomous Investigation and Clean Claude Runtime

- Added `NEEDS_INVESTIGATION` to the verified Claude Code Implementer adapter, so
  `cycle`, `run-next`, and `loop` perform read-only repository investigation without
  requiring the user to open a separate Claude window and paste `NEXT_TURN.md`.
- Added a fail-closed post-turn boundary: an automated investigation may update local
  handoff artifacts, but any application/source/test/config change stops with Protocol
  Repair even if the handoff state advanced.
- Added Claude Code `--safe-mode` to automated turns. OAuth, model selection, built-in
  tools, and permissions remain available, while ambient plugins and hooks (including
  unrelated Bun-dependent hooks) cannot pollute or break the handoff run.
- Added regression coverage for automatic investigation routing, handoff-only success,
  forbidden source-edit detection, safe-mode argv delivery, capture transparency, and
  canonical/template parity.
- Fixed the hanging-runner fixture to recognize the real third-position `--version`
  probe, removing a cold-host timeout false negative without changing production timeout
  behavior.
- Added a Windows Job Object boundary around the bounded Claude runner, so timeout
  termination kills the complete descendant tree even where WMI enumeration and
  `taskkill /T` are unavailable; the existing cross-platform fallback remains.

## 3.1.6 - Strict Human Acceptance Review

- Hardened the independent Reviewer against false approvals: it now verifies relevant
  safe local checks when prior evidence says they were not run, and blocks when adequate
  verification cannot be completed safely.
- Made preservation and backward-compatibility requirements explicit review criteria;
  passing focused tests is evidence, not proof that untested input classes are unchanged.
- Updated beginner-facing Windows install and daily-use commands to invoke PowerShell with
  `-NoProfile -ExecutionPolicy Bypass -File`, so they work under a Restricted execution policy.

## 3.1.5 - Exact-Scope Autonomous Recovery

- Fixed Windows Claude process execution to pass a real PowerShell argument array to
  `npx.cmd`, preserving multi-word prompts and the true child exit code while retaining
  bounded timeout and descendant-process cleanup.
- Hardened the Claude Implementer prompt against unrequested helper/runner files and
  invented verification when Bash is unavailable.
- Allowed Reviewer-`BLOCKED` corrections to resume only when Git status matches the
  approved `Changed Files` set exactly; arbitrary dirty trees still fail closed.
- Added review-only recovery for interrupted corrections with proven exact-scope content
  changes, and for non-zero exits that already produced a valid exact-scope review handoff.
  Recovery never approves implementation; Codex remains the independent Reviewer.
- Added regressions for resume, no-change failure, extra-file blocking, interrupted
  exact-scope recovery, valid-handoff/non-zero continuation, and Windows argv/exit behavior.
- Passed a clean real-user acceptance run in a new Node.js project: Hebrew task input,
  Codex Master -> Claude Code Implementer -> Codex Reviewer, six tests passing, exactly two
  approved files changed, `REVIEW_DONE / User`, commit gate ready, and no commit or release.

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
