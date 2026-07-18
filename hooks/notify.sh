#!/usr/bin/env bash
# notify.sh — Stop hook.
# Plays a short sound when Claude finishes responding, so the turn end is
# noticeable while you're looking elsewhere. Best-effort only: skips silently
# if the sound file or player is missing, and always exits 0 so it can never
# block the Stop event.
set -uo pipefail

SOUND="$HOME/.claude/sounds/notification.mp3"

[[ -f "$SOUND" ]] || exit 0
command -v afplay >/dev/null 2>&1 || exit 0

# Play detached so the hook returns immediately instead of blocking for the
# full length of the clip.
afplay "$SOUND" >/dev/null 2>&1 &

exit 0
