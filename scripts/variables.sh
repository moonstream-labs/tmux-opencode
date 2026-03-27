#!/usr/bin/env bash
# variables.sh -- Option names and defaults for tmux-opencode

# Double-source guard
[[ -n "${_OPENCODE_VARIABLES_LOADED:-}" ]] && return
_OPENCODE_VARIABLES_LOADED=1

# --- Server ---
OPENCODE_SERVER_URL_OPTION="@opencode-server-url"
OPENCODE_SERVER_URL_DEFAULT="http://127.0.0.1:4096"

# --- Keybind ---
OPENCODE_POPUP_KEY_OPTION="@opencode-popup-key"
OPENCODE_POPUP_KEY_DEFAULT="o"

# --- Popup styling ---
OPENCODE_POPUP_WIDTH_OPTION="@opencode-popup-width"
OPENCODE_POPUP_WIDTH_DEFAULT="70%"

OPENCODE_POPUP_HEIGHT_OPTION="@opencode-popup-height"
OPENCODE_POPUP_HEIGHT_DEFAULT="50%"

OPENCODE_POPUP_BORDER_OPTION="@opencode-popup-border"
OPENCODE_POPUP_BORDER_DEFAULT="rounded"

OPENCODE_POPUP_BG_OPTION="@opencode-popup-bg"
OPENCODE_POPUP_BG_DEFAULT="#080909"

OPENCODE_POPUP_FG_OPTION="@opencode-popup-fg"
OPENCODE_POPUP_FG_DEFAULT="#dadada"

# --- Status line colors ---
OPENCODE_COLOR_PERMISSION_OPTION="@opencode-color-permission"
OPENCODE_COLOR_PERMISSION_DEFAULT="#e5c07b"

OPENCODE_COLOR_IDLE_OPTION="@opencode-color-idle"
OPENCODE_COLOR_IDLE_DEFAULT="#98c379"

OPENCODE_COLOR_ERROR_OPTION="@opencode-color-error"
OPENCODE_COLOR_ERROR_DEFAULT="#e06c75"

OPENCODE_COLOR_FG_OPTION="@opencode-color-fg"
OPENCODE_COLOR_FG_DEFAULT="#282c34"

# --- Runtime paths ---
OPENCODE_STATE_DIR="/tmp/tmux-opencode-$(id -u)"
