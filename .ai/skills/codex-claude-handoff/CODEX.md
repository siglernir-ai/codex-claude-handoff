# Codex-Claude Handoff - Codex Entry Pointer

You are Codex. Your behavior in this protocol is determined by your assigned **role**,
not by your name or by this filename.

1. Read `.ai/roles/ROLE_ASSIGNMENT.md` to find your current role(s).
2. By default Codex holds the **Master** and **Reviewer** roles -> read the `Start of Session` and `Context Budget` sections of `MASTER.md` in this folder, and look up any other section by its heading when the turn needs that rule.
3. If you have been reassigned to the **Implementer** role -> follow `IMPLEMENTER.md` in this folder.
4. Take the current state from `NEXT_TURN.md` and the `AI_HANDOFF.md` sections it maps. Look up `SKILL.md` (the shared protocol index) by section only when you need it. At the start of every turn, compare the derived Task Actors in AI_HANDOFF.md with ROLE_ASSIGNMENT.md; drift or Reviewer==Implementer is a fail-closed stop.

The binding in `.ai/roles/ROLE_ASSIGNMENT.md` is authoritative. Do not assume your role from this filename.
