# Contributing

Thank you for testing `codex-claude-handoff`. The most useful early contributions
are reproducible failures, onboarding improvements, focused tests, and corrections
to claims that are unclear or too broad.

## Before opening an issue

1. Confirm the installed version with `.ai/skills/codex-claude-handoff/VERSION`.
2. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\handoff.ps1 doctor`.
3. Capture `handoff.ps1 work` and `git status --short --branch`.
4. Remove secrets, private code, customer information, and personal paths that are
   not needed to reproduce the problem.
5. Use the Bug Report or Pilot Feedback form.

Do not post suspected vulnerabilities or exposed credentials in a public issue.
Read `SECURITY.md` first.

## Pull requests

- Keep one behavioral change per pull request.
- Preserve fail-closed approval boundaries.
- Do not hard-code a permanent model name where a capability policy is sufficient.
- Add focused tests for protocol or installer behavior.
- Update user-facing documentation when commands, states, or safety behavior change.
- Do not commit local coordination or evidence files such as `AI_HANDOFF.md`,
  `NEXT_TURN.md`, or agent capture JSONL.

Run the PowerShell harness on Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\protocol-tests.ps1
```

When changing templates or the standalone public Skill:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-skill-package.ps1
git diff --check
```

The canonical and template copies must remain synchronized. The Codex and Claude
Code standalone Skill payloads must remain byte-identical.

## Review expectations

A pull request is not ready merely because current tests pass. Review also checks
scope preservation, backward compatibility, approval boundaries, documentation,
and whether verification claims match commands that actually ran.
