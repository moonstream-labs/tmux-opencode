#!/usr/bin/env bash
# variables.sh -- Option names and defaults for tmux-opencode

# Double-source guard
[[ -n "${_OPENCODE_VARIABLES_LOADED:-}" ]] && return
_OPENCODE_VARIABLES_LOADED=1

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

OPENCODE_AUTO_STATUS_RIGHT_OPTION="@opencode-auto-status-right"
OPENCODE_AUTO_STATUS_RIGHT_DEFAULT="off"

# --- Daemon health ---
OPENCODE_DAEMON_TS_OPTION="@opencode-daemon-ts"
OPENCODE_DAEMON_STALE_S=20

# --- Remote behavior ---
OPENCODE_REMOTE_POLLING_OPTION="@opencode-remote-polling"
OPENCODE_REMOTE_POLLING_DEFAULT="on"

# Remote pane/session association mode:
# - unbound (default): do not guess a session for unknown remote panes
# - latest: fallback to newest remote DB session when exact binding is unknown
OPENCODE_REMOTE_BINDING_MODE_OPTION="@opencode-remote-binding-mode"
OPENCODE_REMOTE_BINDING_MODE_DEFAULT="unbound"

OPENCODE_SSH_CONNECT_TIMEOUT_OPTION="@opencode-ssh-connect-timeout"
OPENCODE_SSH_CONNECT_TIMEOUT_DEFAULT="3"

OPENCODE_SSH_STRICT_HOST_KEY_CHECKING_OPTION="@opencode-ssh-strict-host-key-checking"
OPENCODE_SSH_STRICT_HOST_KEY_CHECKING_DEFAULT="accept-new"

# --- Polling intervals ---
OPENCODE_POLL_DISCOVERY_S=5        # pane discovery (list-panes scan)
OPENCODE_POLL_METADATA_S=30        # DB queries (local sqlite3 + remote SSH)
OPENCODE_POLL_LOCAL_MAP_S=2        # local fallback SID mapping for plain `opencode`

# --- Paths ---
OPENCODE_STATE_DIR="${OPENCODE_STATE_DIR:-/tmp/tmux-opencode-$(id -u)}"
OPENCODE_STATE_DB_PATH="${OPENCODE_STATE_DB_PATH:-$OPENCODE_STATE_DIR/state.db}"
OPENCODE_DB_PATH="${OPENCODE_DB_PATH:-$HOME/.local/share/opencode/opencode.db}"

# --- tmux option keys for state storage ---
OPENCODE_PILL_OPTION="@opencode-pill"
OPENCODE_GEN_OPTION="@opencode-gen"
