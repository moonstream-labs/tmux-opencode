#!/usr/bin/env bash
# status.sh -- Status line interpolation script
# Called by tmux via #(path/to/status.sh) in status-right.
# Reads daemon state and renders colored indicators.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/variables.sh"

STATE_FILE="$OPENCODE_STATE_DIR/state"
PERM_FILE="$OPENCODE_STATE_DIR/permissions"

# Exit silently if no state file yet
[[ ! -f "$STATE_FILE" ]] && exit 0

# Read colors from tmux options (with defaults)
get_opt() {
    local val
    val=$(tmux show-option -gqv "$1" 2>/dev/null)
    echo "${val:-$2}"
}

COLOR_PERM=$(get_opt "$OPENCODE_COLOR_PERMISSION_OPTION" "$OPENCODE_COLOR_PERMISSION_DEFAULT")
COLOR_IDLE=$(get_opt "$OPENCODE_COLOR_IDLE_OPTION" "$OPENCODE_COLOR_IDLE_DEFAULT")
COLOR_ERROR=$(get_opt "$OPENCODE_COLOR_ERROR_OPTION" "$OPENCODE_COLOR_ERROR_DEFAULT")
COLOR_FG=$(get_opt "$OPENCODE_COLOR_FG_OPTION" "$OPENCODE_COLOR_FG_DEFAULT")

# Count sessions with pending permissions
perm_count=0
if [[ -f "$PERM_FILE" && -s "$PERM_FILE" ]]; then
    # Count unique session IDs that have pending permissions
    perm_count=$(cut -d'|' -f1 "$PERM_FILE" | sort -u | wc -l)
fi

# Count sessions by status (excluding those already counted as permission-pending)
idle_count=0
error_count=0

if [[ -s "$STATE_FILE" ]]; then
    if [[ $perm_count -gt 0 ]]; then
        # Get session IDs with permissions to exclude from idle count
        perm_sids=$(cut -d'|' -f1 "$PERM_FILE" | sort -u)
        idle_count=$(awk -F'|' '$2 == "idle"' "$STATE_FILE" | while IFS='|' read -r sid _rest; do
            echo "$perm_sids" | grep -qx "$sid" || echo "$sid"
        done | wc -l)
    else
        idle_count=$(awk -F'|' '$2 == "idle"' "$STATE_FILE" | wc -l)
    fi
    error_count=$(awk -F'|' '$2 == "error"' "$STATE_FILE" | wc -l)
fi

# Build output -- only show segments with non-zero counts
output=""

if (( perm_count > 0 )); then
    output+="#[bg=${COLOR_PERM},fg=${COLOR_FG},bold]  ${perm_count} #[default]"
fi

if (( error_count > 0 )); then
    output+="#[bg=${COLOR_ERROR},fg=${COLOR_FG},bold]  ${error_count} #[default]"
fi

if (( idle_count > 0 )); then
    output+="#[bg=${COLOR_IDLE},fg=${COLOR_FG},bold]  ${idle_count} #[default]"
fi

echo "$output"
