#!/bin/bash
# Weekly /dream runner. Scheduled by install-scheduled-jobs.sh (launchd).
#
# Runs `claude -p "/second-brain:dream"` from inside the vault. The dream
# itself is non-destructive: it writes a dream/<YYYY-Wxx> branch in a sibling
# worktree for the user to adopt or discard. Passes --notify (Slack DM of the
# report) when SECOND_BRAIN_SLACK_DM is set.
#
# Usage:
#   run-dream.sh             # scheduled run
#   run-dream.sh --dry-run   # print what would run; do nothing

set -o pipefail

. "$(dirname "$0")/job-lib.sh"

VAULT="${SECOND_BRAIN_VAULT:?SECOND_BRAIN_VAULT not set; run /second-brain:setup}"
LOG_FILE="$SB_LOG_DIR/dream.log"

DRY_RUN=false
case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  "") ;;
  *) echo "Unknown argument: $1" >&2; exit 1 ;;
esac

prompt="/second-brain:dream"
[ -n "${SECOND_BRAIN_SLACK_DM:-}" ] && prompt="$prompt --notify"

if ! git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
  sb_log "$LOG_FILE" "ERROR: $VAULT is not a git repo; /dream needs git. Run: git -C \"$VAULT\" init -b main"
  sb_notify "Second brain" "Weekly review skipped: the vault isn't backed by git yet."
  exit 1
fi

# The dream worktree is a sibling of the vault (../<vault>-dream-<week>), so
# the run needs the vault's parent directory as well as the session
# transcripts. Edits are still limited by the Edit(...) rules in
# ~/.claude/settings.json.
add_dirs=(--add-dir "$(dirname "$VAULT")")
[ -d "$HOME/.claude/projects" ] && add_dirs+=(--add-dir "$HOME/.claude/projects")

plugin_args=()
while IFS= read -r a; do
  [ -n "$a" ] && plugin_args+=("$a")
done <<EOF
$(sb_plugin_args)
EOF

if [ "$DRY_RUN" = true ]; then
  echo "Would run in $VAULT: claude -p ${plugin_args[*]} ${add_dirs[*]} \"$prompt\""
  exit 0
fi

CLAUDE_BIN=$(sb_claude_bin) || {
  sb_log "$LOG_FILE" "ERROR: claude not found on PATH or at ~/.local/bin/claude"
  sb_notify "Second brain" "Weekly review failed: Claude Code isn't installed where the job expects it."
  exit 1
}

branches_before=$(git -C "$VAULT" for-each-ref --format='%(refname:short) %(objectname)' refs/heads/dream/)
run_out=$(mktemp "${TMPDIR:-/tmp}/dream-out.XXXXXX")

sb_log "$LOG_FILE" "Running $prompt..."
(
  cd "$VAULT" || exit 1
  "$CLAUDE_BIN" -p "${plugin_args[@]}" "${add_dirs[@]}" "$prompt"
) > "$run_out" 2>&1
claude_exit=$?
cat "$run_out" >> "$LOG_FILE"

branches_after=$(git -C "$VAULT" for-each-ref --format='%(refname:short) %(objectname)' refs/heads/dream/)

# As with the journal, exit 0 doesn't prove the dream ran. A new or updated
# dream/* branch does.
if [ "$claude_exit" -eq 0 ] && [ "$branches_after" != "$branches_before" ]; then
  sb_log "$LOG_FILE" "OK: dream branch ready for review ($(git -C "$VAULT" for-each-ref --sort=-committerdate --count=1 --format='%(refname:short)' refs/heads/dream/))"
  sb_notify "Second brain" "Your weekly memory review is ready. Ask Claude to show you the dream report."
  rm -f "$run_out"
  exit 0
fi

if sb_auth_failed "$run_out"; then
  sb_log "$LOG_FILE" "FAILED — $SB_AUTH_HINT"
  sb_notify "Second brain" "Weekly review didn't run: open Terminal, run claude, and sign in again."
else
  sb_log "$LOG_FILE" "FAILED (exit=$claude_exit, no dream branch created or updated — see the output above)"
  sb_notify "Second brain" "Weekly review failed. Log: ~/Library/Logs/second-brain/dream.log"
fi
rm -f "$run_out"
exit 1
