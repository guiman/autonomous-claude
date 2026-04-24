#!/usr/bin/env bash
# install.sh — wire this repo into the paths autonomous-cycle expects, and
# render per-project LaunchAgent plists.
#
# Commands:
#   ./install.sh                     install scripts + seed config (idempotent)
#   ./install.sh schedule <slug>     render and load a LaunchAgent for <slug>
#   ./install.sh unschedule <slug>   unload and delete a LaunchAgent
#
# Environment overrides (also honoured by autonomous-cycle when set in
# ~/.config/autonomous-claude/env):
#   VAULT_ROOT      where project plans/logs live (default: $HOME/autonomous-vault)
#   LABEL_PREFIX    reverse-DNS prefix for LaunchAgent labels (default: autonomous)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the same env file autonomous-cycle uses, so VAULT_ROOT / LABEL_PREFIX
# set there (or in the shell) are honoured consistently across both tools.
ENV_FILE="$HOME/.config/autonomous-claude/env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

VAULT_ROOT="${VAULT_ROOT:-$HOME/autonomous-vault}"
LABEL_PREFIX="${LABEL_PREFIX:-autonomous}"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/autonomous-claude"
LOG_DIR="$HOME/.local/share/autonomous-claude"
LA_DIR="$HOME/Library/LaunchAgents"

say()  { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { echo "error: $*" >&2; exit 1; }

cmd_install() {
  local do_vault=1
  for arg in "$@"; do
    case "$arg" in
      --no-vault) do_vault=0 ;;
      *) die "unknown argument: $arg" ;;
    esac
  done

  step "ensure directories"
  for d in "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR"; do
    mkdir -p "$d"
    say "ok  $d"
  done

  step "link scripts into $BIN_DIR"
  for name in autonomous-cycle autonomous-watch; do
    link_symlink "$REPO_ROOT/bin/$name" "$BIN_DIR/$name"
  done

  step "seed $CONFIG_DIR/env"
  if [[ -f "$CONFIG_DIR/env" ]]; then
    say "exists — left untouched"
    if ! grep -qE 'CLAUDE_CODE_OAUTH_TOKEN="?sk-ant-' "$CONFIG_DIR/env" 2>/dev/null; then
      say "WARN: no token detected; run 'claude setup-token' and paste into this file"
    fi
  else
    cp "$REPO_ROOT/env.example" "$CONFIG_DIR/env"
    chmod 600 "$CONFIG_DIR/env"
    say "seeded from env.example (mode 600)"
    say "NEXT: run 'claude setup-token' and paste the token into $CONFIG_DIR/env"
  fi

  if (( do_vault )); then
    step "link framework files into vault: $VAULT_ROOT"
    mkdir -p "$VAULT_ROOT"
    for name in _runbook.md _wake_prompt.txt README.md; do
      link_symlink "$REPO_ROOT/$name" "$VAULT_ROOT/$name"
    done
    link_symlink "$REPO_ROOT/_templates" "$VAULT_ROOT/_templates"
  else
    step "skipping vault symlinks (--no-vault)"
  fi

  step "done"
  say "scripts:  $BIN_DIR/autonomous-cycle, $BIN_DIR/autonomous-watch"
  say "env:      $CONFIG_DIR/env"
  say "logs:     $LOG_DIR"
  say "vault:    $VAULT_ROOT"
  echo
  say "next: create a project under $VAULT_ROOT/<slug>/ with a PLAN.md"
  say "then: ./install.sh schedule <slug>"
}

cmd_schedule() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || die "usage: install.sh schedule <slug>"
  local plan="$VAULT_ROOT/$slug/PLAN.md"
  [[ -f "$plan" ]] || die "no PLAN.md at $plan — create the project first"

  local label="$LABEL_PREFIX.$slug"
  local plist="$LA_DIR/$label.plist"
  mkdir -p "$LA_DIR"

  step "render plist: $plist"
  sed -e "s|__SLUG__|$slug|g" \
      -e "s|__HOME__|$HOME|g" \
      -e "s|__LABEL_PFX__|$LABEL_PREFIX|g" \
      "$REPO_ROOT/launchd/autonomous-SLUG.plist.template" > "$plist"
  say "ok  $plist"

  step "load into launchd"
  local domain="gui/$(id -u)"
  launchctl bootout "$domain/$label" 2>/dev/null || true
  launchctl bootstrap "$domain" "$plist"
  say "ok  $label loaded (fires immediately, then every 5h)"
}

cmd_unschedule() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || die "usage: install.sh unschedule <slug>"
  local label="$LABEL_PREFIX.$slug"
  local plist="$LA_DIR/$label.plist"
  local domain="gui/$(id -u)"

  step "unload $label"
  launchctl bootout "$domain/$label" 2>/dev/null && say "ok  unloaded" || say "not loaded"

  if [[ -f "$plist" ]]; then
    rm "$plist"
    say "removed $plist"
  fi
}

link_symlink() {
  local src="$1" dst="$2"
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
    say "ok  $dst (already linked)"
  elif [[ -e "$dst" || -L "$dst" ]]; then
    say "replacing $dst"
    rm -rf "$dst"
    ln -s "$src" "$dst"
    say "ok  $dst"
  else
    ln -s "$src" "$dst"
    say "ok  $dst"
  fi
}

case "${1:-install}" in
  install)    shift $(( $# > 0 ? 1 : 0 )) 2>/dev/null; cmd_install "$@" ;;
  schedule)   shift; cmd_schedule "$@" ;;
  unschedule) shift; cmd_unschedule "$@" ;;
  -h|--help)  sed -n '2,14p' "$0" ;;
  *)          die "unknown command: $1 (try --help)" ;;
esac
