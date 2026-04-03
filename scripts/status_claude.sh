#!/usr/bin/env bash
set -euo pipefail

pill=$(tmux show-option -gqv "@agents-claude-pill" 2>/dev/null)
state="${pill%%|*}"
count="${pill#*|}"
: "${state:=idle}" "${count:=0}"

get_opt() {
  local val
  val=$(tmux show-option -gqv "$1" 2>/dev/null)
  echo "${val:-$2}"
}

color_yellow=$(get_opt "@thm_yellow" "#f9e2af")
color_green=$(get_opt "@thm_green" "#a6e3a1")
color_crust=$(get_opt "@thm_crust" "#1e1e2e")
color_white="#dadada"

if [[ "$count" == "0" ]]; then
  printf '#[fg=%s,bg=default] 󰚩  %s #[default] ' "$color_white" "$count"
  exit 0
fi

case "$state" in
permission) bg="$color_yellow" ;;
running)    bg="$color_green" ;;
*)          bg="$color_white" ;;
esac

printf '#[fg=%s,bg=default]#[fg=%s,bg=%s,bold]󰚩  %s#[fg=%s,bg=default]#[default] ' \
  "$bg" "$color_crust" "$bg" "$count" "$bg"
