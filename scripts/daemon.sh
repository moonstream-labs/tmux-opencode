#!/usr/bin/env bash
set -euo pipefail

# daemon.sh -- Background SSE event listener that maintains session state
# Subscribes to the opencode server event stream and tracks:
#   - Session statuses (idle/busy/retry)
#   - Pending permission requests
#   - Session errors

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

ensure_state_dir

STATE_FILE=$(get_state_file)
PID_FILE=$(get_pid_file)
LOCK_FILE="$OPENCODE_STATE_DIR/daemon.lock"
PERM_FILE="$OPENCODE_STATE_DIR/permissions"

# --- Locking ---

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "daemon: another instance is running" >&2
        exit 0
    fi
    echo $$ > "$PID_FILE"
}

cleanup() {
    rm -f "$PID_FILE" "$LOCK_FILE"
    exec 9>&-
}
trap cleanup EXIT

# --- State management ---
# State file format: session_id|status|last_updated_epoch
# One line per session. Status is one of: idle, busy, retry, error
#
# Permissions file format: session_id|permission_id
# One line per pending permission.

update_session_status() {
    local sid="$1" status="$2"
    local now
    now=$(date +%s)
    local tmpfile="$STATE_FILE.tmp"

    if [[ -f "$STATE_FILE" ]]; then
        # Remove existing entry for this session, then append updated
        grep -v "^${sid}|" "$STATE_FILE" > "$tmpfile" 2>/dev/null || true
    else
        : > "$tmpfile"
    fi
    echo "${sid}|${status}|${now}" >> "$tmpfile"
    mv "$tmpfile" "$STATE_FILE"
}

remove_session() {
    local sid="$1"
    local tmpfile="$STATE_FILE.tmp"
    if [[ -f "$STATE_FILE" ]]; then
        grep -v "^${sid}|" "$STATE_FILE" > "$tmpfile" 2>/dev/null || true
        mv "$tmpfile" "$STATE_FILE"
    fi
    # Also clean up any permissions for this session
    remove_all_permissions "$sid"
}

add_pending_permission() {
    local sid="$1" pid="$2"
    echo "${sid}|${pid}" >> "$PERM_FILE"
}

remove_pending_permission() {
    local sid="$1" pid="$2"
    local tmpfile="$PERM_FILE.tmp"
    if [[ -f "$PERM_FILE" ]]; then
        grep -v "^${sid}|${pid}$" "$PERM_FILE" > "$tmpfile" 2>/dev/null || true
        mv "$tmpfile" "$PERM_FILE"
    fi
}

remove_all_permissions() {
    local sid="$1"
    local tmpfile="$PERM_FILE.tmp"
    if [[ -f "$PERM_FILE" ]]; then
        grep -v "^${sid}|" "$PERM_FILE" > "$tmpfile" 2>/dev/null || true
        mv "$tmpfile" "$PERM_FILE"
    fi
}

# --- Initial state seeding ---

seed_state() {
    local statuses
    statuses=$(opencode_api "/session/status" 2>/dev/null) || return 1

    local tmpfile="$STATE_FILE.tmp"
    local now
    now=$(date +%s)

    : > "$tmpfile"
    echo "$statuses" | jq -r 'to_entries[] | "\(.key)|\(.value.type)|\('"$now"')"' >> "$tmpfile" 2>/dev/null || true
    mv "$tmpfile" "$STATE_FILE"

    # Clear permissions -- we can't know pending permissions from the status endpoint alone
    # They'll be picked up as events arrive
    : > "$PERM_FILE"
}

# --- SSE event processing ---

process_event() {
    local json="$1"

    local event_type
    event_type=$(echo "$json" | jq -r '.payload.type // empty' 2>/dev/null) || return
    [[ -z "$event_type" ]] && return

    local sid pid status

    case "$event_type" in
        session.status)
            sid=$(echo "$json" | jq -r '.payload.properties.sessionID // empty' 2>/dev/null)
            status=$(echo "$json" | jq -r '.payload.properties.status.type // empty' 2>/dev/null)
            [[ -n "$sid" && -n "$status" ]] && update_session_status "$sid" "$status"
            ;;
        session.idle)
            sid=$(echo "$json" | jq -r '.payload.properties.sessionID // empty' 2>/dev/null)
            [[ -n "$sid" ]] && update_session_status "$sid" "idle"
            ;;
        session.error)
            sid=$(echo "$json" | jq -r '.payload.properties.sessionID // empty' 2>/dev/null)
            [[ -n "$sid" ]] && update_session_status "$sid" "error"
            ;;
        session.created)
            sid=$(echo "$json" | jq -r '.payload.properties.id // empty' 2>/dev/null)
            [[ -n "$sid" ]] && update_session_status "$sid" "idle"
            ;;
        session.deleted)
            sid=$(echo "$json" | jq -r '.payload.properties.id // empty' 2>/dev/null)
            [[ -n "$sid" ]] && remove_session "$sid"
            ;;
        permission.updated)
            sid=$(echo "$json" | jq -r '.payload.properties.sessionID // empty' 2>/dev/null)
            pid=$(echo "$json" | jq -r '.payload.properties.id // empty' 2>/dev/null)
            [[ -n "$sid" && -n "$pid" ]] && add_pending_permission "$sid" "$pid"
            ;;
        permission.replied)
            sid=$(echo "$json" | jq -r '.payload.properties.sessionID // empty' 2>/dev/null)
            pid=$(echo "$json" | jq -r '.payload.properties.permissionID // empty' 2>/dev/null)
            [[ -n "$sid" && -n "$pid" ]] && remove_pending_permission "$sid" "$pid"
            ;;
    esac
}

process_sse_stream() {
    local server_url
    server_url=$(get_server_url)

    curl -sfN "${server_url}/global/event" 2>/dev/null | while IFS= read -r line; do
        # SSE format: lines starting with "data:" contain the JSON payload
        if [[ "$line" == data:* ]]; then
            local json="${line#data:}"
            # Trim leading whitespace
            json="${json#"${json%%[![:space:]]*}"}"
            [[ -n "$json" ]] && process_event "$json"
        fi
    done
}

# --- Main loop ---

acquire_lock

while true; do
    if opencode_api_ok; then
        seed_state
        process_sse_stream
    fi
    # Backoff before reconnect
    sleep 3
done
