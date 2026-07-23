# Discord Launch Copy

Use this for developer, AI coding, Codex, Claude Code, or Agent Skills
communities. Attach the MP4 natively when the channel permits it; otherwise attach
the poster and include the demo link.

## Title

Public beta: make Codex and Claude Code an accountable engineering pair

## Post

I have released `codex-claude-handoff`, an open-source Agent Skill for developers
who use Codex and Claude Code in the same Git project.

Its core idea is simple:

**One drives. One challenges. Neither ships alone.**

This is not just a summary handed to another session, and it is not the same prompt
sent to two models. Both agents work on one durable task state. By default Codex
routes and scopes, Claude Code investigates or implements, and Codex independently
reviews the exact changed-file scope. A rejected result can return for bounded
correction, while the user keeps approval over commit, release, deployment,
database, and secret actions.

Roles can be reassigned with explicit approval, but Reviewer and Implementer must
remain different. The current public beta is for supervised human-in-the-loop use,
not unrestricted autonomous dialogue.

Demo:
https://github.com/siglernir-ai/codex-claude-handoff/blob/main/launch/assets/codex-claude-handoff-live-demo.mp4

GitHub:
https://github.com/siglernir-ai/codex-claude-handoff

Install:

```powershell
npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy
```

The release passed 221 protocol checks and a clean public install/doctor
acceptance. I would especially value one small non-critical test and a report of
the first confusing, slow, or unreliable step.

## Attachments

1. `assets/codex-claude-handoff-live-demo.mp4`
2. `assets/codex-claude-handoff-live-demo-poster.png`
3. Use `assets/social-card.png` when the platform creates a separate link preview.

## Reply When Asked What Is Different

Most handoff tools preserve context for the next session. This Skill keeps one live
engineering task under explicit ownership, requires a different agent to review
the Implementer's work, can route rejected work back for bounded correction, and
stops at the user's real authority boundaries.
