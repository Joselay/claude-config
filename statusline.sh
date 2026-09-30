#!/usr/bin/env bash
# Claude Code status line.
# Reads the session JSON on stdin and prints one line:
#   <dir>  <branch>  <model>  Context <tokens>k left  Session [bar] <used>%  Weekly [bar] <used>%
# Runs on Claude Code's event-driven updates only (no refreshInterval needed).
# All fields degrade gracefully when data is absent (e.g. before the first API
# response, or rate_limits on plans that don't report them).
# Field reference: https://code.claude.com/docs/en/statusline#available-data

input=$(cat)

# --- Night Owl theme colors (true-color, matches Ghostty's Night Owl palette) ---
DIM=$'\033[2m'
RESET=$'\033[0m'
rgb() { printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"; }
BLUE=$(rgb 130 170 255)     # #82aaff — directory
ORANGE=$(rgb 247 140 108)   # #f78c6c — git branch
MAGENTA=$(rgb 199 146 234)  # #c792ea — model
TEAL=$(rgb 127 219 202)     # #7fdbca — context
GREEN=$(rgb 34 218 110)     # #22da6e — session
PINK=$(rgb 255 134 154)     # #ff869a — weekly
SEP="${DIM} • ${RESET}"

# --- Parse every session field in ONE jq pass (one subprocess instead of six).
# Fields are joined on US (\x1f, a non-whitespace control char) rather than tab
# so that empty fields are preserved positionally — with tab, `read` would
# collapse a leading empty field and shift every value left. \x1f can't appear
# in any of these values, so splitting is safe. Numbers are finished in jq:
# percentages round down so 100% only appears when a limit is truly hit,
# and every field tolerates null so one missing value can't blank the line. ---
IFS=$'\x1f' read -r current_dir model effort ctx_left five_used five_reset seven_used seven_reset <<< "$(
  printf '%s' "$input" | jq -r '[
    (.workspace.current_dir // .workspace.project_dir // ""),
    (.model.display_name // "?"),
    (.effort.level // ""),
    (.context_window as $c
     | if $c.current_usage == null or $c.context_window_size == null then ""
       else [$c.context_window_size - ($c.total_input_tokens // 0), 0] | max end),
    (.rate_limits.five_hour.used_percentage // "" | if type == "number" then floor else . end),
    (.rate_limits.five_hour.resets_at // "" | if type == "number" then floor else . end),
    (.rate_limits.seven_day.used_percentage // "" | if type == "number" then floor else . end),
    (.rate_limits.seven_day.resets_at // "" | if type == "number" then floor else . end)
  ] | map(tostring) | join("")'
)"

# --- Current directory (full path, home replaced with ~) ---
if [ -n "$current_dir" ]; then
  case "$current_dir" in
    "$HOME"/*) dir_str="~${current_dir#$HOME}" ;;
    "$HOME") dir_str="~" ;;
    *) dir_str="$current_dir" ;;
  esac
else
  dir_str="?"
fi

# --- Git branch (empty when not a repo / detached HEAD — --show-current prints
# nothing in those cases, so no extra guarding is needed) ---
branch_str=""
[ -n "$current_dir" ] && branch_str=$(git -C "$current_dir" branch --show-current 2>/dev/null)

# --- Model (with reasoning effort, when supported) ---
if [ -n "$effort" ]; then
  model="${model} (${effort})"
fi

# --- Context window remaining in tokens. Empty before the first API response and
# right after /compact (current_usage is null then), so show "--" instead of a
# misleading full window. total_input_tokens already includes cache reads/writes,
# matching how Claude Code computes used_percentage. ---
if [ -n "$ctx_left" ]; then
  if [ "$ctx_left" -ge 1000 ]; then
    ctx_str="Context $(( ctx_left / 1000 ))k left"
  else
    ctx_str="Context ${ctx_left} left"
  fi
else
  ctx_str="Context --k left"
fi

# --- Rate-limit cache. rate_limits only arrive after the first API response, so
# persist the last known values and reuse them at startup to keep the line's
# shape stable. Limits are account-wide, so sharing across sessions is correct.
# A cached window whose resets_at has passed is shown as 0%. ---
CACHE="$HOME/.claude/.statusline-ratelimits"
if [ -n "$five_used" ] || [ -n "$seven_used" ]; then
  if [ -z "$five_used" ] || [ -z "$seven_used" ]; then
    [ -r "$CACHE" ] && IFS=' ' read -r c5u c5r c7u c7r < "$CACHE"
  fi
  [ -z "$five_used" ] && five_used="${c5u:-}" && five_reset="${c5r:-}"
  [ -z "$seven_used" ] && seven_used="${c7u:-}" && seven_reset="${c7r:-}"
  printf '%s %s %s %s\n' "${five_used:--}" "${five_reset:--}" "${seven_used:--}" "${seven_reset:--}" \
    > "$CACHE.$$" && mv -f "$CACHE.$$" "$CACHE"
elif [ -r "$CACHE" ]; then
  IFS=' ' read -r five_used five_reset seven_used seven_reset < "$CACHE"
fi
now=$(date +%s)
for v in five_used five_reset seven_used seven_reset; do
  [ "${!v}" = "-" ] && printf -v "$v" '%s' ""
done
[ -n "$five_used" ] && [ -n "$five_reset" ] && [ "$five_reset" -le "$now" ] && five_used=0
[ -n "$seven_used" ] && [ -n "$seven_reset" ] && [ "$seven_reset" -le "$now" ] && seven_used=0

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

# --- Helper: format a rate-limit window "label [bar] used%" (caller skips it
# when absent: rate_limits is only sent to Pro/Max after the first API response,
# and each window is dropped once its resets_at passes) ---
fmt_window() {
  local label="$1" used_int="$2"
  local bar
  if [ -z "$used_int" ]; then
    printf '%s [%s] --%%' "$label" "$(render_bar 0)"
    return
  fi
  bar=$(render_bar "$used_int")
  printf '%s [%s] %s%%' "$label" "$bar" "$used_int"
}

# --- Assemble ---
segments=("${BLUE}${dir_str}${RESET}")
[ -n "$branch_str" ] && segments+=("${ORANGE}${branch_str}${RESET}")
segments+=(
  "${MAGENTA}${model}${RESET}"
  "${TEAL}${ctx_str}${RESET}"
)
segments+=(
  "${GREEN}$(fmt_window "Session" "$five_used")${RESET}"
  "${PINK}$(fmt_window "Weekly" "$seven_used")${RESET}"
)

out=""
for i in "${!segments[@]}"; do
  [ "$i" -gt 0 ] && out="${out}${SEP}"
  out="${out}${segments[$i]}"
done
printf '%s' "$out"
