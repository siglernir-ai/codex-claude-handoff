# Launch Kit

This directory contains publication material for `codex-claude-handoff` v3.3.0.
It is separate from the installable Skill and does not change runtime behavior.

## Launch position

Use one sentence consistently:

> A supervised, project-local workflow in which Codex routes, Claude Code
> implements, Codex reviews, and the user approves sensitive actions.

Do not describe the project as fully autonomous, a hidden chat bridge, or a native
VS Code extension.

## Package contents

- `DEMO.md` - the reproducible five-minute demonstration and recording storyboard.
- `POSTS.md` - publication copy for LinkedIn, Reddit, Hacker News, X, and direct sharing.
- `FAQ.md` - concise answers to expected technical and trust questions.
- `CHECKLIST.md` - go/no-go gates, publication order, and useful launch metrics.
- `assets/social-card.html` - editable source for the social image.
- `assets/social-card.png` - rendered 1200 x 630 launch image.

## Publication gate

Do not begin the broad launch until both of these checks pass:

```powershell
npx skills find codex-claude-handoff
```

The skills.sh page must also show the v3.3.0 Skill text rather than the older
"Codex Adapter" copy:

https://www.skills.sh/siglernir-ai/codex-claude-handoff/codex-claude-handoff

Direct GitHub sharing and small invited pilots are safe before that index refresh.

## Recommended order

1. Record the demo from `DEMO.md` without editing out failures.
2. Publish the LinkedIn post with the social card and demo.
3. Publish one tailored Reddit post, starting with `r/codex`.
4. Wait 48-72 hours, answer questions, and fix onboarding friction.
5. Publish to `r/ClaudeCode` only with a Claude-specific framing.
6. Consider Show HN after at least two external users complete the workflow.

Avoid simultaneous identical cross-posts. Early replies and issue handling matter
more than raw impression count.
