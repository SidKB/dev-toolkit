#!/usr/bin/env bash
#
# audit-config.sh — log every change to settings and skill files, and undo
# changes that would switch off this toolkit's protection.
#
# Hooks:    SessionStart (startup|resume|clear)  saves a copy of each settings
#                                                file to compare against later
#           ConfigChange                          logs, and maybe blocks, a change
# Requires: jq
# Toggle:   /config → dev-toolkit → "Audit config changes" (audit_config, on)
#
# The other guards check Claude's own tool calls. This one watches the config
# files themselves, so it also sees changes from an editor, another tool or a
# script.
#
# What it does on ConfigChange:
#   1. Logs the names of the settings that changed (never their values:
#      settings can hold secrets in "env") to
#        ~/.claude/plugins/data/dev-toolkit-local-plugins/config-changes.jsonl
#   2. Blocks the change and puts the file back to its last good copy if it:
#        - sets disableAllHooks to true
#        - removes a protected-file deny rule (see protect-files.sh)
#        - disables the dev-toolkit plugin
#        - sets permissions.defaultMode to bypassPermissions
#   3. Blocks invalid JSON for this session but leaves the file alone, so a
#      half-typed edit saved by auto-save isn't lost.
#
#   Policy (managed) settings can't be blocked; they are only logged.
#   To make a blocked change on purpose, turn the toggle off first.
#
# Exit codes:
#   0  Change allowed (or not a ConfigChange event).
#   2  Change blocked. Claude Code shows stderr to the user.

MAX_LOG_LINES=5000

case "${CLAUDE_PLUGIN_OPTION_AUDIT_CONFIG:-true}" in false | 0 | no | off) exit 0 ;; esac

data_dir="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/dev-toolkit-local-plugins}"
snapshot_dir="$data_dir/config-snapshots"
script_dir=$(cd "$(dirname "$0")" && pwd)

input=$(cat)   # stdin can only be read once
field() { jq -r ".$1 // empty" <<<"$input"; }

# The saved copy of a file. A missing file is saved as {} plus a marker, so
# restoring it means deleting the file again. cksum is on macOS and Linux.
snapshot_of() { echo "$snapshot_dir/$(cksum <<<"$1" | cut -d' ' -f1).json"; }

save_snapshot() {
  local copy; copy=$(snapshot_of "$1")
  mkdir -p "$snapshot_dir"
  if [[ -f "$1" ]]; then cp "$1" "$copy"; rm -f "$copy.absent"
  else echo '{}' > "$copy"; touch "$copy.absent"; fi
}

restore_snapshot() {
  local copy; copy=$(snapshot_of "$1")
  if [[ -f "$copy.absent" ]]; then rm -f "$1"
  elif [[ -f "$copy" ]]; then cp "$copy" "$1"
  else return 1; fi
}

# --- SessionStart: save a copy of every settings file this session uses ------
if [[ "$(field hook_event_name)" == "SessionStart" ]]; then
  project="${CLAUDE_PROJECT_DIR:-$(field cwd)}"
  for f in "$HOME/.claude/settings.json" \
           "$project/.claude/settings.json" \
           "$project/.claude/settings.local.json"; do
    save_snapshot "$f"
  done
  exit 0
fi

[[ "$(field hook_event_name)" == "ConfigChange" ]] || exit 0

source=$(field source)
file=$(field file_path)
reason=""        # why the change is blocked; empty means allowed
restore=true     # put the file back when blocking

# --- Work out what changed ---------------------------------------------------
if [[ "$source" == "skills" ]]; then
  changes=$([[ -f "$file" ]] && echo '["changed"]' || echo '["deleted"]')

elif ! new=$(jq -c . "$file" 2>/dev/null || { [[ ! -f "$file" ]] && echo '{}'; }) ||
     [[ -z "$new" ]]; then   # unreadable, or empty (e.g. mid-save)
  changes='["invalid JSON"]'
  reason="the file is not valid JSON, so Claude Code would ignore all of its settings"
  restore=false

else
  old=$(cat "$(snapshot_of "$file")" 2>/dev/null || echo '{}')

  # Settings flattened to dotted names (permissions.deny, env.API_URL);
  # lists are compared as sets and reported as counts, never contents.
  changes=$(jq -nc --argjson old "$old" --argjson new "$new" '
    def flat: [paths(type != "object") as $p
               | select(all($p[]; type == "string"))
               | {key: ($p | join(".")), value: getpath($p)}] | from_entries;
    ($old | flat) as $o | ($new | flat) as $n
    | [ ($n | keys[] | select(. as $k | $o | has($k) | not) | "added " + .),
        ($o | keys[] | select(. as $k | $n | has($k) | not) | "removed " + .),
        ($n | keys[] | select(. as $k | ($o | has($k)) and $o[$k] != $n[$k]) as $k
         | if ($n[$k] | type) == "array" and ($o[$k] | type) == "array"
           then "changed \($k) (\($n[$k] - $o[$k] | length) added, \($o[$k] - $n[$k] | length) removed)"
           else "changed " + $k end) ]')

  # The four rules. Each only fires when the change introduces the problem.
  rules=$("$script_dir/protect-files.sh" --deny-rules | jq -R . | jq -sc .)
  reason=$(jq -nr --argjson old "$old" --argjson new "$new" --argjson rules "$rules" '
    def toolkit_off: [(.enabledPlugins // {}) | to_entries[]
                      | select((.key | startswith("dev-toolkit@")) and .value == false)] | length > 0;
    if $new.disableAllHooks == true and $old.disableAllHooks != true then
      "it sets disableAllHooks to true, which turns off every guard and linter"
    elif [$rules[] | select(IN($old.permissions.deny[]?) and (IN($new.permissions.deny[]?) | not))] | length > 0 then
      "it removes protected-file deny rules, which would let searches show .env and key files again"
    elif ($new | toolkit_off) and (($old | toolkit_off) | not) then
      "it disables the dev-toolkit plugin"
    elif $new.permissions.defaultMode == "bypassPermissions" and $old.permissions.defaultMode != "bypassPermissions" then
      "it sets permissions.defaultMode to bypassPermissions, which skips all permission checks"
    else empty end')
fi

[[ "$source" == "policy_settings" ]] && reason=""   # can't be blocked

# Nothing changed, e.g. the event caused by our own restore.
[[ -z "$reason" && "$changes" == "[]" ]] && exit 0

# --- Decide ------------------------------------------------------------------
if [[ -z "$reason" ]]; then
  decision=allowed
elif [[ $restore == false ]]; then
  decision="blocked"
elif restore_snapshot "$file"; then
  decision="blocked, file restored"
else
  decision="blocked, could not restore"
fi

# --- Log, capped at MAX_LOG_LINES --------------------------------------------
log_file="$data_dir/config-changes.jsonl"
mkdir -p "$data_dir"
jq -nc --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg session "$(field session_id)" \
       --arg source "$source" --arg file "$file" --argjson changes "$changes" \
       --arg decision "$decision" --arg reason "$reason" \
  '{time: $time, session: $session, source: $source, file: $file,
    decision: $decision, changes: $changes} + (if $reason != "" then {reason: $reason} else {} end)' \
  >> "$log_file"
if (( $(wc -l < "$log_file") > MAX_LOG_LINES )); then
  tail -n "$MAX_LOG_LINES" "$log_file" > "$log_file.tmp" && mv "$log_file.tmp" "$log_file"
fi

# --- Allow, or block and explain ---------------------------------------------
if [[ $decision == allowed ]]; then
  [[ "$source" != "skills" ]] && save_snapshot "$file"
  exit 0
fi

echo "dev-toolkit: blocked a change to $file — $reason." >&2
case "$decision" in
  "blocked, file restored") echo "The file has been put back to its last good version." >&2 ;;
  "blocked")                echo "This session keeps the old settings. Fix the file and save again." >&2 ;;
  *)                        echo "Couldn't restore the file: undo the change yourself." >&2 ;;
esac
echo "To make this change on purpose, turn off \"Audit config changes\" in /config first." >&2
exit 2
