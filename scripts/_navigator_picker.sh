#!/usr/bin/env bash
set -euo pipefail

# _navigator_picker.sh -- fzf picker for opencode session navigation
# Gathers session data from the server API and daemon state,
# builds a prioritized list, and navigates to the selected session's pane.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

STATE_FILE=$(get_state_file)
PERM_FILE="$OPENCODE_STATE_DIR/permissions"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Check server health ---

if ! opencode_api_ok; then
    echo "OpenCode server is not reachable at $(get_server_url)"
    echo "Press Enter to close."
    read -r
    exit 1
fi

# --- Gather data ---

# Fetch sessions and statuses in parallel
opencode_api "/session" > "$TMPDIR/sessions.json" &
pid_sessions=$!
opencode_api "/session/status" > "$TMPDIR/statuses.json" &
pid_statuses=$!
wait "$pid_sessions" "$pid_statuses" 2>/dev/null || true

# Build pane map
build_pane_map > "$TMPDIR/pane_map.tsv"

# --- Build fzf input ---

# Parse sessions JSON into tab-separated rows
# Filter: include sessions with a running pane OR sessions updated in last 24h that are idle
NOW=$(date +%s)
CUTOFF=$(( NOW - 86400 ))

# time.updated is in milliseconds -- we convert to seconds in the processing loop
jq -r '.[] | [.id, .title, .directory, (.time.updated | tostring)] | @tsv' \
    "$TMPDIR/sessions.json" 2>/dev/null > "$TMPDIR/sessions.tsv" || true

# Build status lookup from daemon state file
declare -A STATUS_MAP
if [[ -f "$STATE_FILE" ]]; then
    while IFS='|' read -r sid status _ts; do
        STATUS_MAP["$sid"]="$status"
    done < "$STATE_FILE"
fi

# Build permission lookup
declare -A PERM_MAP
if [[ -f "$PERM_FILE" && -s "$PERM_FILE" ]]; then
    while IFS='|' read -r sid _pid; do
        PERM_MAP["$sid"]=1
    done < "$PERM_FILE"
fi

# Build pane lookup: session_id -> tmux_target, and directory -> tmux_target
declare -A PANE_BY_SID
declare -A PANE_BY_DIR
while IFS=$'\t' read -r sid target dir; do
    if [[ -n "$sid" ]]; then
        PANE_BY_SID["$sid"]="$target"
    fi
    if [[ -n "$dir" ]]; then
        PANE_BY_DIR["$dir"]="$target"
    fi
done < "$TMPDIR/pane_map.tsv"

# ANSI color codes for fzf --ansi
C_YELLOW=$'\033[33m'
C_GREEN=$'\033[32m'
C_RED=$'\033[31m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

# Priority: 0=permission(highest), 1=error, 2=idle, 3=busy/other
get_priority() {
    local sid="$1"
    if [[ -n "${PERM_MAP[$sid]:-}" ]]; then
        echo 0
    else
        case "${STATUS_MAP[$sid]:-}" in
            error) echo 1 ;;
            idle)  echo 2 ;;
            *)     echo 3 ;;
        esac
    fi
}

get_status_display() {
    local sid="$1"
    if [[ -n "${PERM_MAP[$sid]:-}" ]]; then
        echo "${C_YELLOW}${C_BOLD} permission${C_RESET}"
    else
        case "${STATUS_MAP[$sid]:-}" in
            error) echo "${C_RED}${C_BOLD} error${C_RESET}" ;;
            idle)  echo "${C_GREEN} idle${C_RESET}" ;;
            busy)  echo "${C_DIM} busy${C_RESET}" ;;
            retry) echo "${C_DIM} retry${C_RESET}" ;;
            *)     echo "${C_DIM} unknown${C_RESET}" ;;
        esac
    fi
}

resolve_pane() {
    local sid="$1" dir="$2"
    # First try direct session ID match
    if [[ -n "${PANE_BY_SID[$sid]:-}" ]]; then
        echo "${PANE_BY_SID[$sid]}"
        return
    fi
    # Fallback: match by directory
    if [[ -n "$dir" && -n "${PANE_BY_DIR[$dir]:-}" ]]; then
        echo "${PANE_BY_DIR[$dir]}"
        return
    fi
    echo "DETACHED"
}

shorten_dir() {
    local dir="$1"
    echo "$dir" | sed "s|^$HOME|~|"
}

# Build the fzf input lines
: > "$TMPDIR/fzf_input.txt"

while IFS=$'\t' read -r sid title dir updated_str; do
    [[ -z "$sid" ]] && continue

    # API returns millisecond timestamps -- convert to seconds
    updated=$(( ${updated_str%.*} / 1000 ))
    pane_target=$(resolve_pane "$sid" "$dir")

    # Filter: include if pane-backed, or if idle/error/permission and recent
    if [[ "$pane_target" == "DETACHED" ]]; then
        local_status="${STATUS_MAP[$sid]:-}"
        has_perm="${PERM_MAP[$sid]:-}"
        # Skip if not recent AND not interesting
        if [[ -z "$has_perm" && "$local_status" != "idle" && "$local_status" != "error" ]]; then
            # Check if updated within last 24h (updated is in epoch seconds)
            if (( updated < CUTOFF )); then
                continue
            fi
        fi
    fi

    priority=$(get_priority "$sid")
    status_display=$(get_status_display "$sid")
    short_dir=$(shorten_dir "$dir")
    age=$(format_age "$updated")

    if [[ "$pane_target" == "DETACHED" ]]; then
        pane_display="${C_DIM}detached${C_RESET}"
    else
        pane_display="$pane_target"
    fi

    # Truncate title to 30 chars
    if (( ${#title} > 30 )); then
        title="${title:0:27}..."
    fi

    # Key field (hidden): priority|session_id|pane_target
    # Display fields: status icon, title, directory, pane, age
    printf '%s\t%s  %-32s  %-28s  %-16s  %s\n' \
        "${priority}|${sid}|${pane_target}" \
        "$status_display" \
        "$title" \
        "$short_dir" \
        "$pane_display" \
        "${C_DIM}${age}${C_RESET}" \
        >> "$TMPDIR/fzf_input.txt"

done < "$TMPDIR/sessions.tsv"

# Sort by priority (first field before |)
sort -t'|' -k1,1n "$TMPDIR/fzf_input.txt" > "$TMPDIR/fzf_sorted.txt"

# --- Show empty state if no sessions ---

if [[ ! -s "$TMPDIR/fzf_sorted.txt" ]]; then
    echo "No active OpenCode sessions found."
    echo "Press Enter to close."
    read -r
    exit 0
fi

# --- Run fzf ---

SELECTION=$(cat "$TMPDIR/fzf_sorted.txt" | fzf \
    --ansi \
    --with-nth='2..' \
    --delimiter=$'\t' \
    --no-sort \
    --reverse \
    --no-info \
    --prompt='  ' \
    --pointer='▶' \
    --header='  STATUS       TITLE                             DIRECTORY                     PANE              AGE' \
    --header-first \
    --color="bg:-1,fg:-1,hl:#e5c07b,fg+:#ffffff,bg+:#3e4452,hl+:#e5c07b,pointer:#98c379,prompt:#98c379,header:#5c6370" \
    --bind='ctrl-c:abort,esc:abort' \
) || exit 0

# --- Handle selection ---

KEY=$(echo "$SELECTION" | cut -f1)
SESSION_ID=$(echo "$KEY" | cut -d'|' -f2)
PANE_TARGET=$(echo "$KEY" | cut -d'|' -f3)

if [[ "$PANE_TARGET" == "DETACHED" ]]; then
    # Open in a new tmux window
    tmux new-window -n "oc" "opencode -s '$SESSION_ID'"
else
    # Switch to the existing pane
    tmux switch-client -t "$PANE_TARGET"
fi
