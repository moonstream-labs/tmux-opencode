#!/usr/bin/env bash
# opencode.tmux -- TPM entry point for tmux-opencode
# Registers keybindings, starts the background daemon, and sets up
# status line interpolation.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

source "$SCRIPTS_DIR/helpers.sh"

# --- Keybinding ---

POPUP_KEY=$(get_tmux_option "$OPENCODE_POPUP_KEY_OPTION" "$OPENCODE_POPUP_KEY_DEFAULT")
tmux bind-key "$POPUP_KEY" run-shell -b "$SCRIPTS_DIR/navigator.sh"

# --- Status line ---
# Append the opencode status indicator to the right side of the status bar.
# Uses #() shell interpolation so tmux calls status.sh on each refresh.

CURRENT_STATUS_RIGHT=$(tmux show-option -gqv "status-right")
STATUS_FRAGMENT="#($SCRIPTS_DIR/status.sh)"

# Only append if not already present (idempotent on tmux source-file reload)
if [[ "$CURRENT_STATUS_RIGHT" != *"$STATUS_FRAGMENT"* ]]; then
    tmux set-option -g status-right "${STATUS_FRAGMENT}${CURRENT_STATUS_RIGHT}"
fi

# --- Daemon ---
# Start the background SSE event listener if not already running.

start_daemon
