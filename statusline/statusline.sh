#!/usr/bin/env bash
# Claude Code status line.
# Reads the session JSON on stdin and prints one line:
#   <project dir>  <model>  Context <remaining>% left  Session [bar] <used>%  Weekly [bar] <used>%
# All fields degrade gracefully when data is absent (e.g. before the first API response).

input=$(cat)

# --- Night Owl theme colors (true-color, matches Ghostty's Night Owl palette) ---
DIM=$'\033[2m'
RESET=$'\033[0m'
rgb() { printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"; }
BLUE=$(rgb 130 170 255)     # #82aaff — project dir
ORANGE=$(rgb 247 140 108)   # #f78c6c — git branch
MAGENTA=$(rgb 199 146 234)  # #c792ea — model
TEAL=$(rgb 127 219 202)     # #7fdbca — context
GREEN=$(rgb 34 218 110)     # #22da6e — session
PINK=$(rgb 255 134 154)     # #ff869a — weekly
SEP="${DIM} • ${RESET}"

# --- Parse every session field in ONE jq pass. This script re-runs every few
# seconds (refreshInterval), so a single invocation instead of seven keeps the
# idle subprocess overhead minimal. Fields are joined on US (\x1f, a non-
# whitespace control char) rather than tab so that empty fields are preserved
# positionally — with tab, `read` would collapse a leading empty field and shift
# every value left. \x1f can't appear in any of these values, so splitting is safe. ---
IFS=$'\x1f' read -r project_dir model effort ctx_size ctx_used five_used seven_used <<< "$(
  printf '%s' "$input" | jq -r '[
    (.workspace.project_dir // .workspace.current_dir // .cwd // ""),
    (.model.display_name // "?"),
    (.effort.level // ""),
    (.context_window.context_window_size // ""),
    (.context_window.total_input_tokens // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.seven_day.used_percentage // "")
  ] | map(tostring) | join("")'
)"

# --- Project directory (full path, home replaced with ~) ---
if [ -n "$project_dir" ]; then
  case "$project_dir" in
    "$HOME"/*) dir_str="~${project_dir#$HOME}" ;;
    "$HOME") dir_str="~" ;;
    *) dir_str="$project_dir" ;;
  esac
else
  dir_str="?"
fi

# --- Git branch (empty when not a repo / detached HEAD — --show-current prints
# nothing in those cases, so no extra guarding is needed) ---
branch_str=""
[ -n "$project_dir" ] && branch_str=$(git -C "$project_dir" branch --show-current 2>/dev/null)

# --- Model (with reasoning effort, when supported) ---
if [ -n "$effort" ]; then
  model="${model} (${effort})"
fi

# --- Context window remaining (tokens) ---
if [ -n "$ctx_size" ] && [ -n "$ctx_used" ]; then
  ctx_remaining=$(( ctx_size - ctx_used ))
  if [ "$ctx_remaining" -ge 1000 ]; then
    ctx_str="Context $(( ctx_remaining / 1000 ))k left"
  else
    ctx_str="Context ${ctx_remaining} left"
  fi
else
  ctx_str="Context --"
fi

# --- Helper: render a simple text progress bar ---
render_bar() {
  local pct="$1" width=10
  local filled=$(( pct * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  local empty=$(( width - filled ))
  local bar=""
  local i
  for (( i = 0; i < filled; i++ )); do bar="${bar}█"; done
  for (( i = 0; i < empty; i++ )); do bar="${bar}░"; done
  printf '%s' "$bar"
}

# --- Helper: format a rate-limit window "label [bar] used%" ---
fmt_window() {
  local label="$1" used="$2"
  local used_int=0
  if [ -n "$used" ] && [ "$used" != "null" ]; then
    used_int=$(printf '%.0f' "$used")
  fi
  local bar
  bar=$(render_bar "$used_int")
  printf '%s [%s] %s%%' "$label" "$bar" "$used_int"
}

five_str=$(fmt_window "Session" "$five_used")
week_str=$(fmt_window "Weekly" "$seven_used")

# --- Assemble ---
segments=("${BLUE}${dir_str}${RESET}")
[ -n "$branch_str" ] && segments+=("${ORANGE}${branch_str}${RESET}")
segments+=(
  "${MAGENTA}${model}${RESET}"
  "${TEAL}${ctx_str}${RESET}"
  "${GREEN}${five_str}${RESET}"
  "${PINK}${week_str}${RESET}"
)

out=""
for i in "${!segments[@]}"; do
  [ "$i" -gt 0 ] && out="${out}${SEP}"
  out="${out}${segments[$i]}"
done
printf '%s' "$out"
