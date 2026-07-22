# Launch Checklist

## Go / no-go gate

Launch broadly only when every item is true:

- [ ] `npx skills find codex-claude-handoff` returns the Skill.
- [ ] The skills.sh page displays the v3.3.0 first-use and safety content.
- [ ] The public GitHub release and both assets remain downloadable.
- [ ] The release ZIP matches its SHA-256 checksum.
- [ ] A fresh project install for Codex and Claude Code completes.
- [ ] Bundled setup completes and `doctor` returns `PASS`.
- [ ] The five-minute demo reaches `REVIEW_DONE / Waiting For: User`.
- [ ] The demo shows exactly one intended changed file and no commit.
- [ ] The 45-second edit contains no hidden retry or fabricated output.
- [ ] All post links and the install command are tested from a logged-out browser.

No-go conditions:

- skills.sh still presents materially stale setup or safety instructions.
- A clean install needs undocumented manual file copying.
- The demo requires manual repair that is not shown.
- A security scanner reports an unexplained high-severity finding.
- The repository has uncommitted release changes.

## Publication sequence

### Day 0

- Publish the English LinkedIn post with the social card and demo.
- Send the direct message to no more than five relevant developers.
- Stay available to answer setup questions for at least two hours.

### Day 1 or 2

- Publish the `r/codex` version if LinkedIn reveals no critical onboarding issue.
- Do not reuse the LinkedIn introduction verbatim.
- Link to the repository, not to a URL shortener.

### Day 3 to 5

- Fix the first repeated onboarding problem.
- Add the answer to the FAQ or Quick Start.
- Publish the Claude-specific post only if it adds a distinct discussion.

### After two external completed workflows

- Decide whether Show HN is justified.
- Publish a short results note: what worked, what failed, and what changed.

## Metrics that matter

Track these for 30 days:

- Unique external users who installed the Skill.
- Users who completed setup and received `doctor PASS`.
- Users who completed one full task through review.
- Median time from install to first successful task.
- Number and severity of setup failures.
- Number of users who returned for a second task.
- Actionable issues or pull requests from outside the author account.

Do not optimize primarily for impressions, likes, or GitHub stars. A useful beta
signal is five external installs, two completed supervised workflows, and no open
critical safety or data-loss problem.

## Response policy

- Acknowledge reproducible critical issues quickly and pause promotion if needed.
- Ask for version, OS, handoff state, exact safe output, and clean-tree status.
- Never ask a reporter to publish private code, tokens, or full environment dumps.
- Label confirmed limitations honestly instead of arguing with the user.
- Convert repeated confusion into documentation or product changes.

## Launch record

Record the publication date, post URLs, demo URL, first five testers, and any paused
promotion decision here after launch. Keep personal contact details outside Git.
