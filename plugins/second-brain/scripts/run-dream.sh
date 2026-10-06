#!/bin/bash
# Weekly /dream runner. Scheduled by install-scheduled-jobs.sh (launchd).
#
# Runs /second-brain:dream with `claude -p` from inside the vault. The dream
# itself is non-destructive: it writes a dream/<YYYY-Wxx> branch in a git
# worktree under SECOND_BRAIN_DREAM_DIR (default
# ~/.claude/second-brain/dream-worktrees) for the user to adopt or discard.
# Passes --notify (Slack DM of the report) when SECOND_BRAIN_SLACK_DM is set.
#
# The run is given that folder (it holds nothing but dream worktrees) and the
# session transcripts, and its own allow list via --settings (see
# sb_write_job_settings in job-lib.sh). The user's settings aren't changed.
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

DREAM_DIR="$SB_DREAM_DIR"
WEEK=$(date +%G-W%V)

# The skill takes everything it needs from these arguments in a scheduled
# run, so it doesn't have to read config.env (outside the folders it's given).
prompt="/second-brain:dream --dream-dir \"$DREAM_DIR\""
[ -n "${SECOND_BRAIN_SLACK_DM:-}" ] && prompt="$prompt --notify --slack-dm ${SECOND_BRAIN_SLACK_DM}"

if ! git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
  sb_log "$LOG_FILE" "ERROR: $VAULT is not a git repo; /dream needs git. Run: git -C \"$VAULT\" init -b main"
  sb_notify "Second brain" "Weekly review skipped: the vault isn't backed by git yet."
  exit 1
fi

if git -C "$VAULT" rev-parse --verify --quiet "refs/heads/dream/$WEEK" >/dev/null; then
  sb_log "$LOG_FILE" "Skipped: dream/$WEEK already exists and is waiting for review (adopt or discard it with adopt-dream.sh $WEEK)."
  sb_notify "Second brain" "This week's memory review is already waiting for you. Ask Claude to show you the dream report."
  exit 0
fi

# Only the dream folder (worktrees only, never the vault's parent) and the
# session transcripts. The vault itself is the working directory.
add_dirs=(--add-dir "$DREAM_DIR")
[ -d "$HOME/.claude/projects" ] && add_dirs+=(--add-dir "$HOME/.claude/projects")

plugin_args=()
while IFS= read -r a; do
  [ -n "$a" ] && plugin_args+=("$a")
done <<EOF
$(sb_plugin_args)
EOF

if [ "$DRY_RUN" = true ]; then
  printf 'Would run in %s:\n  claude -p' "$VAULT"
  [ "${#plugin_args[@]}" -gt 0 ] && printf ' %q' "${plugin_args[@]}"
  printf ' --settings %q' "$SB_JOBS_DIR/dream-settings.json"
  printf ' %q' "${add_dirs[@]}"
  printf ' <<< %q\n' "$prompt"
  exit 0
fi

mkdir -p "$DREAM_DIR"
SETTINGS_FILE=$(sb_write_job_settings dream) || {
  sb_log "$LOG_FILE" "ERROR: couldn't write the run's settings file in $SB_JOBS_DIR"
  sb_notify "Second brain" "Weekly review failed: couldn't prepare its permissions. Log: $LOG_FILE"
  exit 1
}

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
  # Prompt on stdin: --add-dir takes several values, so a prompt argument
  # after it would be read as one more directory.
  "$CLAUDE_BIN" -p "${plugin_args[@]}" --settings "$SETTINGS_FILE" "${add_dirs[@]}" <<< "$prompt"
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
  sb_notify "Second brain" "Weekly review failed. Log: $LOG_FILE"
fi
rm -f "$run_out"
exit 1
