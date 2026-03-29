#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

ensure_state_dir

LOCK_FILE="$OPENCODE_STATE_DIR/daemon.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi
echo $$ > "$OPENCODE_STATE_DIR/daemon.pid"

cleanup() { rm -f "$OPENCODE_STATE_DIR/daemon.pid"; }
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

# --- Known pane list (populated by discovery tier) ---
# Each entry: "target\tcommand\tpane_pid\tpane_title"
declare -a KNOWN_PANES=()
PREV_PILL=""

# --- TUI pattern constants for remote detection ---
# These patterns appear in the bottom 3 non-blank lines of an OpenCode TUI
readonly TUI_PATTERNS='╹▀▀▀|ctrl\+p commands|esc interrupt|Allow once'

# --- State detection for a single pane ---
# Reads bottom 3 non-blank lines via capture-pane, returns: running|permission|idle|unknown
detect_pane_state() {
    local target="$1"
    local cmd="$2"
    local bottom3
    bottom3=$(tmux capture-pane -t "$target" -p 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -3)
    [[ -z "$bottom3" ]] && { echo "unknown"; return; }

    # For remote (ssh) panes, verify this is actually an OpenCode TUI
    if [[ "$cmd" == "ssh" ]]; then
        if ! grep -qE "$TUI_PATTERNS" <<< "$bottom3"; then
            echo "unknown"
            return
        fi
    fi

    # State priority: running > permission > idle
    local last_line
    last_line=$(tail -1 <<< "$bottom3")
    if [[ "$last_line" == *"esc interrupt"* ]]; then
        echo "running"
        return
    fi

    local second_last
    second_last=$(sed -n '2p' <<< "$bottom3")
    if [[ "$second_last" == *"Allow once"* || "$last_line" == *"Allow once"* ]]; then
        echo "permission"
        return
    fi

    echo "idle"
}

# --- Discovery: scan all panes, find OpenCode panes ---
discover_panes() {
    local -a new_panes=()
    local target cmd pane_pid pane_title

    while IFS=$'\t' read -r target cmd pane_pid pane_title; do
        if [[ "$cmd" == "opencode" ]]; then
            new_panes+=("${target}"$'\t'"${cmd}"$'\t'"${pane_pid}"$'\t'"${pane_title}")
        elif [[ "$cmd" == "ssh" ]]; then
            # Validate remote pane is actually running OpenCode TUI
            local bottom3
            bottom3=$(tmux capture-pane -t "$target" -p 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -3)
            if grep -qE "$TUI_PATTERNS" <<< "$bottom3" 2>/dev/null; then
                new_panes+=("${target}"$'\t'"${cmd}"$'\t'"${pane_pid}"$'\t'"${pane_title}")
            fi
        fi
    done < <(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}	#{pane_current_command}	#{pane_pid}	#{pane_title}' 2>/dev/null)

    KNOWN_PANES=("${new_panes[@]+"${new_panes[@]}"}")
}

# --- Session ID extraction for local panes ---
# Walks process tree from pane_pid to find opencode child, extracts -s argument
extract_local_session_id() {
    local pane_pid="$1"
    local cpid cmdline gcpid child_pid=""

    for cpid in $(pgrep -P "$pane_pid" 2>/dev/null); do
        if [[ -f "/proc/$cpid/cmdline" ]]; then
            cmdline=$(tr '\0' ' ' < "/proc/$cpid/cmdline" 2>/dev/null || true)
            if [[ "$cmdline" == *opencode* ]]; then
                child_pid="$cpid"
                break
            fi
        fi
        # Check grandchildren (e.g. shell -> opencode)
        for gcpid in $(pgrep -P "$cpid" 2>/dev/null); do
            if [[ -f "/proc/$gcpid/cmdline" ]]; then
                cmdline=$(tr '\0' ' ' < "/proc/$gcpid/cmdline" 2>/dev/null || true)
                if [[ "$cmdline" == *opencode* ]]; then
                    child_pid="$gcpid"
                    break 2
                fi
            fi
        done
    done

    [[ -z "$child_pid" ]] && return

    # Parse -s / --session flag from null-delimited cmdline
    local found_s=0 arg
    while IFS= read -r -d '' arg || [[ -n "$arg" ]]; do
        if (( found_s )); then
            echo "$arg"
            return
        fi
        [[ "$arg" == "-s" || "$arg" == "--session" ]] && found_s=1
    done < "/proc/$child_pid/cmdline" 2>/dev/null
    return 0
}

escape_field() {
    local s="${1:-}"
    s=${s//%/%25}
    s=${s//|/%7C}
    s=${s//$'\n'/%0A}
    s=${s//$'\r'/%0D}
    printf '%s' "$s"
}

apply_local_fallback_mappings() {
    local db_path="$1"
    [[ -f "$db_path" ]] || return

    local -A mapped_local_sids=()
    local entry target cmd pane_pid pane_title sid

    # Track already-mapped local session IDs so we don't reuse them.
    for entry in "${KNOWN_PANES[@]}"; do
        IFS=$'\t' read -r target cmd pane_pid pane_title <<< "$entry"
        [[ "$cmd" != "opencode" ]] && continue
        sid="${SID_FOR_TARGET[$target]:-}"
        [[ -n "$sid" ]] && mapped_local_sids["$sid"]=1
    done

    # Option B strategy: for unmapped local panes, pick newest session in pane dir.
    for entry in "${KNOWN_PANES[@]}"; do
        IFS=$'\t' read -r target cmd pane_pid pane_title <<< "$entry"
        [[ "$cmd" != "opencode" ]] && continue
        [[ -n "${SID_FOR_TARGET[$target]:-}" ]] && continue

        local pane_dir pane_dir_sql
        pane_dir=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
        [[ -z "$pane_dir" ]] && continue
        pane_dir_sql=${pane_dir//\'/\'\'}

        local cand_sid cand_title cand_dir cand_updated
        while IFS='|' read -r cand_sid cand_title cand_dir cand_updated; do
            [[ -z "$cand_sid" ]] && continue
            [[ -n "${mapped_local_sids[$cand_sid]:-}" ]] && continue

            SID_FOR_TARGET["$target"]="$cand_sid"
            mapped_local_sids["$cand_sid"]=1

            META_TITLE["$cand_sid"]="$cand_title"
            META_DIR["$cand_sid"]="$cand_dir"
            META_UPDATED["$cand_sid"]="$cand_updated"
            META_HOST["$cand_sid"]="local"
            break
        done < <(sqlite3 "$db_path" "SELECT id, title, directory, time_updated FROM session WHERE directory = '$pane_dir_sql' ORDER BY time_created DESC, time_updated DESC LIMIT 15" 2>/dev/null)
    done
}

# --- Metadata: associative arrays for session data ---
declare -A META_TITLE=()
declare -A META_DIR=()
declare -A META_UPDATED=()
declare -A META_HOST=()
declare -A SID_FOR_TARGET=()

# --- Fetch metadata from local DB + remote SSH ---
fetch_metadata() {
    local target cmd pane_pid pane_title
    local -a local_sids=()

    META_TITLE=()
    META_DIR=()
    META_UPDATED=()
    META_HOST=()
    SID_FOR_TARGET=()

    local -A remote_hosts=()
    local -A tmux_session_for_host=()
    local -A host_for_target=()

    # Collect session IDs for local panes, host list for remote panes
    for entry in "${KNOWN_PANES[@]}"; do
        IFS=$'\t' read -r target cmd pane_pid pane_title <<< "$entry"
        host_for_target["$target"]="local"
        if [[ "$cmd" == "opencode" ]]; then
            local sid
            sid=$(extract_local_session_id "$pane_pid")
            if [[ -n "$sid" ]]; then
                local_sids+=("$sid")
                SID_FOR_TARGET["$target"]="$sid"
            fi
        elif [[ "$cmd" == "ssh" ]]; then
            remote_hosts["$pane_title"]="$target"
            tmux_session_for_host["$pane_title"]="${target%%:*}"
            host_for_target["$target"]="$pane_title"
        fi
    done

    # Local DB query: active session metadata + recent sessions
    local db_path
    db_path=$(get_db_path)
    if [[ -f "$db_path" ]]; then
        # Fill unmapped local panes launched as plain `opencode`.
        apply_local_fallback_mappings "$db_path"

        # Rebuild local active SID list from resolved targets (includes fallback).
        local_sids=()
        for entry in "${KNOWN_PANES[@]}"; do
            IFS=$'\t' read -r target cmd pane_pid pane_title <<< "$entry"
            [[ "$cmd" != "opencode" ]] && continue
            sid="${SID_FOR_TARGET[$target]:-}"
            [[ -n "$sid" ]] && local_sids+=("$sid")
        done

        # Fetch active session metadata
        if (( ${#local_sids[@]} > 0 )); then
            local in_clause="" sid
            for sid in "${local_sids[@]}"; do
                [[ -n "$in_clause" ]] && in_clause+=","
                in_clause+="'$sid'"
            done
            while IFS='|' read -r sid title dir updated; do
                META_TITLE["$sid"]="$title"
                META_DIR["$sid"]="$dir"
                META_UPDATED["$sid"]="$updated"
                META_HOST["$sid"]="local"
            done < <(sqlite3 "$db_path" "SELECT id, title, directory, time_updated FROM session WHERE id IN ($in_clause)" 2>/dev/null)
        fi
        # Fetch recent sessions for local host
        while IFS='|' read -r sid title dir updated; do
            META_TITLE["$sid"]="$title"
            META_DIR["$sid"]="$dir"
            META_UPDATED["$sid"]="$updated"
            META_HOST["$sid"]="local"
        done < <(sqlite3 "$db_path" "SELECT id, title, directory, time_updated FROM session ORDER BY time_updated DESC LIMIT 21" 2>/dev/null)
    fi

    # Remote DB queries: async SSH, one per unique host
    # Fetch both active session (line 1) and recent sessions (lines 2+)
    local -A remote_pids=()
    local tmpdir
    tmpdir=$(mktemp -d)
    for host in "${!remote_hosts[@]}"; do
        ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no "$host" \
            "sqlite3 ~/.local/share/opencode/opencode.db \"SELECT id, title, directory, time_updated FROM session ORDER BY time_updated DESC LIMIT 21\"" \
            > "$tmpdir/$host" 2>/dev/null &
        remote_pids["$host"]=$!
    done

    # Wait for all SSH queries
    for host in "${!remote_pids[@]}"; do
        wait "${remote_pids[$host]}" 2>/dev/null || true
        if [[ -s "$tmpdir/$host" ]]; then
            local sid title dir updated first_line=1
            while IFS='|' read -r sid title dir updated; do
                META_TITLE["$sid"]="$title"
                META_DIR["$sid"]="$dir"
                META_UPDATED["$sid"]="$updated"
                META_HOST["$sid"]="$host"
                if (( first_line )); then
                    local rtarget="${remote_hosts[$host]}"
                    SID_FOR_TARGET["$rtarget"]="$sid"
                    first_line=0
                fi
            done < "$tmpdir/$host"
        fi
    done
    rm -rf "$tmpdir"

    # Build @opencode-panes TSV: target|cmd|host|sid|title|dir|updated
    local panes_data="" state
    for entry in "${KNOWN_PANES[@]}"; do
        IFS=$'\t' read -r target cmd pane_pid pane_title <<< "$entry"
        local sid="${SID_FOR_TARGET[$target]:-}"
        local title="" dir="" updated=""
        if [[ -n "$sid" ]]; then
            title="${META_TITLE[$sid]:-}"
            dir="${META_DIR[$sid]:-}"
            updated="${META_UPDATED[$sid]:-}"
        fi
        local host="local"
        [[ "$cmd" == "ssh" ]] && host="$pane_title"
        state=$(detect_pane_state "$target" "$cmd")
        [[ -n "$panes_data" ]] && panes_data+=$'\n'
        local e_title e_dir
        e_title=$(escape_field "$title")
        e_dir=$(escape_field "$dir")
        panes_data+="${target}|${cmd}|${state}|${host}|${sid}|${e_title}|${e_dir}|${updated}"
    done

    tmux set-option -g "$OPENCODE_PANES_OPTION" "$panes_data" 2>/dev/null || true

    # Build @opencode-recent: all known sessions minus active ones, sorted by time_updated desc
    # Collect active session IDs to exclude
    local -A active_sids=()
    local -A active_contexts=()
    for target in "${!SID_FOR_TARGET[@]}"; do
        local asid="${SID_FOR_TARGET[$target]}"
        active_sids["$asid"]=1

        local ahost atitle adir
        ahost="${host_for_target[$target]:-local}"
        atitle="${META_TITLE[$asid]:-}"
        adir="${META_DIR[$asid]:-}"
        if [[ -n "$atitle" && -n "$adir" ]]; then
            active_contexts["${ahost}|${adir}|${atitle}"]=1
        fi
    done

    # Build recent entries from all metadata (local + remote hosts)
    # Format: updated|host|sid|title|dir|tmux_session (sorted by updated desc)
    local -a recent_entries=()
    local rsid
    for rsid in "${!META_TITLE[@]}"; do
        [[ -n "${active_sids[$rsid]:-}" ]] && continue
        local rtitle="${META_TITLE[$rsid]}"
        local rdir="${META_DIR[$rsid]:-}"
        local rupdated="${META_UPDATED[$rsid]:-0}"
        local rhost="${META_HOST[$rsid]:-local}"

        # Context dedupe: if an active pane already represents the same
        # host+directory+title, hide duplicate from recent list.
        if [[ -n "$rtitle" && -n "$rdir" && -n "${active_contexts["${rhost}|${rdir}|${rtitle}"]:-}" ]]; then
            continue
        fi

        local rtmux_session=""
        if [[ "$rhost" != "local" ]]; then
            rtmux_session="${tmux_session_for_host[$rhost]:-}"
        fi
        recent_entries+=("${rupdated}|${rhost}|${rsid}|$(escape_field "$rtitle")|$(escape_field "$rdir")|${rtmux_session}")
    done

    # Sort by time_updated descending, take top 20
    local recent_data=""
    if (( ${#recent_entries[@]} > 0 )); then
        recent_data=$(printf '%s\n' "${recent_entries[@]}" | sort -t'|' -k1 -rn | head -20 | while IFS='|' read -r _ts host sid title dir tmux_session; do
            echo "${host}|${sid}|${title}|${dir}|${_ts}|${tmux_session}"
        done)
    fi
    tmux set-option -g "$OPENCODE_RECENT_OPTION" "$recent_data" 2>/dev/null || true
}

# --- Update pill, pane states, and refresh status line ---
# Single pass: detect state for each pane, compute pill, update @opencode-panes
PREV_PANES_STATES=""

update_pill() {
    local count=${#KNOWN_PANES[@]}
    if (( count == 0 )); then
        local pill="idle|0"
        if [[ "$pill" != "$PREV_PILL" ]]; then
            tmux set-option -g "$OPENCODE_PILL_OPTION" "$pill" 2>/dev/null || true
            tmux refresh-client -S 2>/dev/null || true
            PREV_PILL="$pill"
        fi
        return
    fi

    local permission_count=0 running_count=0
    local panes_data="" target cmd pane_pid pane_title state

    for entry in "${KNOWN_PANES[@]}"; do
        IFS=$'\t' read -r target cmd pane_pid pane_title <<< "$entry"
        state=$(detect_pane_state "$target" "$cmd")
        case "$state" in
            permission) (( permission_count++ )) || true ;;
            running)    (( running_count++ )) || true ;;
        esac

        local sid="${SID_FOR_TARGET[$target]:-}"
        local title="" dir="" updated=""
        if [[ -n "$sid" ]]; then
            title="${META_TITLE[$sid]:-}"
            dir="${META_DIR[$sid]:-}"
            updated="${META_UPDATED[$sid]:-}"
        fi
        local host="local"
        [[ "$cmd" == "ssh" ]] && host="$pane_title"
        [[ -n "$panes_data" ]] && panes_data+=$'\n'
        local e_title e_dir
        e_title=$(escape_field "$title")
        e_dir=$(escape_field "$dir")
        panes_data+="${target}|${cmd}|${state}|${host}|${sid}|${e_title}|${e_dir}|${updated}"
    done

    # Compute pill
    local pill
    if (( permission_count > 0 )); then
        pill="permission|$permission_count"
    elif (( running_count > 0 )); then
        pill="running|$running_count"
    else
        pill="active|$count"
    fi

    if [[ "$pill" != "$PREV_PILL" ]]; then
        tmux set-option -g "$OPENCODE_PILL_OPTION" "$pill" 2>/dev/null || true
        tmux refresh-client -S 2>/dev/null || true
        PREV_PILL="$pill"
    fi

    # Update pane states for navigator
    if [[ "$panes_data" != "$PREV_PANES_STATES" ]]; then
        tmux set-option -g "$OPENCODE_PANES_OPTION" "$panes_data" 2>/dev/null || true
        PREV_PANES_STATES="$panes_data"
    fi
}

# --- Main loop: three-tier polling ---
FAST_INTERVAL_S="0.1"
DISCOVERY_INTERVAL_S="$OPENCODE_POLL_DISCOVERY_S"
METADATA_INTERVAL_S="$OPENCODE_POLL_METADATA_S"
LOCAL_MAP_INTERVAL_S="$OPENCODE_POLL_LOCAL_MAP_S"

last_discovery=0
last_metadata=0
last_local_map=0

# Initial discovery
discover_panes
update_pill

while true; do
    now=$(date +%s)

    # Discovery tier (every 5s)
    if (( now - last_discovery >= DISCOVERY_INTERVAL_S )); then
        discover_panes
        last_discovery=$now
    fi

    # Metadata tier (every 30s): session titles, dirs, timestamps
    if (( now - last_metadata >= METADATA_INTERVAL_S )); then
        fetch_metadata
        last_metadata=$now
    fi

    # Local fallback tier (every 2s): quickly map plain `opencode` panes.
    if (( now - last_local_map >= LOCAL_MAP_INTERVAL_S )); then
        db_path_now=$(get_db_path)
        apply_local_fallback_mappings "$db_path_now"
        last_local_map=$now
    fi

    # Fast tier (every 100ms): state detection on known panes
    update_pill

    sleep "$FAST_INTERVAL_S"
done
