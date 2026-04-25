# Autonomous Claude

Scheduler + scaffolding that wakes Claude Code every hour to pick up a project, do the next task on the plan, commit, and halt. Designed to continue work across usage-limit windows so long-running projects make progress even when you're asleep or AFK — the agent retries hourly and resumes as soon as the 5h Anthropic limit window resets.

- [PATTERN.md](PATTERN.md) — the underlying pattern, transport-agnostic. Read this first if you want to understand or port the workflow.
- [_runbook.md](_runbook.md) — the contract the agent re-reads each wake.
- This file (README) — how to install and run *this* macOS implementation.

Currently macOS only (the scheduler uses `launchd`). Linux equivalent would be a `systemd --user` timer — not implemented here.

---

## Architecture

```
launchd (every 1h)
      │
      ▼
~/.local/bin/autonomous-cycle <slug>              bash wrapper
      │
      ├── source ~/.config/autonomous-claude/env       → OAuth token (+ optional overrides)
      ├── parse $VAULT_ROOT/<slug>/PLAN.md             → Repo: line = cwd for the agent
      ├── trim session-log.md to last 5 entries         → rotate older to session-log.archive.md
      ├── cd <repo>
      └── claude --print --output-format stream-json --model claude-sonnet-4-6 \
                 --add-dir=$VAULT_ROOT "<wake_prompt>"
                 │
                 ▼
         stream-json events → ~/.local/share/autonomous-claude/<slug>-<ts>.log
```

**What lives where:**

| Concern                | Location                                                 |
| ---------------------- | -------------------------------------------------------- |
| Scheduler (launchd)    | `~/Library/LaunchAgents/<prefix>.<slug>.plist`           |
| Scripts                | `~/.local/bin/autonomous-cycle`, `~/.local/bin/autonomous-watch` |
| Secret                 | `~/.config/autonomous-claude/env` (mode 600, gitignored) |
| Vault (plans + runbook)| `$VAULT_ROOT` (default `~/autonomous-vault`)             |
| Run logs               | `~/.local/share/autonomous-claude/`                      |
| Code                   | wherever each project's `PLAN.md` says (`Repo:` line)    |

Nothing lives in iCloud or an Obsidian vault path — see [Mac gotchas](#mac-specific-gotchas) for why.

---

## One-time setup

### 1. Install the Claude Code CLI

Follow the Claude Code install docs. Confirm it runs: `claude --version`.

### 2. Clone this repo and run `install.sh`

```sh
git clone <this-repo-url> ~/dev/autonomous-claude     # or anywhere you like
cd ~/dev/autonomous-claude
./install.sh
```

Defaults: vault at `~/autonomous-vault`, LaunchAgent label prefix `autonomous`. Override either:

```sh
VAULT_ROOT="$HOME/mystuff/autonomous" LABEL_PREFIX="com.you.autonomous" ./install.sh
```

The installer is idempotent. It:
- creates `~/.local/bin`, `~/.config/autonomous-claude`, `~/.local/share/autonomous-claude`
- symlinks `autonomous-cycle` and `autonomous-watch` into `~/.local/bin`
- seeds `~/.config/autonomous-claude/env` from `env.example` (never overwrites an existing file)
- symlinks the framework files (`_runbook.md`, `_wake_prompt.txt`, `README.md`, `_templates/`) into the vault

### 3. Generate a long-lived OAuth token

The default token in your macOS Keychain is not reachable from `launchd`. You need a long-lived one:

```sh
claude setup-token
```

Paste the `sk-ant-oat01-…` value into `~/.config/autonomous-claude/env`:

```sh
export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."

# Optional overrides (see env.example):
# export VAULT_ROOT="$HOME/ai-documents/ai-projects/autonomous"
# export CLAUDE_BIN="$HOME/.local/bin/claude"
```

Keep the file at mode 600.

---

## Starting a new project

### 1. Create the vault entry

```sh
SLUG=myproject
VAULT=${VAULT_ROOT:-$HOME/autonomous-vault}
mkdir -p "$VAULT/$SLUG"/{blockers,decisions}
cp "$VAULT/_templates/PLAN.md" "$VAULT/$SLUG/PLAN.md"
touch "$VAULT/$SLUG/session-log.md"
```

Edit `$VAULT/$SLUG/PLAN.md`. The `Repo:` line **must** be an absolute path to a git working tree — the cycle script greps it out and `cd`s there before firing Claude.

### 2. Prepare the code repo

```sh
cd /path/to/repo
git checkout -b autonomous/$SLUG
```

Drop a `.claude/settings.json` into the repo with an allowlist matching what the agent needs. Example:

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

### 3. Schedule it

```sh
./install.sh schedule $SLUG
```

Renders the LaunchAgent plist from the template, substituting `__SLUG__`, `__HOME__`, and the label prefix. Loads it via `launchctl bootstrap`. `RunAtLoad=true` fires a cycle immediately.

---

## Daily operations

### Status

```sh
launchctl list | grep autonomous                         # is any scheduler loaded?
pgrep -afl 'bin/autonomous-cycle|bin/claude --print'     # is a fire running?
ls -lt ~/.local/share/autonomous-claude/<slug>-*.log | head   # recent fires
```

### Watch a cycle live

```sh
autonomous-watch <slug>
```

Tails the newest log and pretty-prints stream-json events (`💭 text`, `🔧 tool_name args`, `✓ result`, `═══ done ═══`).

### Unblock the agent

When a task requires a decision, the agent writes a file into `<slug>/blockers/` and halts. To unblock:

1. Edit the blocker file, append a `## Resolution` section with your answer — or delete the file if the answer is obvious.
2. Fire the next cycle immediately (otherwise wait for the next hourly interval):
   ```sh
   launchctl kickstart "gui/$(id -u)/<prefix>.<slug>"
   # or
   autonomous-cycle <slug> &
   ```

### Fire manually

```sh
autonomous-cycle <slug>
```

Runs one cycle synchronously. Useful for testing changes to the runbook or prompt.

### Stop scheduling a project

```sh
./install.sh unschedule <slug>
```

Unloads the LaunchAgent and removes its plist. `autonomous-cycle <slug>` still works for manual fires.

### Review what the agent did

```sh
cd <repo-for-slug>
git log autonomous/<slug> --oneline     # one commit per completed task
cat $VAULT_ROOT/<slug>/session-log.md   # narrative history (last 5 cycles)
cat $VAULT_ROOT/<slug>/PLAN.md          # CURSOR shows current task
```

---

## Mac-specific gotchas

Recorded here so nobody rediscovers them.

### iCloud + TCC blocks both `cron` and `launchd`

If the vault lives inside `~/Library/Mobile Documents/iCloud~…/` (Obsidian's default iCloud location), macOS's Transparency/Consent/Control layer refuses read access to any non-UI process. You'll see errors like:

```
grep: …/PLAN.md: Operation not permitted
```

**Fix:** keep the vault under a plain path (e.g. `~/autonomous-vault`) outside iCloud. If you want Obsidian to see it, use an Obsidian vault that lives outside iCloud or sync it some other way.

### Don't give `cron` Full Disk Access

`cron` fires from a shell unrelated to your user session — you'd have to grant `/usr/sbin/cron` Full Disk Access to reach anything under `~/Library`, which is a broad security surface. `launchd` user-agents inherit your login session, respect TCC per-path, and can't run when nobody's logged in — which is what we actually want.

### `launchd` can't read keychain-stored OAuth tokens

`claude` normally authenticates via a token in your login keychain. `launchd` jobs run in a session that can't prompt for the login password, so keychain reads silently fail and `claude` appears to hang.

**Fix:** generate a long-lived token with `claude setup-token`, write it to `~/.config/autonomous-claude/env`, and have the runner `source` it. `autonomous-cycle` does this automatically.

### `launchd` wake semantics

With `StartInterval` the job fires every N seconds *while the Mac is awake and you are logged in*. If the machine sleeps through multiple intervals, `launchd` runs the job **once** on wake to catch up — it does not replay every missed tick. For "fire at 3am every day" semantics, use `StartCalendarInterval` instead.

### `--add-dir PATH "<prompt>"` silently eats the prompt

The Claude CLI parser treats `--add-dir` as variadic (`--add-dir <directories...>`). If the next positional looks prompt-shaped, the parser greedily consumes it as the directory value, leaving no prompt. Short prompts error with:

```
Error: Input must be provided either through stdin or as a prompt argument when using --print
```

Long prompts with embedded newlines or slashes hang silently at 0% CPU — no output, no exit.

**Fix:** always use the `=` form so the value is unambiguous:

```sh
claude … "--add-dir=$VAULT_ROOT" "$PROMPT"
```

### Don't wrap `claude` in a pty via `script(1)`

`script -q /dev/null claude …` is a natural instinct to defeat node's stdout block-buffering when writing to a file. It makes things worse: the pty-allocated stdin changes `claude`'s I/O detection and the process never connects to the API.

**Fix:** don't wrap. Use `< /dev/null` for stdin, plain file redirection for stdout. For short prompts node flushes on exit; for longer cycles the internal buffer fills and flushes regularly enough for live tailing.

### `pkill -f "claude"` also matches Claude Code itself

If you're running Claude Code interactively on the same machine, it also matches `claude`. Be specific:

```sh
pkill -f "bin/claude --print"   # only headless runs
```

---

## Troubleshooting

| Symptom                                  | Likely cause / fix                                                                |
| ---------------------------------------- | --------------------------------------------------------------------------------- |
| Log stuck at ~200 bytes (just the header) | Token missing → no API call. Check `~/.config/autonomous-claude/env`.            |
| Log stuck at 0 bytes                     | `--add-dir` ate the prompt. Confirm script uses `--add-dir=PATH` (equals form).  |
| `launchctl list` shows exit code nonzero | Last fire errored. Read the timestamped log under `~/.local/share/autonomous-claude/`. |
| Cycle exits immediately with rate-limit  | You're inside the 5h limit window. Wait for the reset shown in the stream output. |
| Agent halts on sight of a file you added | `T0 — HALT` trick in `PLAN.md`, or a stray blocker file. Check `blockers/`.       |
| Uncommitted changes in the repo after a cycle | Cycle died mid-task (often token exhaustion). Per runbook, next cycle's recovery step reconciles. |

---

## Repo layout

```
autonomous-claude/
├── README.md                          operator docs (this file)
├── _runbook.md                        agent contract
├── _wake_prompt.txt                   prompt template with <SLUG> substitution
├── _templates/                        PLAN.md / blocker.md / decision.md starters
├── bin/
│   ├── autonomous-cycle              fires one cycle for a given slug
│   └── autonomous-watch              pretty-prints the latest stream-json log
├── launchd/
│   └── autonomous-SLUG.plist.template rendered by install.sh
├── install.sh                         install / schedule / unschedule
├── env.example                        template for ~/.config/autonomous-claude/env
└── .gitignore                         blocks env/*.env/*.token/*.secret
```

Nothing in this repo contains secrets. `.gitignore` blocks the obvious patterns regardless.
