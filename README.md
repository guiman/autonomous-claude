# Autonomous Claude

Scheduler + scaffolding that wakes Claude Code every 5 hours to pick up a project, do the next task on the plan, commit, and halt. Designed to continue work across usage-limit windows so long-running projects make progress even when you're asleep or AFK.

See [_runbook.md](_runbook.md) for the agent-side contract. This file is the operator-side documentation: how the system is wired, how to use it, and the macOS gotchas we hit setting it up.

**Source of truth**: `~/dev/autonomous-claude/` (this repo). The files in `~/.local/bin/` and inside the vault (`~/ai-documents/ai-projects/autonomous/{_runbook.md,_wake_prompt.txt,_templates,README.md}`) are symlinks back into this repo — edit here, every installation sees the change.

---

## Architecture

```
launchd (every 5h)
      │
      ▼
~/.local/bin/autonomous-cycle <slug>     bash wrapper
      │
      ├── source ~/.config/autonomous-claude/env     → OAuth token
      ├── parse <vault>/<slug>/PLAN.md               → Repo: line = cwd
      ├── trim session-log.md to last 5 entries       → rotate older to session-log.archive.md
      ├── cd <repo>
      └── claude --print --output-format stream-json --model claude-sonnet-4-6 \
                 --add-dir=<vault> "<wake_prompt>"
                 │
                 ▼
         stream-json events → ~/.local/share/autonomous-claude/<slug>-<ts>.log
```

**Two processes, two places:**

| Concern                | Lives at                                             |
| ---------------------- | ---------------------------------------------------- |
| Schedule (launchd job) | `~/Library/LaunchAgents/com.guiman.autonomous-<slug>.plist` |
| Runner                 | `~/.local/bin/autonomous-cycle`                      |
| Viewer                 | `~/.local/bin/autonomous-watch`                      |
| Secret                 | `~/.config/autonomous-claude/env` (mode 600)         |
| Vault (plan + logs)    | `~/ai-documents/ai-projects/autonomous/`             |
| Run logs               | `~/.local/share/autonomous-claude/`                  |
| Code                   | wherever the project's `PLAN.md` says (`Repo:` line) |

Nothing lives in iCloud or an Obsidian vault path — see [Mac gotchas](#mac-specific-gotchas).

---

## One-time setup

1. **Install the Claude Code CLI** and confirm it runs:
   ```sh
   /Users/guiman/.local/bin/claude --version
   ```

2. **Create a long-lived OAuth token** (the default token in your macOS Keychain is not reachable from `launchd`):
   ```sh
   /Users/guiman/.local/bin/claude setup-token
   ```
   Paste the `sk-ant-oat01-…` value into `~/.config/autonomous-claude/env`:
   ```sh
   mkdir -p ~/.config/autonomous-claude
   cat > ~/.config/autonomous-claude/env <<'EOF'
   export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."
   EOF
   chmod 600 ~/.config/autonomous-claude/env
   ```

3. **Vault scaffolding already exists** at `~/ai-documents/ai-projects/autonomous/`:
   - `_runbook.md` — contract the agent follows
   - `_wake_prompt.txt` — prompt template (uses `<SLUG>` substitution)
   - `_templates/` — PLAN, blocker, decision templates

4. **Scripts already installed**: `~/.local/bin/autonomous-cycle` and `~/.local/bin/autonomous-watch`.

---

## Starting a new project

### 1. Create the vault entry

```sh
SLUG=myproject
mkdir -p ~/ai-documents/ai-projects/autonomous/$SLUG/{blockers,decisions}
cp ~/ai-documents/ai-projects/autonomous/_templates/PLAN.md \
   ~/ai-documents/ai-projects/autonomous/$SLUG/PLAN.md
touch ~/ai-documents/ai-projects/autonomous/$SLUG/session-log.md
```

Edit `PLAN.md`. The `Repo:` line **must** be an absolute path to a git working tree — the cycle script greps it out and `cd`s there before firing Claude.

### 2. Prepare the code repo

```sh
cd /path/to/repo
git checkout -b autonomous/$SLUG
```

Drop a `.claude/settings.json` into the repo with an allowlist matching what the agent needs. Example (from the dino project):

```json
{
  "permissions": {
    "allow": [
      "Read(*)", "Write(*)", "Edit(*)",
      "Bash(git:*)",
      "mcp__Claude_Preview__*"
    ],
    "deny": [
      "Bash(git push:*)", "Bash(npm:*)", "Bash(curl:*)", "Bash(rm:*)",
      "WebFetch", "WebSearch"
    ]
  }
}
```

### 3. Create the LaunchAgent

Copy the dino plist as a template:

```sh
cp ~/Library/LaunchAgents/com.guiman.autonomous-dino.plist \
   ~/Library/LaunchAgents/com.guiman.autonomous-$SLUG.plist
```

Edit it — change `Label`, the script argument, and the two log paths to use the new slug. Then load it:

```sh
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.guiman.autonomous-$SLUG.plist
```

`RunAtLoad=true` means it fires immediately. First cycle will read `PLAN.md`, see `CURSOR: T1`, and start work.

---

## Daily operations

### Check status

```sh
# Is the scheduler loaded?
launchctl list | grep autonomous

# Is a fire running right now?
pgrep -afl 'bin/autonomous-cycle|bin/claude --print'

# What did the last cycle do?
ls -lt ~/.local/share/autonomous-claude/<slug>-*.log | head
```

### Watch a cycle live

```sh
autonomous-watch <slug>
```

Tails the most recent log and pretty-prints stream-json events:

- `💭 text` — assistant text
- `🔧 tool_name  args` — tool use
- `✓ result` — tool result
- `═══ done: success (cost $X, Xs) ═══` — final result event

### Unblock the agent

When a task requires a decision, the agent writes a file into `<slug>/blockers/` and halts (per [_runbook.md](_runbook.md)). To unblock:

1. Edit the blocker file, append a `## Resolution` section with your answer. Or delete the file if the answer is obvious.
2. Trigger the next cycle immediately (otherwise wait for the 5h interval):
   ```sh
   launchctl kickstart "gui/$(id -u)/com.guiman.autonomous-<slug>"
   # — or —
   /Users/guiman/.local/bin/autonomous-cycle <slug> &
   ```

The agent, on next wake, sees the empty `blockers/` (or a `## Resolution` section) and moves resolved files to `decisions/`.

### Fire manually outside the schedule

```sh
autonomous-cycle <slug>
```

Runs one cycle synchronously, output goes to a timestamped log under `~/.local/share/autonomous-claude/`.

### Stop the scheduler

```sh
launchctl bootout "gui/$(id -u)/com.guiman.autonomous-<slug>"
```

To permanently disable, also delete the plist. The `autonomous-cycle` script itself still works for manual fires.

### Review what the agent did

```sh
cd <repo>
git log autonomous/<slug> --oneline        # one commit per completed task
cat ~/ai-documents/ai-projects/autonomous/<slug>/session-log.md
cat ~/ai-documents/ai-projects/autonomous/<slug>/PLAN.md       # CURSOR shows current task
```

Review the branch, then decide whether to merge, rebase, or adjust the plan.

---

## Mac-specific gotchas

These all bit us during setup. Recording here so they aren't rediscovered.

### iCloud + TCC blocks both `cron` and `launchd`

If the vault lives inside `~/Library/Mobile Documents/iCloud~…/` (Obsidian's default iCloud location), macOS's Transparency/Consent/Control layer refuses read access to any non-UI process. You'll see errors like:

```
grep: …/PLAN.md: Operation not permitted
```

**Fix:** keep the vault under a plain path (`~/ai-documents/…`) outside iCloud. Either sync manually or use an Obsidian vault that lives outside iCloud and is synced some other way.

### Don't give `cron` Full Disk Access

`cron` fires from a shell unrelated to your user session — you'd have to grant `/usr/sbin/cron` Full Disk Access to reach any `~/Library` path, which is a broad security surface. `launchd` user-agents inherit your login session, respect TCC per-path, and can't run when nobody's logged in — which is what we actually want.

### `launchd` can't read keychain-stored OAuth tokens

`claude` normally authenticates via a token in your login keychain. `launchd` jobs run in a session that can't prompt for the login password, so keychain reads silently fail and `claude` appears to hang.

**Fix:** generate a long-lived token with `claude setup-token`, write it to `~/.config/autonomous-claude/env`, and have the runner `source` it. The runner does this:

```sh
ENV_FILE="$HOME/.config/autonomous-claude/env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
```

### `launchd` wake behavior (what was asked)

With `StartInterval` the job fires every N seconds *while the Mac is awake and you are logged in*. If the machine sleeps through multiple intervals, launchd runs the job **once** on wake to catch up — it does not replay every missed tick. For "fire at 3am every day" semantics, use `StartCalendarInterval` instead.

### `--add-dir PATH "<prompt>"` silently eats the prompt

The Claude CLI parser treats `--add-dir` as variadic (`--add-dir <directories...>`). If the next positional looks prompt-shaped, the parser greedily consumes it as the directory value, leaving no prompt. For short prompts you get:

```
Error: Input must be provided either through stdin or as a prompt argument when using --print
```

For long prompts with embedded newlines/slashes, the process hangs silently at 0% CPU — no output, no exit.

**Fix:** always use the `=` form so the value is unambiguous:

```sh
claude … "--add-dir=$VAULT_ROOT" "$PROMPT"
```

### Don't wrap `claude` in a pty via `script(1)`

`script -q /dev/null claude …` was tried to defeat node's stdout block-buffering when writing to a file. It makes things worse: the pty-allocated stdin changes `claude`'s I/O detection and the process never connects to the API.

**Fix:** don't wrap it. Redirect stdin explicitly: `< /dev/null`, and just redirect stdout to a file. For short prompts, node flushes on exit; for long-running cycles, the internal buffer fills and flushes regularly enough for live tailing via `autonomous-watch`.

### `pkill -f "claude"` also matches Claude Code itself

The currently running Claude Code session on your Mac matches `claude` too. Be specific:

```sh
pkill -f "bin/claude --print"   # only headless runs of this project
```

---

## Troubleshooting

| Symptom                                  | Likely cause / fix                                                                |
| ---------------------------------------- | --------------------------------------------------------------------------------- |
| Log stuck at 197 bytes (just the header) | Token missing → stdin never receives auth → no API call. Check `~/.config/autonomous-claude/env`. |
| Log stuck at 0 bytes                     | `--add-dir` ate the prompt. Confirm script uses `--add-dir=PATH` (equals form).   |
| `launchctl list` shows exit code nonzero | Last fire errored. Read the timestamped log under `~/.local/share/autonomous-claude/`. |
| Cycle exits immediately with rate-limit  | You're inside the 5h limit window. Wait for the reset shown in the stream output. |
| Agent halts on sight of a file you added | `T0 — HALT` trick in `PLAN.md`, or a stray blocker file. Check `blockers/`.       |
| Uncommitted changes after a cycle        | Cycle died mid-task (often token exhaustion). Per runbook, next wake's recovery step reconciles. |

---

## File reference

| Path                                                                 | Purpose                                        |
| -------------------------------------------------------------------- | ---------------------------------------------- |
| `~/.local/bin/autonomous-cycle`                                      | Wrapper: loads env, parses PLAN.md, fires claude |
| `~/.local/bin/autonomous-watch`                                      | Pretty tail of latest run log                  |
| `~/Library/LaunchAgents/com.guiman.autonomous-<slug>.plist`          | Per-project 5h scheduler                       |
| `~/.config/autonomous-claude/env`                                    | OAuth token (mode 600)                         |
| `~/ai-documents/ai-projects/autonomous/_runbook.md`                  | Agent contract                                 |
| `~/ai-documents/ai-projects/autonomous/_wake_prompt.txt`             | Prompt template with `<SLUG>`                  |
| `~/ai-documents/ai-projects/autonomous/_templates/`                  | PLAN, blocker, decision starters               |
| `~/ai-documents/ai-projects/autonomous/<slug>/PLAN.md`               | Project state + CURSOR                         |
| `~/ai-documents/ai-projects/autonomous/<slug>/blockers/`             | Open blockers — agent halts if any exist       |
| `~/ai-documents/ai-projects/autonomous/<slug>/decisions/`            | Resolved blockers, for posterity               |
| `~/ai-documents/ai-projects/autonomous/<slug>/session-log.md`        | Last 5 cycles (trimmed each run)               |
| `~/ai-documents/ai-projects/autonomous/<slug>/session-log.archive.md`| Older cycles rotated out                       |
| `~/.local/share/autonomous-claude/<slug>-<timestamp>.log`            | Per-fire stream-json log                       |
| `~/.local/share/autonomous-claude/launchd-<slug>.{out,err}.log`      | launchd's own stdio (usually empty)            |
