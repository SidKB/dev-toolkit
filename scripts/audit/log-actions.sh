#!/usr/bin/env bash
#
# log-actions.sh — audit trail of what Claude runs or changes.
#
# Hooks:    PostToolUse         the action succeeded
#           PostToolUseFailure  the action failed
#           PermissionDenied    the action was denied
#           Matcher for all three: ^(Bash|Edit|Write|NotebookEdit|mcp__.*)$
#           (anchored, so TodoWrite and read-only tools are left out)
# Requires: jq
# Toggle:   /config → dev-toolkit → "Log Claude's actions" (log_actions, on)
#
# Kept as cheap as possible: one jq call per action, nothing printed (so no
# tokens), and the size check runs only about once every 200 actions.
#
# What it does:
#   Appends one JSON line per action to
#     ~/.claude/plugins/data/dev-toolkit-local-plugins/actions.jsonl
#   with: time, session, folder, tool, target, result (ok / failed / denied),
#   and agent, error or reason when they apply.
#     target   Bash: the command, secrets masked · Edit/Write: the file path
#              · MCP tools: left out (inputs can hold anything)
#
#   Never logged: file contents, edit text, command output.
#   Secrets masked: Bearer/Basic tokens, *KEY= / *TOKEN= / *PASSWORD= values,
#   --password style flags, URL passwords, -u / --user user:password (curl),
#   sk- / ghp_ / github_pat_ / xox*- /
#   AKIA tokens. Pattern-based, so an unusual secret can still get through.
#
# Exit codes:
#   0  Always. Logging never blocks Claude.

MAX_LINES=20000

case "${CLAUDE_PLUGIN_OPTION_LOG_ACTIONS:-true}" in false | 0 | no | off) exit 0 ;; esac

data_dir="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/dev-toolkit-local-plugins}"
log_file="$data_dir/actions.jsonl"
[[ -d "$data_dir" ]] || mkdir -p "$data_dir"

# (jq only passes named groups to a replacement, hence (?<keep>...).)
jq -c '
  def mask:
    gsub("(?i)(?<keep>(bearer|basic|token)\\s+)[^\\s\"'\'']+"; "\(.keep)***")
    | gsub("(?i)(?<keep>\\b([A-Z0-9]+_)*(apikey|key|token|secret|password|passwd|pwd|auth)(_[A-Z0-9_]*)?\\s*[=:]\\s*)[^\\s\"'\'']+"; "\(.keep)***")
    | gsub("(?i)(?<keep>--?(password|passwd|token|secret|api-?key|key)[= ])[^\\s\"'\'']+"; "\(.keep)***")
    | gsub("://[^/\\s:@]+:[^/\\s@]+@"; "://***@")
    | gsub("(?<keep>(^|\\s)(-u|--user)[= ]\\s*[\"'\'']?[^\\s:\"'\'']+:)[^\\s\"'\'']+"; "\(.keep)***")
    | gsub("(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|xox[abpors]-[A-Za-z0-9-]{8,}|AKIA[0-9A-Z]{16})"; "***")
    | .[0:500];

  {
    time: (now | todate),
    session: .session_id,
    folder: .cwd,
    tool: .tool_name,
    target: (if .tool_name == "Bash" then (.tool_input.command // "" | mask)
             elif (.tool_name | startswith("mcp__")) then null
             else (.tool_input.file_path // .tool_input.notebook_path) end),
    result: ({PostToolUse: "ok", PostToolUseFailure: "failed",
              PermissionDenied: "denied"}[.hook_event_name] // .hook_event_name),
    agent: .agent_type,
    error: (.error // null | if . then tostring | mask | .[0:200] else . end),
    reason: (.reason // null | if . then tostring | mask | .[0:200] else . end)
  } | with_entries(select(.value != null))
' >> "$log_file" 2>/dev/null

# Trim about once every 200 actions instead of counting lines every time.
if (( RANDOM % 200 == 0 )) && (( $(wc -l < "$log_file") > MAX_LINES )); then
  tail -n "$MAX_LINES" "$log_file" > "$log_file.tmp" && mv "$log_file.tmp" "$log_file"
fi

exit 0
