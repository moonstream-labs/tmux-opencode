#!/usr/bin/env bash
# navigator.sh -- Popup launcher for the agent session navigator

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

ensure_server_running

# Read popup options
POPUP_WIDTH=$(get_tmux_option "$AGENTS_POPUP_WIDTH_OPTION" "$AGENTS_POPUP_WIDTH_DEFAULT")
POPUP_HEIGHT=$(get_tmux_option "$AGENTS_POPUP_HEIGHT_OPTION" "$AGENTS_POPUP_HEIGHT_DEFAULT")
POPUP_BORDER=$(get_tmux_option "$AGENTS_POPUP_BORDER_OPTION" "$AGENTS_POPUP_BORDER_DEFAULT")
POPUP_BG=$(get_tmux_option "$AGENTS_POPUP_BG_OPTION" "$AGENTS_POPUP_BG_DEFAULT")
POPUP_FG=$(get_tmux_option "$AGENTS_POPUP_FG_OPTION" "$AGENTS_POPUP_FG_DEFAULT")

tmux display-popup -E \
    -w "$POPUP_WIDTH" \
    -h "$POPUP_HEIGHT" \
    -b "$POPUP_BORDER" \
    -S "fg=$POPUP_FG" \
    -s "bg=$POPUP_BG,fg=$POPUP_FG" \
    "$CURRENT_DIR/_navigator_picker.sh"
