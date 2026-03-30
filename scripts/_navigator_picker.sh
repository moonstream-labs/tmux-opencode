#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

MODE=""
OPENCODE_RENDER_COLS=""
while (( $# > 0 )); do
    case "$1" in
        --render-active|--render-recent)
            MODE="$1"
            ;;
        --cols)
            if (( $# > 1 )); then
                OPENCODE_RENDER_COLS="$2"
                shift
            fi
            ;;
    esac
    shift
done

# --- Color setup ---
get_opt() {
    local val
    val=$(tmux show-option -gqv "$1" 2>/dev/null)
    echo "${val:-$2}"
}

CLR_YELLOW=$(get_opt "@thm_yellow" "#f9e2af")
CLR_GREEN=$(get_opt "@thm_green" "#a6e3a1")
CLR_WHITE="#dadada"
CLR_DIM=$(get_opt "@thm_overlay_0" "#6c7086")
CLR_TEXT=$(get_opt "@thm_fg" "#cdd6f4")

ansi_fg() { printf '\033[38;2;%d;%d;%dm' "0x${1:1:2}" "0x${1:3:2}" "0x${1:5:2}"; }

FG_YELLOW=$(ansi_fg "$CLR_YELLOW")
FG_GREEN=$(ansi_fg "$CLR_GREEN")
FG_WHITE=$(ansi_fg "$CLR_WHITE")
FG_DIM=$(ansi_fg "$CLR_DIM")
FG_TEXT=$(ansi_fg "$CLR_TEXT")
RST="\033[0m"

# --- Layout: fixed budgeted column widths ---
get_cols() {
    if [[ -n "$OPENCODE_RENDER_COLS" && "$OPENCODE_RENDER_COLS" =~ ^[0-9]+$ ]]; then
        echo "$OPENCODE_RENDER_COLS"
        return
    fi

    local cols
    cols=$(tmux display-message -p '#{pane_width}' 2>/dev/null || true)
    if [[ -n "$cols" && "$cols" =~ ^[0-9]+$ ]]; then
        echo "$cols"
        return
    fi

    tput cols 2>/dev/null || echo 80
}

COLS=$(get_cols)

# Visible overhead for row rendering:
# - leading state dot: 1 char
# - 2-space gap before each of 5 columns: 10 chars
OVERHEAD=11
SAFETY_COLS=2
PAD_TARGET=$(( COLS - SAFETY_COLS ))
(( PAD_TARGET < 20 )) && PAD_TARGET=20

COL_BUDGET=$(( PAD_TARGET - OVERHEAD ))
(( COL_BUDGET < 20 )) && COL_BUDGET=20

# Desired widths
C_SESSION=30
C_DIR=30
C_HOST=10
C_TMUX=20
C_AGE=10

# Minimum widths
MIN_SESSION=10
MIN_DIR=10
MIN_HOST=6
MIN_TMUX=8
MIN_AGE=6

total_cols=$(( C_SESSION + C_DIR + C_HOST + C_TMUX + C_AGE ))
deficit=$(( total_cols - COL_BUDGET ))

if (( deficit > 0 )); then
    reducible=$(( C_SESSION - MIN_SESSION ))
    (( reducible < 0 )) && reducible=0
    dec=$(( deficit < reducible ? deficit : reducible ))
    C_SESSION=$(( C_SESSION - dec ))
    deficit=$(( deficit - dec ))
fi

if (( deficit > 0 )); then
    reducible=$(( C_DIR - MIN_DIR ))
    (( reducible < 0 )) && reducible=0
    dec=$(( deficit < reducible ? deficit : reducible ))
    C_DIR=$(( C_DIR - dec ))
    deficit=$(( deficit - dec ))
fi

if (( deficit > 0 )); then
    reducible=$(( C_TMUX - MIN_TMUX ))
    (( reducible < 0 )) && reducible=0
    dec=$(( deficit < reducible ? deficit : reducible ))
    C_TMUX=$(( C_TMUX - dec ))
    deficit=$(( deficit - dec ))
fi

if (( deficit > 0 )); then
    reducible=$(( C_HOST - MIN_HOST ))
    (( reducible < 0 )) && reducible=0
    dec=$(( deficit < reducible ? deficit : reducible ))
    C_HOST=$(( C_HOST - dec ))
    deficit=$(( deficit - dec ))
fi

if (( deficit > 0 )); then
    reducible=$(( C_AGE - MIN_AGE ))
    (( reducible < 0 )) && reducible=0
    dec=$(( deficit < reducible ? deficit : reducible ))
    C_AGE=$(( C_AGE - dec ))
    deficit=$(( deficit - dec ))
fi

if (( deficit > 0 )); then
    while (( deficit > 0 && C_SESSION > 3 )); do
        C_SESSION=$(( C_SESSION - 1 ))
        deficit=$(( deficit - 1 ))
    done
fi

if (( deficit > 0 )); then
    while (( deficit > 0 && C_DIR > 3 )); do
        C_DIR=$(( C_DIR - 1 ))
        deficit=$(( deficit - 1 ))
    done
fi

# --- Truncation helpers ---
truncate_str() {
    local str="$1" max="$2"
    if (( ${#str} > max )); then
        echo "${str:0:$((max-3))}..."
    else
        echo "$str"
    fi
}

decode_field() {
    local s="${1:-}"
    s=${s//%0D/}
    s=${s//%0A/ }
    s=${s//%7C/|}
    s=${s//%25/%}
    printf '%s' "$s"
}

shell_quote() {
    local s="${1:-}"
    s=${s//\'/\'"\'"\'}
    printf "'%s'" "$s"
}

normalize_path() {
    local p="${1:-}"
    [[ -z "$p" ]] && return
    p="${p%/}"
    [[ -z "$p" ]] && p="/"
    readlink -f -- "$p" 2>/dev/null || printf '%s' "$p"
}

short_dir() {
    local dir="$1"
    dir="${dir/#$HOME/~}"
    # Keep last 2 path segments
    local parts
    parts=$(awk -F'/' '{if(NF>2) print $(NF-1)"/"$NF; else print $0}' <<< "$dir")
    truncate_str "$parts" "$C_DIR"
}

# --- Pad line to full width for highlight ---
pad_line() {
    local line="$1"
    # Strip ANSI codes to count visible length
    local visible
    visible=$(sed 's/\x1b\[[0-9;]*m//g' <<< "$line")
    local vlen=${#visible}
    local padding=$(( PAD_TARGET - vlen ))
    (( padding > 0 )) && printf '%s%*s' "$line" "$padding" "" || printf '%s' "$line"
}

# --- Sort helper: order by state priority then by time_updated desc ---
# Input: lines of "sort_key|rest" where sort_key = "priority updated"
# priority: 0=permission, 1=running, 2=idle
state_priority() {
    case "$1" in
        permission) echo 0 ;;
        running)    echo 1 ;;
        *)          echo 2 ;;
    esac
}

# --- Render active sessions from @opencode-panes ---
render_active() {
    local panes_data
    panes_data=$(tmux show-option -gqv "$OPENCODE_PANES_OPTION" 2>/dev/null)
    if [[ -z "$panes_data" ]]; then
        return
    fi

    # Header
    local hdr
    hdr=$(printf ' %b  %-*s  %-*s  %-*s  %-*s  %-*s%b' \
        "$FG_DIM" \
        "$C_SESSION" "session" \
        "$C_DIR" "directory" \
        "$C_HOST" "host" \
        "$C_TMUX" "tmux-session" \
        "$C_AGE" "active" \
        "$RST")
    printf '%s\t%s\n' "__HEADER__" "$(pad_line "$hdr")"

    # Collect rows with sort keys
    local -a sortable=()
    while IFS='|' read -r target cmd state host sid title dir updated; do
        [[ -z "$target" ]] && continue

        title=$(decode_field "$title")
        dir=$(decode_field "$dir")

        local pri
        pri=$(state_priority "$state")
        local ts="${updated:-0}"

        # State circle color
        local circle_color
        case "$state" in
            permission) circle_color="$FG_YELLOW" ;;
            running)    circle_color="$FG_GREEN" ;;
            *)          circle_color="$FG_WHITE" ;;
        esac

        # Format fields
        local s_title s_dir s_host age tmux_ses
        s_title=$(truncate_str "$title" "$C_SESSION")
        s_dir=$(short_dir "$dir")
        s_host=$(truncate_str "$host" "$C_HOST")
        tmux_ses=$(truncate_str "${target%%:*}" "$C_TMUX")
        age=""
        if [[ -n "$updated" && "$updated" =~ ^[0-9]+$ ]]; then
            age=$(truncate_str "$(format_age "$(( updated / 1000 ))")" "$C_AGE")
        fi

        local row
        row=$(printf '%b●%b  %b%-*s%b  %b%-*s%b  %b%-*s%b  %b%-*s%b  %b%-*s%b' \
            "$circle_color" "$RST" \
            "$FG_TEXT" "$C_SESSION" "$s_title" "$RST" \
            "$FG_DIM" "$C_DIR" "$s_dir" "$RST" \
            "$FG_TEXT" "$C_HOST" "$s_host" "$RST" \
            "$FG_DIM" "$C_TMUX" "$tmux_ses" "$RST" \
            "$FG_DIM" "$C_AGE" "$age" "$RST")

        sortable+=("${pri}|${ts}|${target}"$'\t'"$(pad_line "$row")")
    done <<< "$panes_data"

    # Sort: by priority asc, then timestamp desc
    printf '%s\n' "${sortable[@]}" | sort -t'|' -k1,1n -k2,2rn | while IFS='|' read -r _pri _ts rest; do
        echo "$rest"
    done
}

# --- Render recent sessions from @opencode-recent ---
render_recent() {
    local recent_data
    recent_data=$(tmux show-option -gqv "$OPENCODE_RECENT_OPTION" 2>/dev/null)
    if [[ -z "$recent_data" ]]; then
        printf '%s\t%s\n' "__HEADER__" "$(pad_line "  No recent sessions found.")"
        return
    fi

    # Header
    local hdr
    hdr=$(printf ' %b  %-*s  %-*s  %-*s  %-*s  %-*s%b' \
        "$FG_DIM" \
        "$C_SESSION" "session" \
        "$C_DIR" "directory" \
        "$C_HOST" "host" \
        "$C_TMUX" "tmux-session" \
        "$C_AGE" "active" \
        "$RST")
    printf '%s\t%s\n' "__HEADER__" "$(pad_line "$hdr")"

    # Data rows: host|sid|title|dir|updated|tmux_session
    while IFS='|' read -r host sid title dir updated remote_tmux_session; do
        [[ -z "$sid" ]] && continue

        title=$(decode_field "$title")
        dir=$(decode_field "$dir")

        local s_title s_dir s_host age tmux_ses
        s_title=$(truncate_str "$title" "$C_SESSION")
        s_dir=$(short_dir "$dir")
        s_host=$(truncate_str "$host" "$C_HOST")
        tmux_ses="-"
        if [[ -n "${remote_tmux_session:-}" ]]; then
            tmux_ses=$(truncate_str "$remote_tmux_session" "$C_TMUX")
        fi
        age=""
        if [[ -n "$updated" && "$updated" =~ ^[0-9]+$ ]]; then
            age=$(truncate_str "$(format_age "$(( updated / 1000 ))")" "$C_AGE")
        fi

        local row
        row=$(printf '%b●%b  %b%-*s%b  %b%-*s%b  %b%-*s%b  %b%-*s%b  %b%-*s%b' \
            "$FG_DIM" "$RST" \
            "$FG_TEXT" "$C_SESSION" "$s_title" "$RST" \
            "$FG_DIM" "$C_DIR" "$s_dir" "$RST" \
            "$FG_TEXT" "$C_HOST" "$s_host" "$RST" \
            "$FG_DIM" "$C_TMUX" "$tmux_ses" "$RST" \
            "$FG_DIM" "$C_AGE" "$age" "$RST")

        printf 'recent:%s:%s:%s\t%s\n' "$host" "$sid" "${remote_tmux_session:-}" "$(pad_line "$row")"
    done <<< "$recent_data"
}

# --- Handle render-only modes for fzf reload ---
case "$MODE" in
    --render-active) render_active; exit 0 ;;
    --render-recent) render_recent; exit 0 ;;
esac

# --- Initial render ---
initial_rows=$(render_active)
if [[ -z "$initial_rows" ]]; then
    echo "No OpenCode sessions found."
    echo "Press Enter to close."
    read -r
    exit 0
fi

# --- fzf listen port ---
FZF_PORT=$(( 16384 + $(id -u) % 10000 ))
ensure_state_dir
MODE_FILE="$OPENCODE_STATE_DIR/picker-mode-$$"
printf 'active' > "$MODE_FILE"

# --- Background watcher: auto-reload on state changes ---
_state_watcher() {
    local last_panes last_recent
    last_panes=$(tmux show-option -gqv "$OPENCODE_PANES_OPTION" 2>/dev/null || true)
    last_recent=$(tmux show-option -gqv "$OPENCODE_RECENT_OPTION" 2>/dev/null || true)
    while true; do
        sleep 0.1
        local current_panes current_recent mode
        current_panes=$(tmux show-option -gqv "$OPENCODE_PANES_OPTION" 2>/dev/null || true)
        current_recent=$(tmux show-option -gqv "$OPENCODE_RECENT_OPTION" 2>/dev/null || true)
        if [[ "$current_panes" != "$last_panes" || "$current_recent" != "$last_recent" ]]; then
            last_panes="$current_panes"
            last_recent="$current_recent"
            mode=$(cat "$MODE_FILE" 2>/dev/null || echo "active")
            if [[ "$mode" == "recent" ]]; then
                reload_cmd="bash $CURRENT_DIR/_navigator_picker.sh --render-recent --cols $COLS"
            else
                reload_cmd="bash $CURRENT_DIR/_navigator_picker.sh --render-active --cols $COLS"
            fi
            curl -sf -XPOST "localhost:$FZF_PORT" \
                -d "reload($reload_cmd)" >/dev/null 2>&1 || true
        fi
    done
}

_state_watcher &
watcher_pid=$!

cleanup() {
    kill "$watcher_pid" 2>/dev/null || true
    rm -f "$MODE_FILE"
}
trap cleanup EXIT

# --- Launch fzf with arrow key view toggle ---
selection=$(echo "$initial_rows" | fzf \
    --listen="$FZF_PORT" \
    --ansi \
    --with-nth='2..' \
    --delimiter=$'\t' \
    --no-sort \
    --reverse \
    --no-info \
    --prompt='  ' \
    --marker='' \
    --pointer='' \
    --no-scrollbar \
    --border=none \
    --header-lines=1 \
    --bind='ctrl-c:abort,esc:abort' \
    --bind="right:execute-silent(printf recent > $MODE_FILE)+reload(bash $CURRENT_DIR/_navigator_picker.sh --render-recent --cols $COLS)" \
    --bind="left:execute-silent(printf active > $MODE_FILE)+reload(bash $CURRENT_DIR/_navigator_picker.sh --render-active --cols $COLS)" \
) || exit 0

# --- Handle selection ---
key=$(cut -f1 <<< "$selection")
[[ "$key" == "__HEADER__" ]] && exit 0

# --- Active session: navigate to tmux pane ---
if [[ "$key" != recent:* ]]; then
    # key format after sort stripping: "target\t..."
    # Extract target (may have leading sort remnants stripped by --with-nth)
    local_target="$key"
    tmux_session="${local_target%%:*}"
    window_pane="${local_target#*:}"
    tmux select-window -t "${tmux_session}:${window_pane%%.*}" 2>/dev/null || true
    tmux select-pane -t "$local_target" 2>/dev/null || true
    tmux switch-client -t "$tmux_session" 2>/dev/null || true
    exit 0
fi

# --- Recent session: open session ---
# key format: "recent:host:session_id:tmux_session"
IFS=':' read -r _recent_tag recent_host recent_sid recent_tmux_session <<< "$key"

current_cmd=$(tmux display-message -p '#{pane_current_command}' 2>/dev/null || true)
current_path=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || true)
current_title=$(tmux display-message -p '#{pane_title}' 2>/dev/null || true)

recent_dir=""
while IFS='|' read -r host sid _title dir _updated _tmux_session; do
    if [[ "$host" == "$recent_host" && "$sid" == "$recent_sid" ]]; then
        recent_dir=$(decode_field "$dir")
        break
    fi
done <<< "$(tmux show-option -gqv "$OPENCODE_RECENT_OPTION" 2>/dev/null || true)"

recent_cmd="opencode -s $(shell_quote "$recent_sid")"
if [[ -n "$recent_dir" ]]; then
    recent_cmd="cd -- $(shell_quote "$recent_dir") && $recent_cmd"
fi

if [[ "$recent_host" == "local" ]]; then
    current_path_norm=$(normalize_path "$current_path")
    recent_path_norm=$(normalize_path "$recent_dir")

    if [[ "$current_cmd" =~ ^(zsh|bash|fish|sh)$ ]] &&
       [[ -n "$current_path_norm" && -n "$recent_path_norm" ]] &&
       [[ "$current_path_norm" == "$recent_path_norm" ]]; then
        tmux send-keys "$recent_cmd" Enter
    elif [[ -n "$recent_dir" && -d "$recent_dir" ]]; then
        tmux new-window -c "$recent_dir" "opencode -s '$recent_sid'"
    else
        tmux new-window "opencode -s '$recent_sid'"
    fi
else
    if [[ "$current_cmd" == "ssh" ]] &&
       [[ "$current_title" == "$recent_host" ]]; then
        tmux send-keys "$recent_cmd" Enter
        exit 0
    fi

    # Remote recent session: prefer mapped tmux session from daemon metadata.
    local_tmux_session="$recent_tmux_session"
    if [[ -z "$local_tmux_session" ]]; then
        while IFS=$'\t' read -r ptarget pcmd ptitle; do
            if [[ "$pcmd" == "ssh" && "$ptitle" == "$recent_host" ]]; then
                local_tmux_session="${ptarget%%:*}"
                break
            fi
        done < <(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}	#{pane_current_command}	#{pane_title}' 2>/dev/null)
    fi

    if [[ -n "$local_tmux_session" ]]; then
        # Open in the same tmux session that has SSH panes to this host
        tmux new-window -t "$local_tmux_session" "ssh -t $(shell_quote "$recent_host") $(shell_quote "$recent_cmd")"
        tmux switch-client -t "$local_tmux_session" 2>/dev/null || true
    else
        # Fallback: open in current session
        tmux new-window "ssh -t $(shell_quote "$recent_host") $(shell_quote "$recent_cmd")"
    fi
fi
