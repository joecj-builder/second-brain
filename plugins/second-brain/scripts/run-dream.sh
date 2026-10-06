#!/bin/bash
# Weekly /dream runner. Scheduled by install-scheduled-jobs.sh (launchd).
#
# Runs /second-brain:dream with `claude -p` from inside the vault. The dream
# itself is non-destructive: it writes a dream/<YYYY-Wxx> branch in a git
# worktree under SECOND_BRAIN_DREAM_DIR (default
# ~/.claude/second-brain/dream-worktrees) for the user to adopt or discard.
# Passes --notify (Slack DM of the report) when SECOND_BRAIN_SLACK_DM is set.
#
# This script commits any pending vault changes ("pre-dream snapshot") and
# creates the branch and worktree itself, so the run doesn't need
# `git worktree add` (which takes any path). The run is given that one
# worktree and the session transcripts, and its own allow list via --settings
# (see sb_write_job_settings in job-lib.sh). The user's settings aren't
# changed. If the run commits nothing, the empty branch and worktree are
# removed again so the next run can retry.
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

VAULT="${VAULT%/}"
DREAM_DIR="$SB_DREAM_DIR"
WEEK=$(date +%G-W%V)
BRANCH="dream/$WEEK"
# Same name adopt-dream.sh looks for.
WORKTREE="$DREAM_DIR/$(basename "$VAULT")-$WEEK"

# The skill takes everything it needs from these arguments in a scheduled
# run, so it doesn't have to read config.env (outside the folders it's given).
prompt="/second-brain:dream --worktree \"$WORKTREE\" --week $WEEK"
[ -n "${SECOND_BRAIN_SLACK_DM:-}" ] && prompt="$prompt --notify --slack-dm ${SECOND_BRAIN_SLACK_DM}"

if ! git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
  sb_log "$LOG_FILE" "ERROR: $VAULT is not a git repo; /dream needs git. Run: git -C \"$VAULT\" init -b main"
  sb_notify "Second brain" "Weekly review skipped: the vault isn't backed by git yet."
  exit 1
fi

if git -C "$VAULT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  sb_log "$LOG_FILE" "Skipped: $BRANCH already exists and is waiting for review (adopt or discard it with adopt-dream.sh $WEEK)."
  sb_notify "Second brain" "This week's memory review is already waiting for you. Ask Claude to show you the dream report."
  exit 0
fi

# Only this week's worktree (never the vault's parent) and the session
# transcripts. The vault itself is the working directory.
add_dirs=(--add-dir "$WORKTREE")
helper_roots="$VAULT:$WORKTREE"
if [ -d "$HOME/.claude/projects" ]; then
  add_dirs+=(--add-dir "$HOME/.claude/projects")
  helper_roots="$helper_roots:$HOME/.claude/projects"
fi

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
  printf 'after creating branch %s in a new worktree at %s\n' "$BRANCH" "$WORKTREE"
  exit 0
fi

SETTINGS_FILE=$(sb_write_job_settings dream "$WORKTREE") || {
  sb_log "$LOG_FILE" "ERROR: couldn't write the run's settings file in $SB_JOBS_DIR"
  sb_notify "Second brain" "Weekly review failed: couldn't prepare its permissions. Log: $LOG_FILE"
  exit 1
}

CLAUDE_BIN=$(sb_claude_bin) || {
  sb_log "$LOG_FILE" "ERROR: claude not found on PATH or at ~/.local/bin/claude"
  sb_notify "Second brain" "Weekly review failed: Claude Code isn't installed where the job expects it."
  exit 1
}

# Commit pending changes first, so the dream branch starts from everything in
# the vault and its diff shows only what the dream did.
if [ -n "$(git -C "$VAULT" status --porcelain 2>/dev/null)" ]; then
  if snap_err=$(git -C "$VAULT" add -A 2>&1 && git -C "$VAULT" commit -q -m "pre-dream snapshot" 2>&1); then
    sb_log "$LOG_FILE" "Committed the vault's pending changes (pre-dream snapshot)."
  else
    sb_log "$LOG_FILE" "ERROR: couldn't commit the vault's pending changes before the dream: $snap_err"
    sb_notify "Second brain" "Weekly review failed: couldn't save the vault's pending changes first. Log: $LOG_FILE"
    exit 1
  fi
fi

mkdir -p "$DREAM_DIR"
git -C "$VAULT" worktree prune >/dev/null 2>&1
if ! wt_err=$(git -C "$VAULT" worktree add "$WORKTREE" -b "$BRANCH" 2>&1); then
  sb_log "$LOG_FILE" "ERROR: couldn't create the dream worktree at $WORKTREE: $wt_err"
  sb_notify "Second brain" "Weekly review failed: couldn't set up its review folder. Log: $LOG_FILE"
  exit 1
fi
base_commit=$(git -C "$VAULT" rev-parse "refs/heads/$BRANCH")
run_out=$(mktemp "${TMPDIR:-/tmp}/dream-out.XXXXXX")

sb_log "$LOG_FILE" "Running $prompt..."
(
  cd "$VAULT" || exit 1
  # The helper's list/search/modified read only inside these folders.
  export SB_HELPER_ROOTS="$helper_roots"
  # Prompt on stdin: --add-dir takes several values, so a prompt argument
  # after it would be read as one more directory.
  "$CLAUDE_BIN" -p "${plugin_args[@]}" --settings "$SETTINGS_FILE" "${add_dirs[@]}" <<< "$prompt"
) > "$run_out" 2>&1
claude_exit=$?
cat "$run_out" >> "$LOG_FILE"

tip_commit=$(git -C "$VAULT" rev-parse --verify --quiet "refs/heads/$BRANCH")

# As with the journal, exit 0 doesn't prove the dream ran. Commits on the
# dream branch do.
if [ "$claude_exit" -eq 0 ] && [ -n "$tip_commit" ] && [ "$tip_commit" != "$base_commit" ]; then
  sb_log "$LOG_FILE" "OK: dream branch ready for review ($BRANCH)"
  sb_notify "Second brain" "Your weekly memory review is ready. Ask Claude to show you the dream report."
  rm -f "$run_out"
  exit 0
fi

# Nothing was committed: remove the empty branch and worktree, or the next
# run this week would hit the guard above and report a review that isn't there.
if [ "$tip_commit" = "$base_commit" ]; then
  git -C "$VAULT" worktree remove --force "$WORKTREE" >/dev/null 2>&1
  git -C "$VAULT" branch -D "$BRANCH" >/dev/null 2>&1
  left="the empty $BRANCH branch and its worktree were removed, so the next run starts fresh"
else
  left="$BRANCH has partial work; review or discard it with adopt-dream.sh $WEEK"
fi

if sb_auth_failed "$run_out"; then
  sb_log "$LOG_FILE" "FAILED — $SB_AUTH_HINT ($left)"
  sb_notify "Second brain" "Weekly review didn't run: open Terminal, run claude, and sign in again."
else
  sb_log "$LOG_FILE" "FAILED (exit=$claude_exit; $left — see the output above)"
  sb_notify "Second brain" "Weekly review failed. Log: $LOG_FILE"
fi
rm -f "$run_out"
exit 1
