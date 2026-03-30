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

cleanup() {
    rm -f "$OPENCODE_STATE_DIR/daemon.pid"
}

trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

# --- Known pane list (populated by discovery tier) ---
# Each entry: "target\tcommand\tpane_pid\tpane_title"
declare -a KNOWN_PANES=()

# --- Session metadata keyed by composite session key (host + sid) ---
declare -A META_TITLE=()
declare -A META_DIR=()
declare -A META_UPDATED=()

# --- Pane -> session association ---
# value is composite session key (host + sid)
declare -A SESSION_KEY_FOR_TARGET=()
declare -A HOST_FOR_TARGET=()

PREV_PILL=""
PREV_PANES_STATES=""
PREV_RECENT_STATES=""
STATE_GEN=0

# --- TUI pattern constants for remote detection ---
# These patterns appear in the bottom 3 non-blank lines of an OpenCode TUI.
readonly TUI_PATTERNS='╹▀▀▀|ctrl\+p commands|esc interrupt|Allow once'
readonly SESSION_KEY_SEP=$'\x1f'
STATE_DB_PATH=$(get_state_db_path)

to_bool() {
    local value="${1:-}"
    value=${value,,}
    [[ "$value" == "1" || "$value" == "on" || "$value" == "yes" || "$value" == "true" ]]
}

make_session_key() {
    local host="$1"
    local sid="$2"
    printf '%s%s%s' "$host" "$SESSION_KEY_SEP" "$sid"
}

session_key_host() {
    local key="$1"
    printf '%s' "${key%%"$SESSION_KEY_SEP"*}"
}

session_key_sid() {
    local key="$1"
    printf '%s' "${key#*"$SESSION_KEY_SEP"}"
}

init_generation_counter() {
    local current
    current=$(tmux show-option -gqv "$OPENCODE_GEN_OPTION" 2>/dev/null || true)
    if [[ "$current" =~ ^[0-9]+$ ]]; then
        STATE_GEN="$current"
    else
        STATE_GEN=0
    fi
}

bump_generation() {
    STATE_GEN=$(( STATE_GEN + 1 ))
    tmux set-option -g "$OPENCODE_GEN_OPTION" "$STATE_GEN" 2>/dev/null || true
}

sql_quote() {
    local s="${1:-}"
    s=${s//\'/\'\'}
    printf "'%s'" "$s"
}

sql_nullable_text() {
    local s="${1:-}"
    if [[ -n "$s" ]]; then
        sql_quote "$s"
    else
        printf 'NULL'
    fi
}

sql_nullable_int() {
    local v="${1:-}"
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%s' "$v"
    else
        printf 'NULL'
    fi
}

init_state_db() {
    sqlite3 "$STATE_DB_PATH" <<'SQL' >/dev/null 2>&1 || true
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=1000;
CREATE TABLE IF NOT EXISTS panes (
  target TEXT PRIMARY KEY,
  cmd TEXT NOT NULL,
  state TEXT NOT NULL,
  host TEXT NOT NULL,
  sid TEXT,
  title TEXT,
  dir TEXT,
  updated INTEGER
);
CREATE TABLE IF NOT EXISTS recent (
  host TEXT NOT NULL,
  sid TEXT NOT NULL,
  title TEXT,
  dir TEXT,
  updated INTEGER,
  tmux_session TEXT,
  PRIMARY KEY(host, sid)
);
SQL
}

write_panes_snapshot_sql() {
    local panes_sql="$1"
    local tmp_sql
    init_state_db
    tmp_sql=$(mktemp "$OPENCODE_STATE_DIR/state-write.XXXXXX")
    {
        printf 'BEGIN IMMEDIATE;\n'
        printf 'DELETE FROM panes;\n'
        printf '%s' "$panes_sql"
        printf 'COMMIT;\n'
    } > "$tmp_sql"

    sqlite3 "$STATE_DB_PATH" < "$tmp_sql" >/dev/null 2>&1 || true
    rm -f "$tmp_sql"
}

write_state_snapshot_sql() {
    local panes_sql="$1"
    local recent_sql="$2"
    local tmp_sql
    init_state_db
    tmp_sql=$(mktemp "$OPENCODE_STATE_DIR/state-write.XXXXXX")
    {
        printf 'BEGIN IMMEDIATE;\n'
        printf 'DELETE FROM panes;\n'
        printf '%s' "$panes_sql"
        printf 'DELETE FROM recent;\n'
        printf '%s' "$recent_sql"
        printf 'COMMIT;\n'
    } > "$tmp_sql"

    sqlite3 "$STATE_DB_PATH" < "$tmp_sql" >/dev/null 2>&1 || true
    rm -f "$tmp_sql"
}

capture_bottom3_nonblank() {
    local target="$1"
    local pane_text bottom3

    if ! pane_text=$(tmux capture-pane -t "$target" -p 2>/dev/null); then
        return 1
    fi

    bottom3=$(printf '%s\n' "$pane_text" | sed '/^[[:space:]]*$/d' | tail -3)
    [[ -n "$bottom3" ]] || return 1
    printf '%s' "$bottom3"
}

is_remote_opencode_tui() {
    local target="$1"
    local bottom3

    if ! bottom3=$(capture_bottom3_nonblank "$target"); then
        return 1
    fi

    grep -qE "$TUI_PATTERNS" <<< "$bottom3"
}

# Reads pane output and returns: running|permission|idle|unknown
detect_pane_state() {
    local target="$1"
    local cmd="$2"
    local bottom3

    if ! bottom3=$(capture_bottom3_nonblank "$target"); then
        echo "unknown"
        return
    fi

    # For remote (ssh) panes, verify this is actually an OpenCode TUI.
    if [[ "$cmd" == "ssh" ]] && ! grep -qE "$TUI_PATTERNS" <<< "$bottom3"; then
        echo "unknown"
        return
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
        [[ -z "$target" ]] && continue

        if [[ "$cmd" == "opencode" ]]; then
            new_panes+=("${target}"$'\t'"${cmd}"$'\t'"${pane_pid}"$'\t'"${pane_title}")
        elif [[ "$cmd" == "ssh" ]]; then
            if is_remote_opencode_tui "$target"; then
                new_panes+=("${target}"$'\t'"${cmd}"$'\t'"${pane_pid}"$'\t'"${pane_title}")
            fi
        fi
    done < <(tmux list-panes -a -F $'#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_command}\t#{pane_pid}\t#{pane_title}' 2>/dev/null)

    KNOWN_PANES=("${new_panes[@]+"${new_panes[@]}"}")
}

# --- Session ID extraction for local panes ---
# Walks process tree from pane_pid to find opencode child, extracts -s argument.
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

    # Parse -s / --session flag from null-delimited cmdline.
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

apply_local_fallback_mappings() {
    local db_path="$1"
    [[ -f "$db_path" ]] || return

    local -A mapped_local_sids=()
    local entry target cmd pane_pid pane_title sid key

    # Track already-mapped local session IDs so we do not reuse them.
    for entry in "${KNOWN_PANES[@]}"; do
        IFS=$'\t' read -r target cmd pane_pid pane_title <<< "$entry"
        [[ "$cmd" != "opencode" ]] && continue

        key="${SESSION_KEY_FOR_TARGET[$target]:-}"
        [[ -z "$key" ]] && continue
        if [[ "$(session_key_host "$key")" == "local" ]]; then
            sid=$(session_key_sid "$key")
            [[ -n "$sid" ]] && mapped_local_sids["$sid"]=1
        fi
    done

    # For unmapped local panes, pick newest session in pane directory.
    for entry in "${KNOWN_PANES[@]}"; do
        IFS=$'\t' read -r target cmd pane_pid pane_title <<< "$entry"
        [[ "$cmd" != "opencode" ]] && continue
        [[ -n "${SESSION_KEY_FOR_TARGET[$target]:-}" ]] && continue

        local pane_dir pane_dir_sql
        pane_dir=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
        [[ -z "$pane_dir" ]] && continue
        pane_dir_sql=${pane_dir//\'/\'\'}

        local cand_sid cand_title cand_dir cand_updated
        while IFS='|' read -r cand_sid cand_title cand_dir cand_updated; do
            [[ -z "$cand_sid" ]] && continue
            [[ -n "${mapped_local_sids[$cand_sid]:-}" ]] && continue

            key=$(make_session_key "local" "$cand_sid")
            SESSION_KEY_FOR_TARGET["$target"]="$key"
            mapped_local_sids["$cand_sid"]=1

            META_TITLE["$key"]="$cand_title"
            META_DIR["$key"]="$cand_dir"
            META_UPDATED["$key"]="$cand_updated"
            break
        done < <(sqlite3 "$db_path" "SELECT id, title, directory, time_updated FROM session WHERE directory = '$pane_dir_sql' ORDER BY time_created DESC, time_updated DESC LIMIT 15" 2>/dev/null)
    done
}

apply_remote_bindings() {
    local bindings_file

    bindings_file=$(get_bindings_file)
    [[ -f "$bindings_file" ]] || return 0

    local target host sid current_host key
    while IFS=$'\t' read -r target host sid; do
        [[ -n "$target" && -n "$host" && -n "$sid" ]] || continue

        current_host="${HOST_FOR_TARGET[$target]:-}"
        [[ -n "$current_host" && "$current_host" != "local" ]] || continue
        [[ "$current_host" == "$host" ]] || continue

        key=$(make_session_key "$host" "$sid")
        SESSION_KEY_FOR_TARGET["$target"]="$key"
    done < "$bindings_file"
}

# --- Fetch metadata from local DB + remote SSH ---
fetch_metadata() {
    local target cmd pane_pid pane_title
    local -a local_sids=()

    META_TITLE=()
    META_DIR=()
    META_UPDATED=()
    SESSION_KEY_FOR_TARGET=()

    local -A remote_hosts=()
    local -A remote_targets_for_host=()
    local -A tmux_session_for_host=()
    HOST_FOR_TARGET=()

    # Collect local session IDs and remote host inventory.
    for entry in "${KNOWN_PANES[@]}"; do
        IFS=$'\t' read -r target cmd pane_pid pane_title <<< "$entry"
        HOST_FOR_TARGET["$target"]="local"

        if [[ "$cmd" == "opencode" ]]; then
            local sid key
            sid=$(extract_local_session_id "$pane_pid")
            if [[ -n "$sid" ]]; then
                key=$(make_session_key "local" "$sid")
                local_sids+=("$sid")
                SESSION_KEY_FOR_TARGET["$target"]="$key"
            fi
        elif [[ "$cmd" == "ssh" ]]; then
            remote_hosts["$pane_title"]=1
            tmux_session_for_host["$pane_title"]="${target%%:*}"
            HOST_FOR_TARGET["$target"]="$pane_title"
            remote_targets_for_host["$pane_title"]+="${target}"$'\n'
        fi
    done

    # Load exact remote bindings persisted by picker actions.
    apply_remote_bindings

    # Local DB query: active session metadata + recent sessions.
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

            key="${SESSION_KEY_FOR_TARGET[$target]:-}"
            [[ -z "$key" ]] && continue
            [[ "$(session_key_host "$key")" == "local" ]] || continue
            sid="$(session_key_sid "$key")"
            [[ -n "$sid" ]] && local_sids+=("$sid")
        done

        # Fetch active local session metadata.
        if (( ${#local_sids[@]} > 0 )); then
            local in_clause="" sid
            for sid in "${local_sids[@]}"; do
                [[ -n "$in_clause" ]] && in_clause+=","
                in_clause+="'$sid'"
            done

            local title dir updated key
            while IFS='|' read -r sid title dir updated; do
                [[ -z "$sid" ]] && continue
                key=$(make_session_key "local" "$sid")
                META_TITLE["$key"]="$title"
                META_DIR["$key"]="$dir"
                META_UPDATED["$key"]="$updated"
            done < <(sqlite3 "$db_path" "SELECT id, title, directory, time_updated FROM session WHERE id IN ($in_clause)" 2>/dev/null)
        fi

        # Fetch recent local sessions.
        local title dir updated key
        while IFS='|' read -r sid title dir updated; do
            [[ -z "$sid" ]] && continue
            key=$(make_session_key "local" "$sid")
            META_TITLE["$key"]="$title"
            META_DIR["$key"]="$dir"
            META_UPDATED["$key"]="$updated"
        done < <(sqlite3 "$db_path" "SELECT id, title, directory, time_updated FROM session ORDER BY time_updated DESC LIMIT 21" 2>/dev/null)
    fi

    # Remote DB queries: async SSH, one per unique host.
    local remote_polling remote_mode
    remote_polling=$(get_tmux_option "$OPENCODE_REMOTE_POLLING_OPTION" "$OPENCODE_REMOTE_POLLING_DEFAULT")
    remote_mode=$(get_tmux_option "$OPENCODE_REMOTE_BINDING_MODE_OPTION" "$OPENCODE_REMOTE_BINDING_MODE_DEFAULT")

    if to_bool "$remote_polling" && (( ${#remote_hosts[@]} > 0 )); then
        local ssh_connect_timeout ssh_strict_host_key
        ssh_connect_timeout=$(get_tmux_option "$OPENCODE_SSH_CONNECT_TIMEOUT_OPTION" "$OPENCODE_SSH_CONNECT_TIMEOUT_DEFAULT")
        ssh_strict_host_key=$(get_tmux_option "$OPENCODE_SSH_STRICT_HOST_KEY_CHECKING_OPTION" "$OPENCODE_SSH_STRICT_HOST_KEY_CHECKING_DEFAULT")

        local -A remote_pids=()
        local -A remote_tmp_for_host=()
        local tmpdir
        tmpdir=$(mktemp -d)

        local host tmpfile
        for host in "${!remote_hosts[@]}"; do
            tmpfile=$(mktemp "$tmpdir/remote.XXXXXX")
            remote_tmp_for_host["$host"]="$tmpfile"

            ssh \
                -o BatchMode=yes \
                -o ConnectTimeout="$ssh_connect_timeout" \
                -o StrictHostKeyChecking="$ssh_strict_host_key" \
                "$host" \
                "sqlite3 ~/.local/share/opencode/opencode.db \"SELECT id, title, directory, time_updated FROM session ORDER BY time_updated DESC LIMIT 21\"" \
                > "$tmpfile" 2>/dev/null &
            remote_pids["$host"]=$!
        done

        # Wait for all SSH queries and parse results.
        local sid title dir updated key first_sid
        for host in "${!remote_pids[@]}"; do
            wait "${remote_pids[$host]}" 2>/dev/null || true

            tmpfile="${remote_tmp_for_host[$host]}"
            [[ -s "$tmpfile" ]] || continue

            first_sid=""
            while IFS='|' read -r sid title dir updated; do
                [[ -z "$sid" ]] && continue

                key=$(make_session_key "$host" "$sid")
                META_TITLE["$key"]="$title"
                META_DIR["$key"]="$dir"
                META_UPDATED["$key"]="$updated"

                if [[ -z "$first_sid" ]]; then
                    first_sid="$sid"
                fi
            done < "$tmpfile"

            # Optional legacy fallback: map one unbound pane on this host to latest SID.
            if [[ "$remote_mode" == "latest" && -n "$first_sid" ]]; then
                while IFS= read -r target; do
                    [[ -z "$target" ]] && continue
                    [[ -n "${SESSION_KEY_FOR_TARGET[$target]:-}" ]] && continue

                    SESSION_KEY_FOR_TARGET["$target"]="$(make_session_key "$host" "$first_sid")"
                    break
                done <<< "${remote_targets_for_host[$host]:-}"
            fi
        done

        rm -rf "$tmpdir"
    fi

    # Build pane snapshot SQL.
    local panes_sql="" state
    local sid key title dir updated host
    for entry in "${KNOWN_PANES[@]}"; do
        IFS=$'\t' read -r target cmd pane_pid pane_title <<< "$entry"
        key="${SESSION_KEY_FOR_TARGET[$target]:-}"

        sid=""
        title=""
        dir=""
        updated=""

        if [[ -n "$key" ]]; then
            sid="$(session_key_sid "$key")"
            title="${META_TITLE[$key]:-}"
            dir="${META_DIR[$key]:-}"
            updated="${META_UPDATED[$key]:-}"
        fi

        host="local"
        [[ "$cmd" == "ssh" ]] && host="$pane_title"
        state=$(detect_pane_state "$target" "$cmd")

        panes_sql+="INSERT OR REPLACE INTO panes (target, cmd, state, host, sid, title, dir, updated) VALUES ("
        panes_sql+="$(sql_quote "$target"),$(sql_quote "$cmd"),$(sql_quote "$state"),$(sql_quote "$host"),"
        panes_sql+="$(sql_nullable_text "$sid"),$(sql_nullable_text "$title"),$(sql_nullable_text "$dir"),$(sql_nullable_int "$updated")"
        panes_sql+=");"
        panes_sql+=$'\n'
    done

    local did_change=0
    if [[ "$panes_sql" != "$PREV_PANES_STATES" ]]; then
        PREV_PANES_STATES="$panes_sql"
        did_change=1
    fi

    # Build recent snapshot: all known metadata sessions minus active sessions.
    local -A active_session_keys=()
    local -A active_contexts=()

    local asid ahost atitle adir
    for target in "${!SESSION_KEY_FOR_TARGET[@]}"; do
        key="${SESSION_KEY_FOR_TARGET[$target]}"
        active_session_keys["$key"]=1

        ahost="${HOST_FOR_TARGET[$target]:-local}"
        atitle="${META_TITLE[$key]:-}"
        adir="${META_DIR[$key]:-}"
        if [[ -n "$atitle" && -n "$adir" ]]; then
            active_contexts["${ahost}|${adir}|${atitle}"]=1
        fi
    done

    # Build recent entries from all metadata.
    # Format before final render: updated|host|sid|title|dir|tmux_session
    local -a recent_entries=()
    local rsid rhost rtitle rdir rupdated rtmux_session
    for key in "${!META_TITLE[@]}"; do
        [[ -n "${active_session_keys[$key]:-}" ]] && continue

        rhost="$(session_key_host "$key")"
        rsid="$(session_key_sid "$key")"
        rtitle="${META_TITLE[$key]}"
        rdir="${META_DIR[$key]:-}"
        rupdated="${META_UPDATED[$key]:-0}"

        # Context dedupe: if an active pane already represents same host+dir+title,
        # hide duplicate from recent list.
        if [[ -n "$rtitle" && -n "$rdir" && -n "${active_contexts["${rhost}|${rdir}|${rtitle}"]:-}" ]]; then
            continue
        fi

        rtmux_session=""
        if [[ "$rhost" != "local" ]]; then
            rtmux_session="${tmux_session_for_host[$rhost]:-}"
        fi

        recent_entries+=("${rupdated}|${rhost}|${rsid}|${rtitle}|${rdir}|${rtmux_session}")
    done

    # Sort by time_updated descending, take top 20 and materialize SQL snapshot.
    local recent_sql=""
    if (( ${#recent_entries[@]} > 0 )); then
        while IFS='|' read -r ts host sid title dir tmux_session; do
            [[ -z "$host" || -z "$sid" ]] && continue
            recent_sql+="INSERT OR REPLACE INTO recent (host, sid, title, dir, updated, tmux_session) VALUES ("
            recent_sql+="$(sql_quote "$host"),$(sql_quote "$sid"),$(sql_nullable_text "$title"),$(sql_nullable_text "$dir"),$(sql_nullable_int "$ts"),$(sql_nullable_text "$tmux_session")"
            recent_sql+=");"
            recent_sql+=$'\n'
        done < <(printf '%s\n' "${recent_entries[@]}" | sort -t'|' -k1 -rn | head -20)
    fi

    if [[ "$recent_sql" != "$PREV_RECENT_STATES" ]]; then
        PREV_RECENT_STATES="$recent_sql"
        did_change=1
    fi

    if (( did_change )); then
        write_state_snapshot_sql "$panes_sql" "$recent_sql"
        bump_generation
    fi
}

# --- Update pill + pane states ---
update_pill() {
    local count=${#KNOWN_PANES[@]}
    if (( count == 0 )); then
        local pill="idle|0"
        if [[ -n "$PREV_PANES_STATES" ]]; then
            PREV_PANES_STATES=""
            write_panes_snapshot_sql ""
            bump_generation
        fi
        if [[ "$pill" != "$PREV_PILL" ]]; then
            tmux set-option -g "$OPENCODE_PILL_OPTION" "$pill" 2>/dev/null || true
            tmux refresh-client -S 2>/dev/null || true
            PREV_PILL="$pill"
        fi
        return
    fi

    local permission_count=0 running_count=0
    local panes_sql="" target cmd pane_pid pane_title state
    local sid key title dir updated host

    for entry in "${KNOWN_PANES[@]}"; do
        IFS=$'\t' read -r target cmd pane_pid pane_title <<< "$entry"
        state=$(detect_pane_state "$target" "$cmd")

        case "$state" in
            permission) (( permission_count++ )) || true ;;
            running) (( running_count++ )) || true ;;
        esac

        key="${SESSION_KEY_FOR_TARGET[$target]:-}"
        sid=""
        title=""
        dir=""
        updated=""
        if [[ -n "$key" ]]; then
            sid="$(session_key_sid "$key")"
            title="${META_TITLE[$key]:-}"
            dir="${META_DIR[$key]:-}"
            updated="${META_UPDATED[$key]:-}"
        fi

        host="local"
        [[ "$cmd" == "ssh" ]] && host="$pane_title"

        panes_sql+="INSERT OR REPLACE INTO panes (target, cmd, state, host, sid, title, dir, updated) VALUES ("
        panes_sql+="$(sql_quote "$target"),$(sql_quote "$cmd"),$(sql_quote "$state"),$(sql_quote "$host"),"
        panes_sql+="$(sql_nullable_text "$sid"),$(sql_nullable_text "$title"),$(sql_nullable_text "$dir"),$(sql_nullable_int "$updated")"
        panes_sql+=");"
        panes_sql+=$'\n'
    done

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

    if [[ "$panes_sql" != "$PREV_PANES_STATES" ]]; then
        PREV_PANES_STATES="$panes_sql"
        write_panes_snapshot_sql "$panes_sql"
        bump_generation
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
last_heartbeat=0

# Initial pass
init_generation_counter
init_state_db
discover_panes
fetch_metadata
update_pill

while true; do
    now=$(date +%s)

    # Heartbeat once per second so callers can detect stale daemon state.
    if (( now - last_heartbeat >= 1 )); then
        tmux set-option -g "$OPENCODE_DAEMON_TS_OPTION" "$now" 2>/dev/null || true
        last_heartbeat=$now
    fi

    # Discovery tier
    if (( now - last_discovery >= DISCOVERY_INTERVAL_S )); then
        discover_panes
        last_discovery=$now
    fi

    # Metadata tier
    if (( now - last_metadata >= METADATA_INTERVAL_S )); then
        fetch_metadata
        last_metadata=$now
    fi

    # Local fallback tier
    if (( now - last_local_map >= LOCAL_MAP_INTERVAL_S )); then
        db_path_now=$(get_db_path)
        apply_local_fallback_mappings "$db_path_now"
        last_local_map=$now
    fi

    # Fast tier
    update_pill
    sleep "$FAST_INTERVAL_S"
done
