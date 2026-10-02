#!/usr/bin/env bash
#
# lint-java.sh — format and check Java files after Claude edits them.
#
# Hook:     PostToolUse (Edit | Write)
# Requires: jq, google-java-format, checkstyle, pmd
#           (brew install google-java-format checkstyle pmd)
#
# What it does, in order:
#   1. google-java-format  Rewrites the file in Google Java style.
#                          Stops here if the file has syntax errors.
#   2. Checkstyle          Checks style rules: naming, Javadoc, empty blocks...
#   3. PMD                 Checks for bugs and code smells.
#   All problems found are sent back to Claude together.
#   If any tool isn't installed, asks Claude to install it instead.
#
# These run in one script, not three, because hooks run in parallel:
# the checks must only start after the file has been formatted.
#
# Exit codes:
#   0  No problems, or skipped (not a Java file).
#   2  Problems found, or tools missing. Claude Code shows stderr to Claude
#      so it can act on it.

# --- Rule sets (change these to use your own) -------------------------------
CHECKSTYLE_CONFIG="/google_checks.xml"          # built into Checkstyle
PMD_RULESET="rulesets/java/quickstart.xml"      # built into PMD

# --- Get the edited file's path ---------------------------------------------
file=$(jq -r '.tool_input.file_path // empty')

[[ "$file" == *.java ]] || exit 0   # not a Java file
[[ -f "$file" ]] || exit 0          # file no longer exists

# --- Ask Claude to install any missing tools --------------------------------
missing=()
for tool in google-java-format checkstyle pmd; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "dev-toolkit: $file was not checked; missing: ${missing[*]}." >&2
  echo "Install them with: brew install ${missing[*]}" >&2
  exit 2
fi

# --- 1. Format --------------------------------------------------------------
if ! output=$(google-java-format --replace "$file" 2>&1); then
  echo "dev-toolkit: google-java-format could not parse $file:" >&2
  echo "$output" >&2
  exit 2
fi

problems=""

# --- 2. Checkstyle ----------------------------------------------------------
# Checkstyle exits 0 even when it reports warnings, so look for them instead.
output=$(checkstyle -c "$CHECKSTYLE_CONFIG" "$file" 2>&1)
findings=$(echo "$output" | grep -E '^\[(WARN|ERROR)\]')
if [[ -n "$findings" ]]; then
  problems+=$'\nCheckstyle:\n'"$findings"$'\n'
fi

# --- 3. PMD -----------------------------------------------------------------
# PMD exits 4 when it finds violations, and 0 when it finds none.
output=$(pmd check --no-progress --no-cache -f text \
  -R "$PMD_RULESET" -d "$file" 2>&1)
if [[ $? -ne 0 ]]; then
  problems+=$'\nPMD:\n'"$output"$'\n'
fi

# --- Report -----------------------------------------------------------------
if [[ -n "$problems" ]]; then
  echo "dev-toolkit: problems found in $file:" >&2
  echo "$problems" >&2
  exit 2
fi

exit 0
