# Publication Copy

Replace only the demo URL placeholder after the recording is uploaded. Keep the
GitHub and skills.sh URLs unchanged.

## Social card alt text

Codex-Claude Handoff v3.3.0 public beta workflow: Codex routes and scopes, Claude
Code investigates or implements, Codex reviews independently, and the user approves
sensitive actions. The card notes 216 checks passed, Apache-2.0, and human-in-the-loop
operation.

## LinkedIn - English

I kept running into the same problem when using Codex and Claude Code on one
project: each tool could do useful work, but the handoff between them was informal.
Context was copied manually, ownership blurred, and the agent that implemented a
change could effectively grade its own work.

So I built **codex-claude-handoff**, an open-source Agent Skill for a supervised
multi-agent workflow:

- Codex routes and scopes the task.
- Claude Code investigates or implements.
- Codex reviews the exact changed-file scope.
- The user approves commit, release, deployment, database, and secret-sensitive actions.

The tools coordinate through reviewable project-local files. There is no hosted
orchestrator, hidden chat bridge, or claim of full unattended autonomy. VS Code is
the recommended shared workspace, but this is not a VS Code extension.

v3.3.0 is now available as a public beta under Apache-2.0. The release passed 216
protocol checks, a clean public-tag install for both agents, and a bundled setup
whose health check returned PASS.

Demo: [DEMO_URL]

GitHub: https://github.com/siglernir-ai/codex-claude-handoff

Install:
`npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy`

I am looking for a small number of developers willing to try one non-critical task
and report the first confusing or unreliable step. Critical feedback is more useful
than compliments at this stage.

#AgentSkills #Codex #ClaudeCode #OpenSource #AIAgents

## LinkedIn - Hebrew

כשעבדתי עם Codex ו-Claude Code על אותו פרויקט, חזרה שוב אותה בעיה: כל כלי ידע לבצע
עבודה טובה, אבל המעבר ביניהם נשאר ידני ולא מסודר. מעתיקים הקשר, לא תמיד ברור מי
אחראי לשלב הבא, ולעיתים הכלי שביצע את השינוי גם בודק את עצמו.

לכן בניתי את **codex-claude-handoff** - Skill בקוד פתוח לתהליך עבודה מפוקח:

- Codex מנתח, מגדיר ומנתב את המשימה.
- Claude Code חוקר או מממש.
- Codex בודק באופן עצמאי את היקף השינוי.
- המשתמש מאשר commit ופעולות רגישות נוספות.

התיאום נשמר בקבצים מקומיים וברורים בתוך הפרויקט. אין כאן שרת תיווך, גשר צ'אט נסתר
או הבטחה לאוטומציה מלאה ללא בקרה. סביבת העבודה המומלצת היא VS Code, אבל זה אינו
תוסף VS Code.

גרסה v3.3.0 זמינה כעת כ-Public Beta ברישיון Apache-2.0. היא עברה 216 בדיקות
פרוטוקול, התקנה נקייה מהגרסה הציבורית עבור שני הכלים ובדיקת תקינות שהסתיימה ב-PASS.

דמו: [DEMO_URL]

GitHub: https://github.com/siglernir-ai/codex-claude-handoff

התקנה:
`npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy`

אני מחפש מספר קטן של מפתחים שינסו משימה אחת קטנה ולא קריטית וידווחו דווקא על
השלב הראשון שהיה מבלבל או לא אמין. בשלב הזה ביקורת אמיתית חשובה יותר ממחמאות.

## Reddit - r/codex

### Title

I built a supervised Codex -> Claude Code -> Codex review Skill and need critical feedback

### Body

I use both Codex and Claude Code, but I did not want a workflow where context is
copied manually or the implementation agent approves its own change.

I built `codex-claude-handoff`, a project-local Agent Skill with four explicit
responsibilities:

1. Codex routes and scopes the request.
2. Claude Code investigates or implements.
3. Codex reviews the exact changed files and evidence.
4. The user approves commit and other sensitive actions.

It uses local Markdown state plus bounded CLI adapters. It is deliberately not full
unattended autonomy, and it is not a VS Code extension or hosted orchestration
service. The current v3.3.0 public beta passed 216 protocol checks and a fresh
public-tag install/doctor run.

Demo: [DEMO_URL]

Repo: https://github.com/siglernir-ai/codex-claude-handoff

Install:

```powershell
npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy
```

I would value feedback from anyone already combining these tools. In particular:
Is the review boundary useful, and what is the first part of setup or daily use
that feels unnecessarily complicated?

## Reddit - r/ClaudeCode

### Title

Public beta: a Claude Code Implementer workflow with independent Codex review

### Body

I built an open-source Agent Skill for a narrow multi-agent pattern: Claude Code is
the Implementer, while Codex acts as task router and independent Reviewer.

The workflow keeps its task, changed-file scope, evidence, and next actor in local
project files. Claude Code runs through a bounded turn with timeout and budget
limits. Codex reviews read-only. The user remains the approval point for commit,
push, release, deploy, database, and secret-sensitive work.

This is not intended to replace Claude Code's own planning, skills, or subagents.
It is a separation-of-duties layer for people who already use both products.

v3.3.0 is a public beta, not a claim of full unattended autonomy. It passed 216
protocol checks and a clean install/doctor acceptance from the public tag.

Demo: [DEMO_URL]

Repo: https://github.com/siglernir-ai/codex-claude-handoff

Install:

```powershell
npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy
```

I am looking for failure reports and workflow criticism, especially around first
setup, context continuity, and whether the independent review is worth the extra
structure.

## Hacker News - Show HN

### Submission title

Show HN: A supervised handoff protocol for Codex and Claude Code

### URL

https://github.com/siglernir-ai/codex-claude-handoff

### First comment

I built this after repeatedly losing context and role clarity while switching
between two coding agents in the same repository.

The project is intentionally conservative: Codex routes, Claude Code implements,
Codex reviews, and the user approves sensitive actions. State is stored in local
Markdown files, the CLI turns are bounded and observable, and the workflow fails
closed on no progress, timeouts, unexpected files, or stale roles.

It is a v3.3.0 public beta under Apache-2.0. The most exercised environment is
Windows + VS Code, although Bash helpers are included. I am especially interested
in criticism of the architecture and in simpler ways to preserve independent
review without adding too much ceremony.

## X - four-post thread

1. I built an open-source Agent Skill for one narrow problem: making Codex and Claude Code collaborate without letting the implementation agent approve its own work.

2. The flow is explicit: Codex routes -> Claude Code implements -> Codex reviews -> the user approves commit/release/deploy-sensitive actions. Shared state stays in local project files.

3. v3.3.0 is a supervised public beta, not full unattended autonomy. 216 protocol checks passed, plus a clean public install and health check. Demo: [DEMO_URL]

4. GitHub: https://github.com/siglernir-ai/codex-claude-handoff Install: `npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy` Critical feedback welcome.

## Direct message / WhatsApp

I published a small public beta called `codex-claude-handoff`. It gives Codex and
Claude Code separate roles in one project: Codex routes, Claude implements, Codex
reviews, and the user approves sensitive actions. It is supervised rather than
fully autonomous.

The quickest useful test is one small non-critical task. Demo: [DEMO_URL]

GitHub: https://github.com/siglernir-ai/codex-claude-handoff

Install:
`npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy`

If you try it, please send me the first step that was confusing or failed.
