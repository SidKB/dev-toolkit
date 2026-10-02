#!/usr/bin/env bash
#
# sync-deny-rules.sh — keep Claude Code's deny rules in sync with the
# protected-files list in protect-files.sh.
#
# Hook:     SessionStart
# Requires: jq
# Usage:    sync-deny-rules.sh            check (what the hook runs)
#           sync-deny-rules.sh --install  add any missing rules
#
# Why this exists:
#   protect-files.sh can only allow or block a whole tool call. A search over
#   the whole project would either leak protected files in its results or
#   have to be blocked entirely. Claude Code's deny rules work inside the
#   search and drop protected files from the results.
#
#   Plugins can't ship deny rules, so they have to live in the user's
#   ~/.claude/settings.json. This script keeps them in sync with the
#   pattern list in protect-files.sh, which stays the only list to edit.
#
# Exit codes:
#   0  Always. The check never blocks; it tells the user what's missing.

settings="$HOME/.claude/settings.json"
script_dir=$(cd "$(dirname "$0")" && pwd)

# --- Rules the patterns need, and rules already in settings -----------------
expected=$("$script_dir/protect-files.sh" --deny-rules)
current=$(jq -r '.permissions.deny[]?' "$settings" 2>/dev/null)
missing=$(grep -vxF -f <(echo "$current") <<<"$expected")

[[ -z "$missing" ]] && exit 0

# --- --install: merge the missing rules into settings -----------------------
if [[ "$1" == "--install" ]]; then
  [[ -f "$settings" ]] || echo '{}' > "$settings"
  cp "$settings" "$settings.bak"
  jq --argjson new "$(jq -R . <<<"$missing" | jq -s .)" \
    '.permissions.deny = ((.permissions.deny // []) + $new)' \
    "$settings.bak" > "$settings"
  echo "Added $(wc -l <<<"$missing" | tr -d ' ') deny rules to $settings (backup: $settings.bak)."
  exit 0
fi

# --- Default: report what's missing (stdout goes to Claude's context) -------
echo "dev-toolkit: $(wc -l <<<"$missing" | tr -d ' ') deny rules for protected files are missing"
echo "from ~/.claude/settings.json, so project-wide searches can show their contents."
echo "Tell the user to run this in a terminal (Claude can't run it for them):"
echo "  \"$script_dir/sync-deny-rules.sh\" --install"
exit 0
