#!/usr/bin/env bash
#
# notify-desktop.sh — desktop notification when Claude needs you or finishes
# a long task.
#
# Hooks:    UserPromptSubmit  records when the turn started
#           Stop              notifies if the turn took LONG_TURN_SECONDS or more
#           Notification      notifies when Claude is waiting for you
#                             (permission_prompt | idle_prompt |
#                              elicitation_dialog | agent_needs_input)
# Requires: jq, and osascript (macOS, built in) or notify-send (Linux,
#           package libnotify-bin / libnotify)
#
# What it does:
#   - Claude needs you   Always notifies, urgently (a sound on macOS, stays
#                        on screen on Linux): nothing happens until you respond.
#   - Claude finished    Only after long turns, so quick replies you're
#                        watching don't ping you.
#   The title includes the project folder, to tell sessions apart.
#
#   Notifications are sent by the OS, not the terminal, so they work in
#   VS Code too. On macOS, the first one may need permission: allow
#   notifications for "Script Editor" in System Settings → Notifications.
#
# Exit codes:
#   0  Always. A notification must never block Claude.

# --- Settings ---------------------------------------------------------------
LONG_TURN_SECONDS=300   # notify "finished" only after turns this long (5 min)
NEEDS_YOU_SOUND="Glass" # macOS sound for "needs you"; "" for silent

# --- Read the hook input once -----------------------------------------------
input=$(cat)
field() { jq -r ".$1 // empty" <<<"$input"; }

event=$(field hook_event_name)
project=$(basename "$(field cwd)")
start_file="${TMPDIR:-/tmp}/dev-toolkit-turn-$(field session_id)"

# Show a notification: notify <title> <message> <urgent: yes|no>
# Urgent ones play NEEDS_YOU_SOUND on macOS and stay on screen on Linux.
# Text is passed as arguments, never pasted into a command, so quotes in
# Claude's messages can't break it.
notify() {
  local title=$1 message=$2 urgent=$3

  if command -v osascript >/dev/null; then                    # macOS
    local sound=""
    [[ "$urgent" == yes ]] && sound=$NEEDS_YOU_SOUND
    osascript - "$title" "$message" "$sound" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set {theTitle, theMessage, theSound} to argv
  if theSound is "" then
    display notification theMessage with title theTitle
  else
    display notification theMessage with title theTitle sound name theSound
  end if
end run
APPLESCRIPT
  elif command -v notify-send >/dev/null; then                # Linux
    local urgency=normal
    [[ "$urgent" == yes ]] && urgency=critical
    notify-send --urgency="$urgency" --app-name="Claude Code" \
      "$title" "$message" >/dev/null 2>&1
  fi
  # Neither found (e.g. a server with no desktop): do nothing.
}

# --- Act on the event -------------------------------------------------------
case "$event" in

  UserPromptSubmit)
    date +%s > "$start_file"
    ;;

  Stop)
    [[ -f "$start_file" ]] || exit 0
    elapsed=$(( $(date +%s) - $(cat "$start_file") ))
    rm -f "$start_file"
    (( elapsed >= LONG_TURN_SECONDS )) || exit 0

    # First line of Claude's reply, shortened to fit a notification.
    summary=$(field last_assistant_message | head -1 | cut -c1-120)
    notify "Claude finished · $project ($((elapsed / 60)) min)" "${summary:-Done}" no
    ;;

  Notification)
    notify "Claude needs you · $project" "$(field message)" yes
    ;;

esac

exit 0
