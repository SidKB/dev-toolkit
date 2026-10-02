#!/usr/bin/env bash
#
# lint-config.sh — check JSON and YAML files after Claude edits them.
#
# Hook:     PostToolUse (Edit | Write)
# Requires: jq        (ships with macOS)
#           yamllint  (brew install yamllint)
#
# What it does:
#   1. Reads the edited file's path from the hook's JSON input.
#   2. .json        -> checks it is valid JSON with `jq empty`.
#      .yaml / .yml -> lints it with yamllint.
#   3. Sends any errors back to Claude. Files are never modified.
#      If yamllint isn't installed, asks Claude to install it.
#
# Exit codes:
#   0  File is valid, or was skipped.
#   2  File has errors, or yamllint is missing. Claude Code shows stderr
#      to Claude so it can act on it.

# --- 1. Get the edited file's path ------------------------------------------
file=$(jq -r '.tool_input.file_path // empty')
[[ -f "$file" ]] || exit 0

# Print the linter's output to stderr and tell Claude Code to report it.
report_errors() {
  local tool=$1 output=$2
  echo "dev-toolkit: $tool found problems in $file:" >&2
  echo "$output" >&2
  exit 2
}

# --- 2. Pick a check based on the file type ---------------------------------
case "$file" in

  *.jsonc)
    exit 0   # JSON with comments; jq would wrongly reject it
    ;;

  *.json)
    # These .json files also allow comments, so skip them too.
    case "$file" in
      */tsconfig*.json | */jsconfig*.json | */.vscode/*.json | */.devcontainer/*.json)
        exit 0 ;;
    esac

    # `jq empty` prints nothing for valid JSON, and an error otherwise.
    if ! output=$(jq empty "$file" 2>&1); then
      report_errors "jq" "$output"
    fi
    ;;

  *.yaml | *.yml)
    if ! command -v yamllint >/dev/null; then
      echo "dev-toolkit: yamllint is not installed, so $file was not checked." >&2
      echo "Install it with: brew install yamllint" >&2
      exit 2
    fi

    # Use the project's own yamllint config if it has one.
    # Otherwise use the built-in "relaxed" rules, which only fail on real
    # errors (bad syntax, duplicate keys), not on style.
    config=(-d relaxed)
    for name in .yamllint .yamllint.yaml .yamllint.yml; do
      [[ -f "$name" ]] && config=()
    done

    # yamllint exits non-zero only for errors; warnings alone pass.
    if ! output=$(yamllint "${config[@]}" -f parsable "$file" 2>&1); then
      report_errors "yamllint" "$output"
    fi
    ;;

esac

exit 0
