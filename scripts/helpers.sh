#!/usr/bin/env bash
# helpers.sh -- Shared utilities for tmux-opencode

# Double-source guard
[[ -n "${_OPENCODE_HELPERS_LOADED:-}" ]] && return
_OPENCODE_HELPERS_LOADED=1

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/variables.sh"

# --- tmux option helpers ---

get_tmux_option() {
    local option="$1"
    local default_value="$2"
    local value
    value=$(tmux show-option -gqv "$option")
    echo "${value:-$default_value}"
}

get_server_url() {
    get_tmux_option "$OPENCODE_SERVER_URL_OPTION" "$OPENCODE_SERVER_URL_DEFAULT"
}

# --- API helpers ---

opencode_api() {
    local endpoint="$1"
    local server_url
    server_url=$(get_server_url)
    curl -sf --max-time 5 "${server_url}${endpoint}"
}

opencode_api_ok() {
    local server_url
    server_url=$(get_server_url)
    curl -sf --max-time 2 "${server_url}/global/health" >/dev/null 2>&1
}

# --- State directory ---

ensure_state_dir() {
    mkdir -p "$OPENCODE_STATE_DIR"
}

get_state_file() {
    echo "$OPENCODE_STATE_DIR/state"
}

get_pid_file() {
    echo "$OPENCODE_STATE_DIR/daemon.pid"
}

# --- Pane mapping ---
# Builds a mapping of opencode session IDs to tmux pane targets.
# Output format (tab-separated): session_id\ttmux_target\tdirectory
# For panes without a -s flag, outputs: \ttmux_target\tdirectory

build_pane_map() {
    local pane_info pane_target pane_pid child_pid cmdline session_id cwd

    tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}	#{pane_pid}' 2>/dev/null | \
    while IFS=$'\t' read -r pane_target pane_pid; do
        # Find opencode child process of the shell running in this pane
        child_pid=""
        for cpid in $(pgrep -P "$pane_pid" 2>/dev/null); do
            if [[ -f "/proc/$cpid/cmdline" ]]; then
                cmdline=$(tr '\0' ' ' < "/proc/$cpid/cmdline" 2>/dev/null)
                if [[ "$cmdline" == *opencode* ]]; then
                    child_pid="$cpid"
                    break
                fi
            fi
        done

        # Also check grandchildren (shell -> opencode)
        if [[ -z "$child_pid" ]]; then
            for cpid in $(pgrep -P "$pane_pid" 2>/dev/null); do
                for gcpid in $(pgrep -P "$cpid" 2>/dev/null); do
                    if [[ -f "/proc/$gcpid/cmdline" ]]; then
                        cmdline=$(tr '\0' ' ' < "/proc/$gcpid/cmdline" 2>/dev/null)
                        if [[ "$cmdline" == *opencode* ]]; then
                            child_pid="$gcpid"
                            break 2
                        fi
                    fi
                done
            done
        fi

        [[ -z "$child_pid" ]] && continue

        # Extract -s session_id from cmdline
        cmdline=$(tr '\0' '\n' < "/proc/$child_pid/cmdline" 2>/dev/null)
        session_id=""
        local found_s=0
        while IFS= read -r arg; do
            if [[ $found_s -eq 1 ]]; then
                session_id="$arg"
                break
            fi
            [[ "$arg" == "-s" || "$arg" == "--session" ]] && found_s=1
        done <<< "$cmdline"

        # Get working directory of the opencode process
        cwd=$(readlink -f "/proc/$child_pid/cwd" 2>/dev/null || echo "")

        printf '%s\t%s\t%s\n' "$session_id" "$pane_target" "$cwd"
    done
}

# --- Time formatting ---

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

# --- Daemon management ---

is_daemon_running() {
    local pid_file
    pid_file=$(get_pid_file)
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

start_daemon() {
    ensure_state_dir
    if is_daemon_running; then
        return 0
    fi
    nohup "$CURRENT_DIR/daemon.sh" >/dev/null 2>&1 &
}
