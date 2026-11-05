#!/bin/bash
# Match text against the vault's DataContext notes.
#
#   datacontext-match.sh "<text>"            print matching notes (path, name, description)
#   datacontext-match.sh --scores "<text>"   print scores and the tokens that hit
#   datacontext-match.sh --hook              PreToolUse hook on the Agent tool (stdin = hook JSON)
#
# Hook behavior comes from SECOND_BRAIN_SUBAGENT_CONTEXT in config.env:
#   inject (default)  append the matches to the subagent's prompt
#   remind            tell the main model about the matches; leave the prompt alone
#   deny              refuse the launch when there are matches the prompt doesn't name,
#                     so Claude re-sends it with them
#   off               do nothing
# The hook never blocks or fails the Agent call on an error: it exits 0 silently.

. "$(dirname "$0")/config.sh" 2>/dev/null
here="$(cd "$(dirname "$0")" && pwd)"
vault="${SECOND_BRAIN_VAULT:-}"

if [ "${1:-}" = "--hook" ]; then
  mode="${SECOND_BRAIN_SUBAGENT_CONTEXT:-inject}"
  if [ "$mode" = "off" ] || [ -z "$vault" ] || ! command -v python3 >/dev/null 2>&1; then
    cat >/dev/null
    exit 0
  fi
  python3 -I "$here/datacontext-match.py" --vault "$vault" --hook "$mode" 2>/dev/null
  exit 0
fi

exec python3 -I "$here/datacontext-match.py" --vault "$vault" "$@"
