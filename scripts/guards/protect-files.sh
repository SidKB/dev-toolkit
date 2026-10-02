#!/usr/bin/env bash
#
# protect-files.sh — stop Claude from reading, writing or deleting protected files.
#
# Hook:     PreToolUse (Read | Edit | Write | NotebookEdit | Grep | Glob | Bash)
# Requires: jq
#
# What it does:
#   1. Uses the protected patterns listed below.
#   2. Collects every path the tool call would touch:
#        Read, Edit, Write, NotebookEdit  the file path
#        Grep, Glob                       the search folder and file pattern
#        Bash                             every word in the command
#   3. Adds what those paths really point to: wildcards in a Bash command are
#      expanded (`cat .en?` opens .env) and symlinks are followed (a link
#      called notes.txt can point at .env).
#   4. Blocks the call if any path matches a pattern, or sits inside a
#      matching folder.
#   5. For delete commands (rm, git clean, ...), also blocks deleting a
#      folder that contains a protected file, e.g. `rm -rf config/`.
#
# Works together with Claude Code's own deny rules (see sync-deny-rules.sh):
# this hook can only allow or block a whole tool call, so it can't hide
# protected files from a search over the whole project. The deny rules can.
#
# This matches text, so it stops normal access but isn't a hard security
# boundary: a script or program that opens the file itself, or a file name
# built while the command runs ($(printf ...)), can get past it.
# A Bash command that merely mentions a protected name is also blocked.
#
# Exit codes:
#   0  Allowed.
#   2  Blocked. Claude Code shows stderr to Claude.

# --- 1. Protected patterns (edit this list) ---------------------------------
#   name      Any file or folder with this name, anywhere in the path.
#             A matching folder protects everything inside it.
#   *.ext     Wildcards work as in the shell (* and ?).
#   dir/name  A specific path, matched from any folder down.
patterns=(
  # Environment files. .env.* also covers .env.example.
  '.env'
  '.env.*'

  # Keys and certificates
  '*.pem'
  '*.key'
  '*.p12'
  '*.keystore'
  'id_rsa*'
  'id_ed25519*'

  # Credential folders
  '.ssh'
  '.aws'
  '.gnupg'
  'secrets'
  '.kube'
  '.docker'

  # Credential files (registry, git and login tokens)
  '.netrc'
  '.npmrc'
  '.git-credentials'
)

# --- Print the matching Claude Code deny rules (used by sync-deny-rules.sh) -
# Each pattern becomes Read and Edit rules for the file itself and anything
# inside it. `//**/` anchors the rule at the filesystem root, so it applies in
# every project and in the home folder.
if [[ "$1" == "--deny-rules" ]]; then
  for pattern in "${patterns[@]}"; do
    for tool in Read Edit; do
      echo "$tool(//**/$pattern)"
      echo "$tool(//**/$pattern/**)"
    done
  done
  exit 0
fi

# Succeed and set $matched to the pattern that protects a path; fail if none does.
# (Sets a variable rather than printing, to avoid a subshell for every path.)
#   name      matches any single part of the path (so a folder protects
#             everything inside it)
#   dir/name  matches the end of the path, or a folder in it
matching_pattern() {
  local path=$1 pattern
  matched=""
  for pattern in "${patterns[@]}"; do
    if [[ "$pattern" == */* ]]; then
      if [[ "$path" == $pattern || "$path" == */$pattern ||
            "$path" == $pattern/* || "$path" == */$pattern/* ]]; then
        matched=$pattern; return 0
      fi
    # Wrapped in slashes, "*/name/*" matches name as any whole part of the path.
    elif [[ "/$path/" == */$pattern/* ]]; then
      matched=$pattern; return 0
    fi
  done
  return 1
}

# Print the first protected file inside a folder, if there is one.
first_protected_inside() {
  local folder=$1 pattern expr=()
  for pattern in "${patterns[@]}"; do
    if [[ "$pattern" == */* ]]; then
      expr+=(-o -path "*/$pattern")
    else
      expr+=(-o -name "$pattern")
    fi
  done
  find "$folder" \( "${expr[@]:1}" \) -print -quit 2>/dev/null
}

block() {
  echo "dev-toolkit: blocked — $1. Protected files must not be read," \
       "changed or deleted. Ask the user if it's needed." >&2
  exit 2
}

# --- 2. Collect the paths this tool call would touch ------------------------
input=$(cat)   # stdin can only be read once
tool=$(jq -r '.tool_name // empty' <<<"$input")

# Relative paths and wildcards are relative to the folder Claude is in.
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null

paths=()
if [[ "$tool" == "Bash" ]]; then
  cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
  # Treat shell punctuation and quotes as spaces, then split into words.
  read -ra paths <<<"$(tr ';|&<>()`"='"'" ' ' <<<"$cmd")"
else
  while IFS= read -r path; do
    paths+=("$path")
  done < <(jq -r --arg tool "$tool" '.tool_input
    | .file_path, .notebook_path, .path, .glob,
      (if $tool == "Glob" then .pattern else empty end)
    | strings' <<<"$input")
fi

# --- 3. Add what wildcards and symlinks really point to ---------------------
shopt -s nullglob   # a wildcard that matches nothing adds nothing
real_paths=()
if [[ "$tool" == "Bash" ]]; then
  for path in "${paths[@]}"; do
    [[ "$path" == *[*?[]* ]] || continue
    [[ "$path" == "~/"* ]] && path="$HOME/${path#\~/}"
    real_paths+=($path)   # unquoted on purpose: the shell expands the wildcard
  done
fi
resolve() {
  local real
  real=$(readlink -f "$1" 2>/dev/null) && [[ "$real" != "$1" ]] && real_paths+=("$real")
}
# Named paths: also follow a link anywhere along the path (keys/id -> .ssh/id).
for path in "${paths[@]}"; do
  [[ -L "$path" || ( "$path" == */* && -e "$path" ) ]] && resolve "$path"
done
# Wildcard results can be many, so only follow the ones that are links.
for path in "${real_paths[@]}"; do
  [[ -L "$path" ]] && resolve "$path"
done
paths+=("${real_paths[@]}")

# --- 4. Block any protected path --------------------------------------------
for path in "${paths[@]}"; do
  if matching_pattern "$path"; then
    block "'$path' is protected (matches '$matched')"
  fi
done

# --- 5. Block deleting a folder that holds protected files ------------------
[[ "$tool" == "Bash" ]] || exit 0

delete_cmd='(^|[;&|( ])(rm|rmdir|unlink|shred|mv) |git +(rm|clean)|-delete'
grep -Eq "$delete_cmd" <<<"$cmd" || exit 0

# `git clean` deletes from the current folder without naming it.
grep -Eq 'git +clean' <<<"$cmd" && paths+=(".")

for path in "${paths[@]}"; do
  [[ -d "$path" ]] || continue
  if found=$(first_protected_inside "$path") && [[ -n "$found" ]]; then
    block "'$path' contains the protected file '$found'"
  fi
done

exit 0
