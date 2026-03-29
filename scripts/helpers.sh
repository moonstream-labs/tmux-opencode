#!/usr/bin/env bash
# helpers.sh -- Shared utilities for tmux-opencode

[[ -n "${_OPENCODE_HELPERS_LOADED:-}" ]] && return
_OPENCODE_HELPERS_LOADED=1

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/variables.sh"

get_tmux_option() {
    local option="$1"
    local default_value="$2"
    local value
    value=$(tmux show-option -gqv "$option" 2>/dev/null)
    echo "${value:-$default_value}"
}

ensure_state_dir() {
    mkdir -p "$OPENCODE_STATE_DIR"
}

get_pid_file() {
    echo "$OPENCODE_STATE_DIR/daemon.pid"
}

get_db_path() {
    echo "$OPENCODE_DB_PATH"
}

format_age() {
    local epoch="$1"
    local now
    now=$(date +%s)
    local diff=$(( now - epoch ))

    if (( diff < 60 )); then
        echo "${diff}s ago"
    elif (( diff < 3600 )); then
        echo "$(( diff / 60 ))m ago"
    elif (( diff < 86400 )); then
        echo "$(( diff / 3600 ))h ago"
    else
        echo "$(( diff / 86400 ))d ago"
    fi
}

daemon_is_running() {
    local pid_file pid
    pid_file=$(get_pid_file)
    [[ -f "$pid_file" ]] || return 1

    pid=$(cat "$pid_file" 2>/dev/null || true)
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    [[ -f "/proc/$pid/cmdline" ]] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'daemon\.sh'
}

start_daemon_if_needed() {
    ensure_state_dir
    if daemon_is_running; then
        return 0
    fi
    nohup "$CURRENT_DIR/daemon.sh" >/dev/null 2>&1 &
}
