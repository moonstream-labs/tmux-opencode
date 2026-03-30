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

get_bindings_file() {
    echo "$OPENCODE_STATE_DIR/remote-bindings.tsv"
}

get_state_db_path() {
    echo "$OPENCODE_STATE_DB_PATH"
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

    read -r pid < "$pid_file" 2>/dev/null || true
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    [[ -f "/proc/$pid/cmdline" ]] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'daemon\.sh'
}

daemon_heartbeat_is_fresh() {
    local ts now
    ts=$(tmux show-option -gqv "$OPENCODE_DAEMON_TS_OPTION" 2>/dev/null || true)
    [[ "$ts" =~ ^[0-9]+$ ]] || return 0

    now=$(date +%s)
    (( now - ts <= OPENCODE_DAEMON_STALE_S ))
}

daemon_is_healthy() {
    daemon_is_running && daemon_heartbeat_is_fresh
}

stop_daemon_if_running() {
    local pid_file pid i
    pid_file=$(get_pid_file)
    [[ -f "$pid_file" ]] || return 0

    read -r pid < "$pid_file" 2>/dev/null || true
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0

    kill "$pid" 2>/dev/null || true
    for i in {1..10}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done

    kill -KILL "$pid" 2>/dev/null || true
}

set_remote_binding() {
    local target="$1"
    local host="$2"
    local sid="$3"
    [[ -n "$target" && -n "$host" && -n "$sid" ]] || return 1

    ensure_state_dir

    local lock_file bindings_file tmp_file
    lock_file="$OPENCODE_STATE_DIR/remote-bindings.lock"
    bindings_file=$(get_bindings_file)
    tmp_file=$(mktemp "$OPENCODE_STATE_DIR/remote-bindings.XXXXXX")

    exec 8>"$lock_file"
    flock 8

    if [[ -f "$bindings_file" ]]; then
        while IFS=$'\t' read -r existing_target existing_host existing_sid; do
            [[ -z "$existing_target" ]] && continue
            [[ "$existing_target" == "$target" ]] && continue
            printf '%s\t%s\t%s\n' "$existing_target" "$existing_host" "$existing_sid"
        done < "$bindings_file" > "$tmp_file"
    fi

    printf '%s\t%s\t%s\n' "$target" "$host" "$sid" >> "$tmp_file"
    mv "$tmp_file" "$bindings_file"
}

start_daemon_if_needed() {
    ensure_state_dir
    if daemon_is_healthy; then
        return 0
    fi

    if daemon_is_running; then
        stop_daemon_if_running
    fi

    nohup "$CURRENT_DIR/daemon.sh" >/dev/null 2>&1 &
}
