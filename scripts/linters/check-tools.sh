#!/usr/bin/env bash
#
# check-tools.sh — ask Claude to install any missing linters.
#
# Hook:     SessionStart
# Requires: nothing
#
# What it does:
#   Checks that every linter this plugin uses is installed. If any are
#   missing, it tells Claude to install them before starting work.
#   Anything this hook prints to stdout is added to Claude's context.
#
#   The install command still goes through the normal permission prompt.
#   If a tool is still missing later, the lint-*.sh scripts remind Claude.
#
# Exit codes:
#   0  Always. This hook never blocks.

# --- Tools used by the lint-*.sh scripts ------------------------------------
required=(
  jq                   # reads hook input (all scripts)
  google-java-format   # lint-java.sh
  checkstyle           # lint-java.sh
  pmd                  # lint-java.sh
  yamllint             # lint-config.sh
)

# --- Find any that are missing ----------------------------------------------
missing=()
for tool in "${required[@]}"; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done

# --- Ask Claude to install them ---------------------------------------------
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "dev-toolkit: these linters are not installed: ${missing[*]}."
  echo "Before starting the user's task, install them by running:"
  echo "  brew install ${missing[*]}"
fi

exit 0
