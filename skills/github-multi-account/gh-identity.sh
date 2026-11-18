#!/usr/bin/env bash
# SessionStart + CwdChanged hook: pin the gh identity for client folders.
#
# gh uses one global active account, so in a client folder it would act as the personal
# account. This hook writes the client account's settings to $CLAUDE_ENV_FILE, which
# Claude Code applies to the shell commands it runs later in the session. Claude Code
# empties that file on every CwdChanged, so leaving the folder drops the variables.
#
# Writes only GH_TOKEN, read from the client's isolated gh config dir. A token has no
# slashes, so the PowerShell tool gets it as well as Bash. GH_CONFIG_DIR would not work:
# PowerShell skips any value containing / or \, and one line it cannot parse as a plain
# assignment makes it drop every variable in the file.
#
# A repo counts as the client's when its git common dir is under the prefix. That also
# catches worktrees outside the folder, such as T3 Code's ~/.t3/worktrees.
set -u

# prefix (lowercase, forward slashes)  ->  gh config dir
MAP=(
  "d:/client/|C:\\Users\\you\\.gh-client"
)

[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0
input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.new_cwd // .cwd // empty')
[ -n "$cwd" ] || exit 0

# Normalise to "d:/x/y/" for matching: the repo's git common dir if any, else the cwd.
p=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '%s' "$cwd")
p=$(printf '%s' "$p" | tr '\\' '/' | tr '[:upper:]' '[:lower:]')
case "$p" in /[a-z]/*) p="${p:1:1}:${p:2}" ;; esac
p="${p%/}/"

for entry in "${MAP[@]}"; do
  prefix=${entry%%|*}
  dir=${entry#*|}
  case "$p" in
    "$prefix"*)
      token=$(GH_CONFIG_DIR="$dir" gh auth token 2>/dev/null) || exit 0
      [ -n "$token" ] || exit 0
      printf 'export GH_TOKEN=%s\n' "$token" >> "$CLAUDE_ENV_FILE"
      exit 0
      ;;
  esac
done
exit 0
