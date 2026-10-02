#!/usr/bin/env bash
#
# show-actions.sh — read the audit trail written by log-actions.sh.
#
# Not a hook: run it yourself in a terminal.
# Requires: jq
#
# Usage:    show-actions.sh [options]
#   --today            only today's actions (local date, as the table shows)
#   --failed           only failed or denied actions
#   --project NAME     only actions in a folder whose name contains NAME
#   --last N           show the latest N matching actions (default 30)
#   --json             print the matching lines as raw JSON instead of a table
#
# Examples:
#   show-actions.sh --today --failed
#   show-actions.sh --project my-app --last 100
#
# Exit codes:
#   0  Shown (possibly nothing matched).
#   1  Bad option, or no log yet.

# Claude Code names the data folder <plugin>-<marketplace> (dev-toolkit-local-plugins,
# or dev-toolkit-inline for --plugin-dir). Outside a hook, use the latest one written to.
if [[ -n "$CLAUDE_PLUGIN_DATA" ]]; then
  log_file="$CLAUDE_PLUGIN_DATA/actions.jsonl"
else
  log_file=$(ls -t "$HOME"/.claude/plugins/data/dev-toolkit-*/actions.jsonl 2>/dev/null | head -n 1)
fi

today="" failed=false project="" last=30 json=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --today)   today=$(date +%Y-%m-%d) ;;
    --failed)  failed=true ;;
    --project) project=$2; shift ;;
    --last)    last=$2; shift ;;
    --json)    json=true ;;
    -h|--help) sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
  shift
done

[[ -f "$log_file" ]] || { echo "No audit log yet in ~/.claude/plugins/data/dev-toolkit-*/" >&2; exit 1; }

# --- Filter ------------------------------------------------------------------
matches=$(jq -c --arg today "$today" --argjson failed "$failed" \
                --arg project "$project" '
  select($today   == "" or (.time | try (fromdateiso8601 | strflocaltime("%Y-%m-%d")) catch "") == $today)
  | select(($failed | not) or .result != "ok")
  | select($project == "" or (.folder // "" | split("/") | last | contains($project)))
' "$log_file" | tail -n "$last")

[[ -z "$matches" ]] && { echo "No matching actions."; exit 0; }
[[ $json == true ]] && { echo "$matches"; exit 0; }

# --- Table -------------------------------------------------------------------
# One row per action: local time, result, project, tool (and subagent, if one
# did it), what it acted on, and the error or reason if it failed or was denied.
# Line breaks and tabs inside a field are flattened so each action stays one row.
jq -r '
  def cut($n): if length > $n then .[0:$n - 1] + "…" else . end;
  def cut_left($n): if length > $n then "…" + .[length - $n + 1:] else . end;  # keeps the file name
  def flat: tostring | gsub("\\s+"; " ");
  [ (.time | try (fromdateiso8601 | strflocaltime("%m-%d %H:%M")) catch "?"),
    (.result // "?" | {ok: "ok", failed: "FAILED", denied: "DENIED"}[.] // .),
    (.folder // "" | split("/") | last | cut(14)),
    ((.tool // "-" | sub("^mcp__"; "mcp:")) + (if .agent then " (\(.agent))" else "" end) | cut(22)),
    (.target // "" | flat | if startswith("/") then cut_left(60) else cut(60) end),
    (.error // .reason // "" | flat | cut(40)) ]
  | @tsv
' <<<"$matches" | awk -F'\t' '
  BEGIN { printf "%-11s  %-6s  %-14s  %-22s  %-60s  %s\n", "TIME", "RESULT", "PROJECT", "TOOL", "TARGET", "DETAIL" }
        { printf "%-11s  %-6s  %-14s  %-22s  %-60s  %s\n", $1, $2, $3, $4, $5, $6 }'
