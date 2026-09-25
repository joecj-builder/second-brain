#!/bin/bash
# SessionStart hook — tell Claude where this machine's second brain lives.
# Stdout is injected into the session as context. Also appends an audit line
# to ~/.claude/session-log.jsonl.

. "$(dirname "$0")/config.sh"
cat >/dev/null   # hook JSON on stdin; not needed

vault="${SECOND_BRAIN_VAULT:-}"

if [ -z "$vault" ]; then
  echo "Second brain: not configured on this machine. Run /second-brain:setup to pick a vault."
elif [ ! -d "$vault" ]; then
  echo "Second brain: configured vault $vault does not exist. Run /second-brain:setup to fix it."
else
  cat <<MSG
Second brain vault: $vault

This vault is your persistent memory store. Sessions are ephemeral; the vault
is permanent. Load the /second-brain:protocol skill before looking anything up
in the vault or writing to it. The manifest is $vault/Memory/MEMORY.md.
MSG
fi

log="$HOME/.claude/session-log.jsonl"
mkdir -p "$(dirname "$log")"
printf '{"ts":"%s","vault":"%s","cwd":"%s","pid":%s}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$vault" "$(pwd)" "$$" >> "$log"
