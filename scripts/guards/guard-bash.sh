#!/usr/bin/env bash
#
# guard-bash.sh — block obviously destructive shell commands, and ask before
# deleting folders.
#
# Hook:     PreToolUse (Bash)
# Requires: jq
#
# What it does:
#   1. Reads the command Claude is about to run from the hook's JSON input.
#   2. Blocks it if it matches a dangerous pattern (delete the disk or home
#      folder, force-push to main, format a disk, fork bomb).
#   3. Asks you first if it deletes a folder and everything in it:
#        rm -r / -rf / --recursive, find ... -delete or -exec rm, git clean
#      Folders that are safe to throw away are deleted without asking:
#      build output and caches (see `throwaway` below), and temp folders.
#
# This is a safety net for obvious mistakes, not a security boundary:
# it matches text, so a reworded command or a script can get past it.
#
# Exit codes:
#   0  Allowed, or "ask" printed as JSON for Claude Code to prompt you.
#   2  Blocked. Claude Code shows stderr to Claude.

# --- 1. Get the command -----------------------------------------------------
cmd=$(jq -r '.tool_input.command // empty')

# --- 2. Always blocked (extended regex) -------------------------------------
patterns=(
  'rm -rf /( |$)'                                # delete the whole disk
  'rm -rf ~( |/?$)'                              # delete the home folder
  'git push (.* )?--force( |$).*(main|master)'   # force-push to main/master
  'mkfs\.'                                       # format a disk
  ':\(\)\{ :\|:& \};:'                           # fork bomb
)

for pattern in "${patterns[@]}"; do
  if echo "$cmd" | grep -Eq "$pattern"; then
    echo "dev-toolkit: blocked dangerous command matching /$pattern/" >&2
    exit 2
  fi
done

# --- 3. Ask before deleting a folder ----------------------------------------
# Folder names that are fine to delete without asking (edit this list).
throwaway=(node_modules dist build target out coverage .cache .next .nuxt
           .turbo .gradle __pycache__ .pytest_cache)

ask() {
  jq -nc --arg why "dev-toolkit: $1. Check it before allowing." '{hookSpecificOutput: {
    hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $why}}'
  exit 0
}

# True if a path is a throwaway folder, inside one, or in a temp folder.
is_throwaway() {
  local path=$1 name
  [[ "$path" == *..* || "$path" == *'$'* ]] && return 1   # can't tell where it points
  case "$path" in
    /tmp/* | /private/tmp/* | /var/folders/* | /private/var/folders/*) return 0 ;;
  esac
  for name in "${throwaway[@]}"; do
    [[ "/$path/" == */"$name"/* ]] && return 0
  done
  return 1
}

# Check each simple command on its own (split at ; & | and line breaks).
while IFS= read -r part; do
  read -ra words <<<"$(tr '"'"'"'()' ' ' <<<"$part")"
  case " ${words[*]} " in
    *" git clean "*)
      [[ " ${words[*]} " == *" -n "* || " ${words[*]} " == *" --dry-run "* ]] ||
        ask "git clean deletes untracked files" ;;
    *" find "*" -delete "* | *" find "*" -exec rm "* | *" find "*" -execdir rm "*)
      ask "find deletes every file it matches" ;;
  esac

  # rm: find it (also after sudo or xargs), then its flags and folders.
  recursive=false targets=() seen_rm=false from_xargs=false end_of_flags=false
  for word in "${words[@]}"; do
    if [[ $seen_rm == false ]]; then
      [[ "$word" == xargs ]] && from_xargs=true
      [[ "$word" == rm ]] && seen_rm=true
      continue
    fi
    if [[ $end_of_flags == false && "$word" == -* ]]; then
      [[ "$word" == -- ]] && end_of_flags=true
      [[ "$word" == --recursive || ( "$word" != --* && "$word" == -*[rR]* ) ]] && recursive=true
    else
      targets+=("$word")
    fi
  done
  [[ $seen_rm == true && $recursive == true ]] || continue

  [[ $from_xargs == true ]] && ask "rm -r deletes folders read from another command"
  for target in "${targets[@]}"; do
    is_throwaway "$target" || ask "this deletes the folder '$target' and everything in it"
  done
done < <(tr ';&|' '\n\n\n' <<<"$cmd")

exit 0
