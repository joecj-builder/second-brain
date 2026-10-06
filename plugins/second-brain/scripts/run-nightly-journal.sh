#!/bin/bash
# Nightly journal runner with missed-weekday backfill.
#
# Scheduled by install-scheduled-jobs.sh (launchd, weekday evenings). Renders
# templates/nightly-journal.md for a date and runs it with `claude -p` from
# inside the vault.
#
# Tracks the last successfully journaled date in a state file outside the
# vault ($LOG_DIR/nightly-journal.last-success) and backfills any missed
# weekdays after it, up to a cap, one full `claude -p` run per date,
# sequentially. A state file (rather than "does Journal/<date>.md exist") is
# used because daytime sessions write to today's journal too, which would
# otherwise make the evening run skip the day.
#
# Usage:
#   run-nightly-journal.sh                     # normal scheduled run
#   run-nightly-journal.sh --dry-run           # print the date list and check the prompt renders; do nothing
#   run-nightly-journal.sh --date YYYY-MM-DD   # force a single specific date
#   run-nightly-journal.sh --cap N             # override the backfill cap for this run
#
# Config (~/.claude/second-brain/config.env):
#   SECOND_BRAIN_VAULT                      required
#   SECOND_BRAIN_SLACK_USER_ID              the user's Slack member ID (optional; without it the journal looks the user up in Slack)
#   SECOND_BRAIN_NIGHTLY_JOURNAL_CAP        max missed weekdays to backfill in one run (default 5)
#   SECOND_BRAIN_NIGHTLY_JOURNAL_TEMPLATE   path to a customized prompt (default: the plugin's templates/nightly-journal.md)

# Intentionally NOT using `set -u`: macOS ships bash 3.2, which throws
# "unbound variable" on empty-array expansions under nounset. Required config
# is enforced with explicit ${VAR:?} checks instead.
set -o pipefail

. "$(dirname "$0")/job-lib.sh"

VAULT="${SECOND_BRAIN_VAULT:?SECOND_BRAIN_VAULT not set; run /second-brain:setup}"
SLACK_USER_ID="${SECOND_BRAIN_SLACK_USER_ID:-}"
CAP="${SECOND_BRAIN_NIGHTLY_JOURNAL_CAP:-5}"
LOG_DIR="$SB_LOG_DIR"
TEMPLATE="${SECOND_BRAIN_NIGHTLY_JOURNAL_TEMPLATE:-$SB_PLUGIN_ROOT/templates/nightly-journal.md}"
JOURNAL_DIR="$VAULT/Journal"
STATE_FILE="$LOG_DIR/nightly-journal.last-success"
LOG_FILE="$LOG_DIR/nightly-journal.log"
TODAY=$(date +%Y-%m-%d)

DRY_RUN=false
FORCE_DATE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --date) FORCE_DATE="$2"; shift 2 ;;
    --cap) CAP="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ ! -d "$VAULT" ]; then
  sb_log "$LOG_FILE" "ERROR: vault $VAULT does not exist"
  sb_notify "Second brain" "Nightly journal failed: the vault folder is missing."
  exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
  sb_log "$LOG_FILE" "ERROR: prompt template $TEMPLATE not found"
  exit 1
fi
mkdir -p "$JOURNAL_DIR"

add_day() {
  date -j -v+1d -f "%Y-%m-%d" "$1" +%Y-%m-%d
}

weekday_num() {
  # 1=Mon .. 7=Sun
  date -j -f "%Y-%m-%d" "$1" +%u
}

# render <target_date> <gap_warning> — print the prompt for one date.
# Bash pattern substitution rather than sed, so values containing |, & or
# newlines (the gap warning has two lines) can't break the substitution.
# Line by line, because bash 3.2 substitutes slowly over one large string.
render() {
  local target_date="$1" gap_warning="$2" target_date_next line
  target_date_next=$(add_day "$target_date")
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"{{"*)
        line=${line//"{{target_date_next}}"/"$target_date_next"}
        line=${line//"{{target_date}}"/"$target_date"}
        line=${line//"{{vault_path}}"/"$VAULT"}
        line=${line//"{{slack_user_id}}"/"$SLACK_USER_ID"}
        line=${line//"{{log_dir}}"/"$LOG_DIR"}
        line=${line//"{{gap_warning}}"/"$gap_warning"}
        ;;
    esac
    printf '%s\n' "$line"
  done < "$TEMPLATE"
}

# --- Determine the list of dates to run ------------------------------------

dates=()
skipped_dates=()

if [ -n "$FORCE_DATE" ]; then
  if ! date -j -f "%Y-%m-%d" "$FORCE_DATE" +%F >/dev/null 2>&1; then
    echo "Invalid --date $FORCE_DATE (want YYYY-MM-DD)" >&2
    exit 1
  fi
  dates=("$FORCE_DATE")
else
  latest=""
  if [ -f "$STATE_FILE" ]; then
    latest=$(tr -d '[:space:]' < "$STATE_FILE")
  fi
  if [ -z "$latest" ]; then
    # No state yet: fall back to the newest journal file so a fresh install
    # on an existing vault doesn't backfill into the void.
    latest=$(find "$JOURNAL_DIR" -maxdepth 1 -type f \
               -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md' \
               -exec basename {} .md \; | sort | tail -1)
  fi

  if [ -z "$latest" ]; then
    # First-ever run: cover today only.
    start_date="$TODAY"
  else
    start_date=$(add_day "$latest")
  fi

  all_dates=()
  d="$start_date"
  while [[ "$d" < "$TODAY" || "$d" == "$TODAY" ]]; do
    wd=$(weekday_num "$d")
    if [ "$wd" -lt 6 ]; then
      all_dates+=("$d")
    fi
    d=$(add_day "$d")
  done

  n=${#all_dates[@]}
  if [ "$n" -gt "$CAP" ]; then
    skipped_count=$((n - CAP))
    skipped_dates=("${all_dates[@]:0:$skipped_count}")
    # Positive-offset slice: bash 3.2 has no negative array-slice offsets.
    dates=("${all_dates[@]:$skipped_count:$CAP}")
  elif [ "$n" -gt 0 ]; then
    dates=("${all_dates[@]}")
  fi
fi

if [ "${#dates[@]}" -eq 0 ]; then
  sb_log "$LOG_FILE" "Up to date through $TODAY (weekends are skipped) — nothing to run."
  exit 0
fi

sb_log "$LOG_FILE" "Dates to run: ${dates[*]}"
if [ "${#skipped_dates[@]}" -gt 0 ]; then
  sb_log "$LOG_FILE" "WARNING: ${#skipped_dates[@]} older weekday(s) exceeded the backfill cap ($CAP) and will NOT be journaled: ${skipped_dates[*]}"
fi

if [ "$DRY_RUN" = true ]; then
  echo "Would run for: ${dates[*]}"
  if [ "${#skipped_dates[@]}" -gt 0 ]; then
    echo "Would skip (exceeds cap): ${skipped_dates[*]}"
  fi
  rendered=$(render "${dates[0]}" "")
  if printf '%s' "$rendered" | grep -q '{{'; then
    echo "Prompt template has unfilled placeholders:" >&2
    printf '%s\n' "$rendered" | grep -n '{{' >&2
    exit 1
  fi
  echo "Prompt renders OK ($(printf '%s\n' "$rendered" | wc -l | tr -d ' ') lines) from $TEMPLATE"
  [ -n "$SLACK_USER_ID" ] || echo "Note: SECOND_BRAIN_SLACK_USER_ID is empty; the journal will try to look the user up in Slack, or skip Slack."
  exit 0
fi

CLAUDE_BIN=$(sb_claude_bin) || {
  sb_log "$LOG_FILE" "ERROR: claude not found on PATH or at ~/.local/bin/claude"
  sb_notify "Second brain" "Nightly journal failed: Claude Code isn't installed where the job expects it."
  exit 1
}

# claude -p scopes file access to its cwd plus --add-dir, so grant the
# read-only sources outside the vault that the prompt uses (only those that
# exist on this machine; a missing --add-dir path is an error).
add_dirs=()
for dir in "$LOG_DIR" "$HOME/.claude/projects" \
           "$HOME/Library/Application Support/Claude/local-agent-mode-sessions"; do
  [ -d "$dir" ] && add_dirs+=(--add-dir "$dir")
done

# --- Run one claude -p per date, sequentially -------------------------------

failed_dates=()
auth_failed=false
oldest_date="${dates[0]}"

for target_date in "${dates[@]}"; do
  gap_warning=""
  if [ "$target_date" = "$oldest_date" ] && [ "${#skipped_dates[@]}" -gt 0 ]; then
    gap_warning="> [!warning] Backfill gap
> Detected a gap of $((${#skipped_dates[@]} + ${#dates[@]})) missed weekday(s); only the most recent $CAP were backfilled (this entry onward). ${#skipped_dates[@]} older weekday(s) have no journal entry: ${skipped_dates[*]}."
  fi

  rendered=$(mktemp "${TMPDIR:-/tmp}/nightly-journal.XXXXXX")
  run_out=$(mktemp "${TMPDIR:-/tmp}/nightly-journal-out.XXXXXX")
  render "$target_date" "$gap_warning" > "$rendered"

  target_journal="$JOURNAL_DIR/$target_date.md"
  before_mtime=""
  [ -f "$target_journal" ] && before_mtime=$(stat -f '%m' "$target_journal")

  sb_log "$LOG_FILE" "Running nightly journal for $target_date..."
  # Run from inside the vault, not whatever directory launched this script.
  # No --permission-mode flags: the run relies on the permissions.allow list
  # that install-scheduled-jobs.sh merged into ~/.claude/settings.json.
  (
    cd "$VAULT" || exit 1
    "$CLAUDE_BIN" -p "${add_dirs[@]}" < "$rendered"
  ) > "$run_out" 2>&1
  claude_exit=$?
  cat "$run_out" >> "$LOG_FILE"

  after_mtime=""
  [ -f "$target_journal" ] && after_mtime=$(stat -f '%m' "$target_journal")

  # The exit code alone isn't a reliable success signal: `claude -p` can exit
  # 0 while declining the task (e.g. a permission it needs isn't granted).
  # The real signal is whether the journal file was created or updated.
  if [ "$claude_exit" -eq 0 ] && [ -n "$after_mtime" ] && [ "$after_mtime" != "$before_mtime" ]; then
    sb_log "$LOG_FILE" "OK: $target_date"
    # Only ever move the marker forward (a --date run for an older day must
    # not rewind it).
    current=""
    [ -f "$STATE_FILE" ] && current=$(tr -d '[:space:]' < "$STATE_FILE")
    if [ -z "$current" ] || [[ "$target_date" > "$current" ]]; then
      echo "$target_date" > "$STATE_FILE"
    fi
  else
    if sb_auth_failed "$run_out"; then
      auth_failed=true
      sb_log "$LOG_FILE" "FAILED: $target_date — $SB_AUTH_HINT"
    else
      sb_log "$LOG_FILE" "FAILED: $target_date (exit=$claude_exit, journal file unchanged — see the output above; a 'permission' message usually means the allow list in ~/.claude/settings.json is missing a tool)"
    fi
    failed_dates+=("$target_date")
  fi

  rm -f "$rendered" "$run_out"
  # No point trying more dates if the login is gone.
  [ "$auth_failed" = true ] && break
done

if [ "${#failed_dates[@]}" -gt 0 ]; then
  sb_log "$LOG_FILE" "Completed with failures: ${failed_dates[*]}"
  if [ "$auth_failed" = true ]; then
    sb_notify "Second brain" "Nightly journal didn't run: open Terminal, run claude, and sign in again."
  else
    sb_notify "Second brain" "Nightly journal failed for ${failed_dates[*]}. Log: ~/Library/Logs/second-brain/nightly-journal.log"
  fi
  exit 1
fi

sb_log "$LOG_FILE" "Completed successfully: ${dates[*]}"
exit 0
