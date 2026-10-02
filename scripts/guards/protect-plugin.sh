#!/usr/bin/env bash
#
# protect-plugin.sh — stop Claude from changing installed plugins.
#
# Hook:     PreToolUse (Edit | Write | Bash)
# Requires: jq
#
# What it does:
#   Blocks any edit to this plugin's installed files, and any Bash command
#   that touches the installed-plugins folder (~/.claude/plugins). This stops
#   Claude from switching off or weakening these hooks.
#
#   The plugin's source folder is NOT protected, so you can still ask Claude
#   to work on the plugin there. Changes only take effect after you reinstall.
#
#   Files can still be read with the Read tool.
#
# Exit codes:
#   0  Allowed.
#   2  Blocked. Claude Code shows stderr to Claude.

# This script lives in <plugin root>/scripts/guards/, so the root is two levels up.
plugin_root=$(cd "$(dirname "$0")/../.." && pwd)
plugins_dir=".claude/plugins"

block() {
  echo "dev-toolkit: blocked — $1. Ask the user to make this change." >&2
  exit 2
}

# Read the hook input once; stdin can only be read a single time.
input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$input")

case "$tool" in

  Edit | Write)
    file=$(jq -r '.tool_input.file_path // empty' <<<"$input")
    if [[ "$file" == "$plugin_root"/* || "$file" == *"/$plugins_dir/"* ]]; then
      block "installed plugin files can't be edited"
    fi
    ;;

  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
    if [[ "$cmd" == *"$plugin_root"* || "$cmd" == *"$plugins_dir"* ]]; then
      block "commands can't touch the installed plugins folder"
    fi
    ;;

esac

exit 0
