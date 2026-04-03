#!/usr/bin/env bash
# shell-integration.sh -- Wrapper functions for Claude Code and OpenCode
# Source this file from your .zshrc or .bashrc:
#   source /path/to/tmux-agents/scripts/shell-integration.sh

TMUX_AGENTS_SERVER="${TMUX_AGENTS_SERVER:-http://127.0.0.1:7077}"

# cc -- Launch Claude Code with session name and registration
#
# Usage:
#   cc <name> [claude args...]   Launch with name
#   cc [claude args...]          Prompt for name interactively
#   cc -r <name>                 Resume a named session
#   cc -c                        Continue most recent session
cc() {
  local name=""

  # If first arg doesn't start with -, treat as session name.
  if [[ $# -gt 0 && "$1" != -* ]]; then
    name="$1"
    shift
  fi

  # If no name and not resuming/continuing, prompt for one.
  local needs_name=true
  for arg in "$@"; do
    case "$arg" in
      -r|--resume|-c|--continue) needs_name=false; break ;;
    esac
  done

  if [[ -z "$name" && "$needs_name" == true ]]; then
    printf "Session name: "
    read -r name
  fi

  # Get current tmux pane target for registration.
  local target=""
  if [[ -n "$TMUX" ]]; then
    target=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
  fi

  # Pre-register with the agent server (fire-and-forget).
  if [[ -n "$name" && -n "$target" ]]; then
    curl -sf -X POST "$TMUX_AGENTS_SERVER/claude/register" \
      -H 'Content-Type: application/json' \
      -d "{\"name\":\"$name\",\"pane_target\":\"$target\",\"cwd\":\"$(pwd)\"}" \
      >/dev/null 2>&1 &
  fi

  # Build the claude command.
  local -a cmd=(claude)
  [[ -n "$name" ]] && cmd+=(-n "$name")
  cmd+=(--dangerously-skip-permissions --effort max)
  cmd+=("$@")

  "${cmd[@]}"
}

# oc -- Launch OpenCode with session name and port registration
#
# Usage:
#   oc <name> [opencode args...]   Launch with name
#   oc [opencode args...]          Prompt for name interactively
oc() {
  local name=""

  # If first arg doesn't start with -, treat as session name.
  if [[ $# -gt 0 && "$1" != -* ]]; then
    name="$1"
    shift
  fi

  if [[ -z "$name" ]]; then
    printf "Session name: "
    read -r name
  fi

  # Get current tmux pane target.
  local target=""
  if [[ -n "$TMUX" ]]; then
    target=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
  fi

  # Request a port from the agent server, fall back to random.
  local port
  port=$(curl -sf "$TMUX_AGENTS_SERVER/opencode/port" 2>/dev/null)
  if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
    port=$(( 10000 + (RANDOM % 55000) ))
  fi

  # Register in background after a brief delay (opencode needs time to bind).
  if [[ -n "$target" ]]; then
    (
      sleep 1
      curl -sf -X POST "$TMUX_AGENTS_SERVER/opencode/register" \
        -H 'Content-Type: application/json' \
        -d "{\"port\":$port,\"name\":\"$name\",\"pane_target\":\"$target\"}" \
        >/dev/null 2>&1
    ) &
  fi

  opencode --port "$port" -s "$name" "$@"
}
