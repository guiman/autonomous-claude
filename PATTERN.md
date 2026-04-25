# The Autonomous Cycle Pattern

A way to keep a coding agent on-task across session boundaries — usage caps, crashes, sleep cycles — without losing progress or repeating work.

This document describes the *pattern*. The bash scripts and launchd plist in this repo are *one* implementation. The pattern itself ports cleanly to GitHub Actions, hosted scheduled agents, systemd timers, or any other "wake an agent on a schedule" runtime — see [§ Porting](#porting).

---

## Problem

Coding agents on hosted plans (Claude, ChatGPT, etc.) hit usage limits. Sessions end. Laptops sleep. Long-running work — refactors, multi-feature builds, large migrations — that takes longer than one session window dies at the boundary, or worse, leaves the repo in a half-edited state with no clean way to resume.

The naive fix is "just open another session and keep going." This fails because:
- The new session has no memory of the previous one
- The agent has to re-derive what was already decided
- Mid-cycle deaths leave the working tree in a state inconsistent with whatever the user remembers
- A user-facing decision request from cycle N is invisible to cycle N+1

## Idea

**Externalize the agent's state to disk in a format both human and agent can read and edit.** Treat each wake as a fresh, amnesiac agent that:

1. Loads its state from disk
2. Does one bounded unit of work
3. Persists its new state
4. Exits

The runtime that fires the agent is dumb — it just runs the same prompt every interval. All intelligence lives in the state files and the contract that governs how to read and write them.

## Invariants

Five things must always hold. If any can be violated, recovery semantics break.

1. **One source of truth for "what's next."** A single, named pointer (`CURSOR`) into an enumerated list of tasks. The agent never improvises which task to do; it reads the cursor.

2. **One atomic unit of work per cycle.** One task → one commit → one session-log entry. Atomicity matters because the recovery protocol diffs git state against plan state to detect mid-cycle deaths.

3. **Halt beats improvise.** When the agent encounters a decision outside the scope it was given, it writes a blocker file and stops. It does not guess. The blocker file is the entire interface for human-in-the-loop input.

4. **Recovery is mechanical, not interpretive.** A fresh agent starting a cycle can determine the true state by inspecting `git status`, `git log`, and the plan — no LLM judgement required. (See [§ Failure modes](#failure-modes).)

5. **The contract is written, not learned.** The rules the agent follows live in a file (`_runbook.md`) the agent re-reads at the start of every cycle. Changing the rules means editing the file, not retraining.

## Artifacts

The pattern uses six artifacts. Names are conventional; meanings are not.

| Artifact | Role |
| --- | --- |
| `PLAN.md` | The machine-actionable plan: goal, guardrails, ordered task list, current `CURSOR`. The control panel. |
| `_runbook.md` | The contract the agent re-reads each wake. Read-only to the agent; edited only by the user. |
| `blockers/` | One file per open blocker. The agent halts on sight of any file here. The interface for "I need a human." |
| `decisions/` | Resolved blockers, moved here for posterity. Append-only. |
| `session-log.md` | Append-only narrative of what happened each cycle. Continuity between cycles. |
| a code repo | The actual artifact being built. Branch-per-project keeps user and agent on separate review surfaces. |

The split between `PLAN.md` (state) and `_runbook.md` (rules) is load-bearing: it lets the user edit either independently without confusing the agent.

## Wake protocol

Each cycle is a five-step state machine. The runbook expresses these as imperatives the agent follows literally.

```
   ┌─ READ ──────┐
   │  - runbook  │      load contract
   │  - PLAN     │      load state
   │  - blockers │      check halt signal
   │  - last log │      load continuity context
   └──────┬──────┘
          │
          ▼
   ┌─ RECONCILE ─┐      compare git HEAD + working tree to PLAN's CURSOR.
   │             │      Detect mid-cycle death from previous run.
   └──────┬──────┘      Either complete + commit, or revert.
          │
          ▼
   ┌─ ACT ───────┐      do one task starting from CURSOR.
   └──────┬──────┘      stop conditions are explicit (see runbook).
          │
          ▼
   ┌─ COMMIT ────┐      git commit "T<n>: <summary>"
   └──────┬──────┘      one commit per task, no exceptions.
          │
          ▼
   ┌─ PERSIST ───┐      tick PLAN checkbox, advance CURSOR,
   └─────────────┘      append session-log entry.
```

The agent exits cleanly after PERSIST. No long-running state. The next wake starts again at READ.

## Failure modes

Each failure mode the pattern handles, and which artifact handles it.

| Failure | What's true on disk | How the next cycle recovers |
| --- | --- | --- |
| Usage cap kills mid-task | Working tree dirty, no new commit, PLAN unchanged | RECONCILE step: complete + commit if work is sound, else `git restore` and re-do |
| Crash after commit, before PLAN tick | Latest commit is `T<n>` but PLAN shows `T<n>` unchecked | RECONCILE: tick the box, advance CURSOR, log the recovery — don't redo the task |
| Crash after session-log entry, before commit | Log claims task done, no matching commit | Treat task as not done, redo — the log was lying |
| Ambiguous decision in middle of task | A new file in `blockers/`, no commit | Next cycle halts on sight of the blocker; user resolves; cycle after that proceeds |
| User changes the plan between cycles | New PLAN.md content | Next cycle reads fresh PLAN, starts at whatever CURSOR now points at |
| User adds a `T0 — HALT` task | Halt task at top of PLAN | Agent halts on sight of T0, doesn't begin work |
| All tasks complete | All boxes ticked, CURSOR past end | Agent marks plan DONE and disables its own schedule |

The first three are why "one commit per task" is load-bearing. Without atomic per-task commits, you can't tell which side of any boundary the previous cycle died on.

## Load-bearing vs. style

What you can change without breaking the pattern, and what you can't.

| Concern | Load-bearing | Style — change freely |
| --- | --- | --- |
| Plan format | Has a single named `CURSOR` pointing at the next task | Markdown vs JSON vs YAML |
| Task delimitation | Task ↔ commit ↔ log entry are 1:1:1 | Task naming (`T1`, `task-001`, `feat/login`) |
| Blockers | Separate filesystem object the agent halts on | Whether they're files, issues, or labels |
| Runbook | Re-read every wake; never read by the user during a cycle | Length, prose style, table of contents |
| Recovery signal | Comparison of repo state to plan state is mechanical | Specific commands used (`git status`, `git log`) |
| Branch model | User and agent commits don't interleave on the user's review surface | Whether that's branch-per-project, fork, or PR-per-task |
| Schedule cadence | Fast enough to retry after rate-limit reset; slow enough to not waste fires | 1h, 5h, hourly with jitter — your call |

If a future "improvement" weakens any item in the load-bearing column, the pattern stops working. If you change anything in the style column, nobody notices.

## Porting

The pattern is independent of how the agent is woken up. Implementations:

| Runtime | What changes |
| --- | --- |
| **macOS launchd** (this repo) | A per-project `.plist` with `StartInterval`. Script reads token from `~/.config`, calls the CLI. Best for: local laptop, private repos, MCP-driven local tools. |
| **systemd user timer** (Linux) | A `.timer` + `.service` pair. Same script. Same constraints — needs the user logged in. |
| **GitHub Actions cron** | `schedule: cron: "0 */1 * * *"` workflow that checks out the repo, runs `claude -p` against the PLAN, commits and pushes on its own branch. Best for: team-visible, no laptop dependency. State files live in the repo. |
| **Anthropic-hosted scheduled agents** (`mcp__scheduled-tasks__create_scheduled_task`) | The hosted runtime fires the agent on a cron. State files live wherever the agent's tools can reach (likely a connected git remote or MCP-backed filesystem). Best for: laptop-independent, no infra. |
| **`/loop` skill** | Manual interactive loop within an open session. Useful for development of the pattern itself, not autonomous use. |

In all cases the runbook, plan, blockers, and session log are unchanged. Only the wake-up mechanism and how the agent reaches its tools differ.

## When *not* to use this pattern

- **Task fits in one session window.** Just do it interactively; the overhead of plan files isn't worth it.
- **The plan can't be enumerated in advance.** If you can't write down 5–20 concrete tasks, the agent can't follow a CURSOR. Spend the first session designing the plan with the agent before scheduling cycles.
- **Tight feedback loops needed.** If you want to redirect the agent every 30 seconds, you want a session, not a scheduled cycle.
- **Trust hasn't been established yet.** Run a few cycles interactively, watching the log, before letting it run unattended overnight.

## Minimum viable implementation

Stripped to its essence, the pattern needs:

1. A directory with a `PLAN.md` (with `CURSOR`) and `_runbook.md`.
2. A way to fire an agent on an interval, with stdin/stdout going somewhere persistent.
3. A prompt that tells the agent: read these files in this order, do one task per the runbook, exit.
4. A git repo where the agent can commit one task per cycle.

Everything else — `blockers/`, `decisions/`, log rotation, `--add-dir` flags, token files — is mechanics. The pattern is the four items above.
