#!/usr/bin/env bash
#
# restore-context.sh — after compaction, re-add your own messages and the
# git state so Claude doesn't lose your decisions.
#
# Hook:     SessionStart (compact)
# Requires: jq, git (optional)
# Toggle:   /config → dev-toolkit → "Restore context after compaction"
#           (plugin option restore_context, on by default)
#
# Why this exists:
#   Compaction replaces old messages with a summary. Facts about the code are
#   easy to recover by re-reading files, but your decisions and corrections
#   ("skip that", "macOS and Linux only") exist only in the conversation and
#   get blurred in the summary. This puts your exact words back.
#
# What it does:
#   1. Reads your messages from the session transcript. Compaction doesn't
#      remove them from the file, so nothing needs to be saved beforehand.
#      Claude's replies, tool output and IDE context are left out.
#   2. Adds the git branch, uncommitted changes and recent commits.
#   3. Prints it all to stdout, which Claude Code adds to Claude's context.
#
#   Output must stay under Claude Code's 10,000-character hook limit, so each
#   message is shortened and, if they still don't fit, the middle ones are
#   dropped: the first ones (early decisions) and the latest ones are kept.
#
# Exit codes:
#   0  Always. Never blocks.

# --- Settings ---------------------------------------------------------------
MAX_MESSAGE_CHARS=300    # each message is shortened to this
MAX_MESSAGES_CHARS=7000  # total budget for messages (git state uses the rest)
KEEP_FIRST=10            # when over budget, always keep this many first messages

# --- Off switch -------------------------------------------------------------
# Claude Code exports plugin options as CLAUDE_PLUGIN_OPTION_<KEY>.
case "${CLAUDE_PLUGIN_OPTION_RESTORE_CONTEXT:-true}" in
  false | 0 | no | off) exit 0 ;;
esac

input=$(cat)   # stdin can only be read once
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")

# --- 1. Your messages, oldest first, one per line ---------------------------
# Typed messages are "user" entries; messages sent while Claude was working
# are "queued_command" attachments. Skipped: tool results, Claude Code's own
# entries (meta, compaction summary, /commands) and IDE/system tags.
messages=$(jq -r --argjson max "$MAX_MESSAGE_CHARS" '
  def text_of: if type == "string" then .
               else [.[]? | select(.type == "text") | .text] | join(" ") end;
  (if .type == "user" and (.isMeta | not) and (.isCompactSummary | not)
   then .message.content | text_of
   elif .type == "attachment" and .attachment.type == "queued_command"
   then .attachment.prompt | text_of
   else empty end)
  | gsub("(?s)<(ide_[a-z_]+|system-reminder)>.*?</\\1>"; "")
  | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")
  | select(length > 0)
  | select((startswith("<command-") or startswith("<local-command")) | not)
  | if length > $max then .[0:$max] + "…" else . end
' "$transcript" 2>/dev/null)

# Over budget: keep the first KEEP_FIRST and as many of the latest as fit.
if (( ${#messages} > MAX_MESSAGES_CHARS )); then
  first=$(head -n "$KEEP_FIRST" <<<"$messages")
  budget=$(( MAX_MESSAGES_CHARS - ${#first} ))
  latest=""
  while IFS= read -r line; do
    (( ${#latest} + ${#line} + 1 > budget )) && break
    latest="$line"$'\n'"$latest"
  done < <(tail -n +"$((KEEP_FIRST + 1))" <<<"$messages" |
           awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }')
  # (awk reverses the lines portably; `tac` and `tail -r` each exist on only
  # one of Linux and macOS.)
  messages="$first"$'\n'"[… earlier messages omitted …]"$'\n'"${latest%$'\n'}"
fi

# --- 2. Git state -----------------------------------------------------------
git_state=""
if [[ -n "$cwd" ]] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  # symbolic-ref also works with no commits yet; detached HEAD shows the commit.
  branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null ||
           git -C "$cwd" rev-parse --short HEAD 2>/dev/null | sed 's/^/detached at /')
  changes=$(git -C "$cwd" status --short 2>/dev/null | head -30)
  commits=$(git -C "$cwd" log --oneline -5 2>/dev/null)
  git_state="Branch: $branch"
  [[ -n "$changes" ]] && git_state+=$'\n'"Uncommitted changes:"$'\n'"$changes"
  [[ -n "$commits" ]] && git_state+=$'\n'"Recent commits:"$'\n'"$commits"
fi

# --- 3. Print for Claude ----------------------------------------------------
[[ -z "$messages" && -z "$git_state" ]] && exit 0

echo "dev-toolkit: the conversation was just compacted. Below are the user's own"
echo "messages from this session, word for word (shortened), oldest first."
echo "Where the summary disagrees with them, the messages win; where they"
echo "disagree with each other, the later message wins. Keep following every"
echo "decision and correction in them."
if [[ -n "$messages" ]]; then
  echo
  echo "## User's messages"
  sed 's/^/- /' <<<"$messages"
fi
if [[ -n "$git_state" ]]; then
  echo
  echo "## Working state"
  echo "$git_state"
fi

exit 0
