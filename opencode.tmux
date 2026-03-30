#!/usr/bin/env bash
# opencode.tmux -- TPM entry point for tmux-opencode
# Registers keybindings and starts background polling daemon.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

source "$SCRIPTS_DIR/helpers.sh"

# Cleanup stale option from pre-v1 host-inventory implementation.
tmux set-option -gu "@opencode-hosts-json" 2>/dev/null || true

# Cleanup stale payload options from pre-state-db transport.
tmux set-option -gu "@opencode-panes" 2>/dev/null || true
tmux set-option -gu "@opencode-recent" 2>/dev/null || true

# --- Keybinding ---

POPUP_KEY=$(get_tmux_option "$OPENCODE_POPUP_KEY_OPTION" "$OPENCODE_POPUP_KEY_DEFAULT")
tmux bind-key "$POPUP_KEY" run-shell -b "$SCRIPTS_DIR/navigator.sh"

# --- Background collector daemon ---
start_daemon_if_needed

# --- Status line (optional legacy mode) ---
# By default this plugin does not mutate status-right so users can compose
# Catppuccin modules directly in tmux.conf.

AUTO_STATUS_RIGHT=$(get_tmux_option "$OPENCODE_AUTO_STATUS_RIGHT_OPTION" "$OPENCODE_AUTO_STATUS_RIGHT_DEFAULT")
if [[ "$AUTO_STATUS_RIGHT" == "on" || "$AUTO_STATUS_RIGHT" == "yes" || "$AUTO_STATUS_RIGHT" == "true" ]]; then
    CURRENT_STATUS_RIGHT=$(tmux show-option -gqv "status-right")
    STATUS_FRAGMENT="#($SCRIPTS_DIR/status.sh)"
    if [[ "$CURRENT_STATUS_RIGHT" != *"$STATUS_FRAGMENT"* ]]; then
        tmux set-option -g status-right "${CURRENT_STATUS_RIGHT} ${STATUS_FRAGMENT}"
    fi
fi
