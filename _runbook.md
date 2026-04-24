# Autonomous Work Runbook

This folder holds projects Claude works on in scheduled cycles between our conversations. Both the user and the agent read this runbook — it is the contract.

## Folder layout

- `_runbook.md` — this file
- `_templates/` — copy these when starting a new project
- `<project-slug>/`
	- `PLAN.md` — live state, the control panel
	- `decisions/` — one file per decision, append-only
	- `blockers/` — one file per open blocker; moved to `decisions/` when resolved
	- `session-log.md` — recent wake-by-wake history (trimmed to last ~5 entries by the cycle script)
	- `session-log.archive.md` — older entries rotated out of `session-log.md`; read only if you need deeper history

## Agent: read order on wake

1. Read the project's `PLAN.md` top to bottom.
2. List `blockers/`. If anything is there, halt — update `session-log.md` noting why.
3. Read the last entry in `session-log.md` for continuity.
4. **Recovery check.** A prior cycle may have died mid-task (e.g. hit the token limit). `cd` to the repo and the project's branch. Run `git status` and `git log --oneline`. Reconcile:
	- **Uncommitted changes present** → either complete the in-progress task and commit it, or `git restore`/`git reset --hard` back to `HEAD`. Do not begin new work on a dirty tree.
	- **Latest commit is `T<n>: …` but PLAN.md shows T<n> unchecked or CURSOR still on T<n>** → tick the box, move CURSOR, and append a session-log entry noting recovery from a mid-cycle halt after `T<n>`. Do not redo the task.
	- **Session log's last entry claims a task done but no matching commit exists** → the commit never landed; treat the task as not done and resume normally.
5. Start work at the CURSOR in `PLAN.md`.

## Agent: write rules

- **Never edit**: `Goal`, `Guardrails`, `_runbook.md`. The user owns those.
- **Always edit**: task checkboxes, CURSOR position, session log.
- One commit per task. Message format: `T<n>: <one-line summary>`.
- After each task: tick box → move CURSOR → append session-log entry → commit.
- Creating a blocker: write `blockers/<YYYY-MM-DD>-<slug>.md` from template, then halt.
- Resolving a blocker yourself (user edited it, or further work made it moot): move the file to `decisions/` — preserves history, never delete.

## Agent: stop conditions

- Task needs a decision outside Guardrails → blocker → halt.
- Runtime/test check fails twice after genuine fix attempts → blocker with diagnosis → halt.
- All tasks complete → mark plan `DONE` → disable the schedule → notify user.
- Approaching token/usage limits → finish current task or revert cleanly, commit, log. Never stop mid-edit.

## User: editing conventions

- Edit `PLAN.md` between cycles freely — add tasks, tighten guardrails, reorder.
- Resolve blockers by (a) adding a `## Resolution` section in the blocker file, or (b) deleting it if the answer is obvious from context. Agent handles the move to `decisions/`.
- Hard-stop the agent: add `- [ ] T0 — HALT` at the top of Tasks. Agent halts on sight.

## Commit & branch conventions (code repo)

- Branch per project: `autonomous/<project-slug>`.
- Agent **never pushes**. User pulls/reviews between cycles.
- One commit per task. Agent may rebase/reset within its current cycle's own commits, never across commits from prior cycles — those are the user's review surface.
