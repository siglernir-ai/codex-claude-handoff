# Publication Copy

Replace only the demo URL placeholder after the recording is uploaded. Keep the
GitHub and skills.sh URLs unchanged.

## Social card alt text

Codex-Claude Handoff v3.3.1 public beta workflow: Codex routes and scopes, Claude
Code investigates or implements, Codex reviews independently, and the user approves
sensitive actions. The card notes 221 checks passed, Apache-2.0, and human-in-the-loop
operation.

## LinkedIn - English

I kept running into the same problem when using Codex and Claude Code on one
project: each tool could do useful work, but the handoff between them was informal.
Context was copied manually, ownership blurred, and the agent that implemented a
change could effectively grade its own work.

So I built **codex-claude-handoff**, an open-source Agent Skill that turns them
into an accountable engineering pair:

**One drives. One challenges. Neither ships alone.**

- Codex routes and scopes the task.
- Claude Code investigates or implements.
- Codex reviews the exact changed-file scope.
- The user approves commit, release, deployment, database, and secret-sensitive actions.

The handoff is only the transport. Unlike a session-summary handoff or a
multi-model answer comparison, both agents work on one live Git task with durable
state, explicit ownership, and a real rejection path. A blocked review can return
the approved scope to the Implementer for correction inside a bounded
turn/time/budget loop. Focused questions can also travel in both directions,
although those general dialogue states still require explicit turns today.

Those are the default assignments, not hard-coded identities. With explicit user
approval, Codex and Claude Code can exchange responsibilities while the
Implementer and Reviewer must remain different.

The tools coordinate through reviewable project-local files. There is no hosted
orchestrator, hidden chat bridge, or claim of full unattended autonomy. VS Code is
the recommended shared workspace, but this is not a VS Code extension.

v3.3.1 is now available as a public beta under Apache-2.0. The release passed 220
protocol checks, a clean public-tag install for both agents, and a bundled setup
whose health check returned PASS.

Demo: https://github.com/siglernir-ai/codex-claude-handoff/blob/main/launch/assets/codex-claude-handoff-live-demo.mp4

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

לכן בניתי את **codex-claude-handoff** - Skill בקוד פתוח שהופך את Codex ואת
Claude Code לצמד הנדסי עם חלוקת אחריות:

**אחד מוביל או מממש. השני מאתגר ובודק. אף אחד מהם לא משחרר לבד.**

- Codex מנתח, מגדיר ומנתב את המשימה.
- Claude Code חוקר או מממש.
- Codex בודק באופן עצמאי את היקף השינוי.
- המשתמש מאשר commit ופעולות רגישות נוספות.

ה-handoff הוא רק התשתית. בניגוד לסיכום שמועבר לסשן הבא או להשוואה בין שתי
תשובות, שני הכלים עובדים על אותה משימת Git עם מצב משותף, אחריות ברורה ויכולת
אמיתית לדחות את התוצאה. כאשר הביקורת חוסמת, העבודה יכולה לחזור ל-Implementer
לתיקון בתוך לולאה מוגבלת במספר תורות, זמן ותקציב. שאלות ממוקדות יכולות לעבור
בשני הכיוונים, אך מצבי הדו-שיח הכלליים עדיין דורשים כיום צעדים מפורשים.

אלה תפקידי ברירת המחדל, לא זהויות קשיחות. באישור מפורש אפשר להחליף אחריות בין
Codex ל-Claude Code, אך ה-Reviewer וה-Implementer חייבים להישאר כלים שונים.

התיאום נשמר בקבצים מקומיים וברורים בתוך הפרויקט. אין כאן שרת תיווך, גשר צ'אט נסתר
או הבטחה לאוטומציה מלאה ללא בקרה. סביבת העבודה המומלצת היא VS Code, אבל זה אינו
תוסף VS Code.

גרסה v3.3.1 זמינה כעת כ-Public Beta ברישיון Apache-2.0. היא עברה 221 בדיקות
פרוטוקול, התקנה נקייה מהגרסה הציבורית עבור שני הכלים ובדיקת תקינות שהסתיימה ב-PASS.

דמו: https://github.com/siglernir-ai/codex-claude-handoff/blob/main/launch/assets/codex-claude-handoff-live-demo.mp4

GitHub: https://github.com/siglernir-ai/codex-claude-handoff

התקנה:
`npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy`

אני מחפש מספר קטן של מפתחים שינסו משימה אחת קטנה ולא קריטית וידווחו דווקא על
השלב הראשון שהיה מבלבל או לא אמין. בשלב הזה ביקורת אמיתית חשובה יותר ממחמאות.

## Reddit - r/codex

### Title

I built an accountable Codex + Claude Code engineering workflow where neither agent ships alone

### Body

I use both Codex and Claude Code, but I did not want a workflow where context is
copied manually or the implementation agent approves its own change.

I built `codex-claude-handoff`, a project-local Agent Skill that makes the two
tools an accountable engineering pair with four explicit responsibilities:

1. Codex routes and scopes the request.
2. Claude Code investigates or implements.
3. Codex reviews the exact changed files and evidence.
4. The user approves commit and other sensitive actions.

The handoff is only the transport. The differentiator is one live task with durable
state, independent review, and a rejection/correction path rather than two
disconnected answers. It uses local Markdown state plus bounded CLI adapters. It is deliberately not full
unattended autonomy, and it is not a VS Code extension or hosted orchestration
service. The current v3.3.1 public beta passed 221 protocol checks and a fresh
public-tag install/doctor run.

Demo: https://github.com/siglernir-ai/codex-claude-handoff/blob/main/launch/assets/codex-claude-handoff-live-demo.mp4

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

v3.3.1 is a public beta, not a claim of full unattended autonomy. It passed 220
protocol checks and a clean install/doctor acceptance from the public tag.

Demo: https://github.com/siglernir-ai/codex-claude-handoff/blob/main/launch/assets/codex-claude-handoff-live-demo.mp4

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

Show HN: An accountable two-agent engineering workflow for Codex and Claude Code

### URL

https://github.com/siglernir-ai/codex-claude-handoff

### First comment

I built this after repeatedly losing context and role clarity while switching
between two coding agents in the same repository.

The handoff is only the transport. The project makes two coding agents an
accountable engineering pair: Codex routes, Claude Code implements, Codex
challenges and reviews, and the user approves sensitive actions. State is stored
in local Markdown files, the CLI turns are bounded and observable, and the
workflow fails closed on no progress, timeouts, unexpected files, or stale roles.

It is a v3.3.1 public beta under Apache-2.0. The most exercised environment is
Windows + VS Code, although Bash helpers are included. I am especially interested
in criticism of the architecture and in simpler ways to preserve independent
review without adding too much ceremony.

## X - four-post thread

1. I built an open-source Agent Skill that turns Codex and Claude Code into an accountable engineering pair: one drives, one challenges, and neither ships alone.

2. The flow is explicit: Codex routes -> Claude Code implements -> Codex reviews -> the user approves commit/release/deploy-sensitive actions. Shared state stays in local project files.

3. v3.3.1 is a supervised public beta, not full unattended autonomy. 221 protocol checks passed, plus a clean public install and health check. Demo: https://github.com/siglernir-ai/codex-claude-handoff/blob/main/launch/assets/codex-claude-handoff-live-demo.mp4

4. GitHub: https://github.com/siglernir-ai/codex-claude-handoff Install: `npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy` Critical feedback welcome.

## Direct message / WhatsApp

I published a public beta called `codex-claude-handoff`. It turns Codex and Claude
Code into an accountable engineering pair on one Git task: one drives or
implements, a different agent challenges and reviews, rejected work can return for
bounded correction, and the user approves sensitive actions. It is supervised
rather than fully autonomous.

The quickest useful test is one small non-critical task. Demo: https://github.com/siglernir-ai/codex-claude-handoff/blob/main/launch/assets/codex-claude-handoff-live-demo.mp4

GitHub: https://github.com/siglernir-ai/codex-claude-handoff

Install:
`npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy`

If you try it, please send me the first step that was confusing or failed.

## Discord - community post

### Title

Public beta: make Codex and Claude Code an accountable engineering pair

### Body

I have released `codex-claude-handoff`, an open-source Agent Skill for developers
who already use Codex and Claude Code in the same Git project.

Its core idea is simple: **one drives, one challenges, and neither ships alone.**

This is not just a summary handoff and not the same prompt sent to two models.
Both agents work on one durable task state. By default Codex routes and scopes,
Claude Code investigates or implements, and Codex independently reviews the exact
changed-file scope. A rejected result can return for bounded correction, while the
user keeps approval over commit, release, deployment, database, and secret actions.

Roles can be reassigned with explicit approval, but Reviewer and Implementer must
remain different. The current public beta is intended for supervised,
human-in-the-loop use, not unrestricted autonomous dialogue.

Demo:
https://github.com/siglernir-ai/codex-claude-handoff/blob/main/launch/assets/codex-claude-handoff-live-demo.mp4

GitHub:
https://github.com/siglernir-ai/codex-claude-handoff

Install:
`npx skills add siglernir-ai/codex-claude-handoff --skill codex-claude-handoff --agent codex claude-code --copy`

I would especially value one small non-critical test and a report of the first
confusing, slow, or unreliable step.
