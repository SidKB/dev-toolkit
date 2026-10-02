#!/usr/bin/env bash
#
# session-start.sh — tell Claude which git branch it's working on.
#
# Hook:     SessionStart
# Requires: git
#
# Anything this script prints to stdout is added to Claude's context
# at the start of the session. Outside a git repo it prints nothing.
#
# Exit codes:
#   0  Always.

# symbolic-ref also works in a new repo with no commits yet; a detached
# HEAD has no branch, so show the commit instead.
branch=$(git symbolic-ref --short HEAD 2>/dev/null ||
         git rev-parse --short HEAD 2>/dev/null | sed 's/^/detached at /')

if [[ -n "$branch" ]]; then
  echo "dev-toolkit: current git branch is '$branch'."
fi

exit 0
