#!/usr/bin/env bash
set -euo pipefail

# Run serve.sh detached in its own tmux session, for SERVE_HOURS (default 48).
#
# Why tmux: a server started as a Claude Code background command is killed when
# the Bash tool's background limit runs out (at most 2 h). A tmux session is
# owned by the tmux server, not by the Claude session, so it lives until
# `timeout` ends it — or until `--stop`.
#
# Usage: start.sh [--stop]
#   (no args)  stage fresh builds and (re)start the server; prints its URLs
#   --stop     stop the server
# Env: SERVE_HOURS (default 48), APK_SERVE_SESSION (default apk-serve-<repo dir>)

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOURS="${SERVE_HOURS:-48}"
# One session per checkout: a worktree serves its own dist/ (see SKILL.md).
SESSION="${APK_SERVE_SESSION:-apk-serve-$(basename "$ROOT")}"

if ! command -v tmux >/dev/null; then
  echo "ERROR: tmux is not installed. Run scripts/serve.sh as a background"
  echo "command instead; it will stop when the Bash tool's limit (2 h) runs out."
  exit 2
fi

running() { tmux has-session -t "=$SESSION" 2>/dev/null; }

if [ "${1:-}" = "--stop" ]; then
  if running; then
    tmux kill-session -t "=$SESSION"
    echo "stopped: $SESSION"
  else
    echo "not running: $SESSION"
  fi
  exit 0
fi

# Restart rather than reuse: serve.sh stages new builds only when it starts.
if running; then
  tmux kill-session -t "=$SESSION"
  echo "restarting: $SESSION"
fi

tmux new-session -d -s "$SESSION" -c "$ROOT" "timeout ${HOURS}h bash '$HERE/serve.sh'"

# Wait for the server line (or an early exit) and show what serve.sh printed.
for _ in $(seq 1 20); do
  if ! running; then
    echo "ERROR: the server exited at once; run scripts/serve.sh directly to see why"
    exit 1
  fi
  if tmux capture-pane -p -t "=$SESSION:" | grep -q "^Serving HTTP"; then
    tmux capture-pane -p -S - -t "=$SESSION:" | sed '/^$/N;/^\n$/D' | grep -v "Ctrl+C"
    echo "Running in tmux session '$SESSION' for ${HOURS} h — stops at $(date -d "+${HOURS} hours" '+%Y-%m-%d %H:%M %Z')."
    echo "Stop early: bash .claude/skills/serve-apks/scripts/start.sh --stop"
    exit 0
  fi
  sleep 0.5
done

echo "ERROR: the server did not report ready within 10 s. Pane:"
tmux capture-pane -p -t "=$SESSION:"
exit 1
