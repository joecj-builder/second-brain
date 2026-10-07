#!/bin/bash
# Nightly journal runner with missed-weekday backfill.
#
# Scheduled by install-scheduled-jobs.sh (launchd). The job fires every
# evening; this script journals weekdays only, so a weekend fire just catches
# up on missed weekdays. Renders templates/nightly-journal.md for a date and
# runs it with `claude -p` from inside the vault.
#
# Tracks the last successfully journaled date in a state file outside the
# vault ($LOG_DIR/nightly-journal.last-success) and backfills any missed
# weekdays after it, up to a cap, one full `claude -p` run per date,
# sequentially. A state file (rather than "does Journal/<date>.md exist") is
# used because daytime sessions write to today's journal too, which would
# otherwise make the evening run skip the day.
#
# A failed date stops the run and leaves the marker where it was, so the next
# run retries it. $LOG_DIR/nightly-journal.failures counts the attempts; after
# $MAX_ATTEMPTS failed runs on one date it is skipped (with a notification) so
# one bad day can't block the journal forever.
#
# Permissions: the run gets its own settings file (sb_write_job_settings in
# job-lib.sh) passed with --settings. Nothing is added to the user's
# ~/.claude/settings.json.
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
#   SECOND_BRAIN_LOG_DIR                    logs + state file (default ~/Library/Logs/second-brain; for testing)
#   SECOND_BRAIN_JOB_EXTRA_ALLOW / _DENY    extra permission rules for the run, ;-separated

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
FAILURES_FILE="$LOG_DIR/nightly-journal.failures"
MAX_ATTEMPTS=3
LOG_FILE="$LOG_DIR/nightly-journal.log"
TODAY=$(date +%Y-%m-%d)

DRY_RUN=false
FORCE_DATE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --date|--cap)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "$1 needs a value" >&2; exit 1
      fi
      if [ "$1" = --date ]; then FORCE_DATE="$2"; else CAP="$2"; fi
      shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$CAP" in
  ''|0*|*[!0-9]*)
    echo "The backfill cap must be a whole number of 1 or more (got '$CAP' from --cap or SECOND_BRAIN_NIGHTLY_JOURNAL_CAP)" >&2
    exit 1 ;;
esac

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
  local target_date="$1" gap_warning="$2" target_date_next daily_notes line
  target_date_next=$(add_day "$target_date")
  daily_notes=$(daily_notes_line "$target_date")
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"{{"*)
        line=${line//"{{target_date_next}}"/"$target_date_next"}
        line=${line//"{{target_date}}"/"$target_date"}
        line=${line//"{{vault_path}}"/"$VAULT"}
        line=${line//"{{slack_user_id}}"/"$SLACK_USER_ID"}
        line=${line//"{{log_dir}}"/"$LOG_DIR"}
        line=${line//"{{journal_helper}}"/"$HELPER_CMD"}
        line=${line//"{{daily_notes}}"/"$daily_notes"}
        line=${line//"{{gap_warning}}"/"$gap_warning"}
        ;;
    esac
    printf '%s\n' "$line"
  done < "$TEMPLATE"
}

# daily_notes_line <date> — the prompt's instruction for the optional manual
# notes. The run may only read that folder when it exists (--add-dir below),
# so don't send Claude looking for it otherwise.
DAILY_NOTES_DIR="$LOG_DIR/daily-notes"
daily_notes_line() {
  if [ -d "$DAILY_NOTES_DIR" ]; then
    # shellcheck disable=SC2016  # literal backticks for the markdown
    printf 'Read `%s/%s.md` for any manually logged notes from the day. If the file is missing, skip this source.' "$DAILY_NOTES_DIR" "$1"
  else
    printf 'No daily notes folder on this machine; skip this source.'
  fi
}

# The exact helper command the prompt uses; the allow rule matches it.
HELPER_CMD=$(sb_helper_cmd)

# failure_count <date> — failed scheduled attempts recorded for that date.
failure_count() {
  local d n
  [ -f "$FAILURES_FILE" ] || { echo 0; return; }
  while read -r d n; do
    [ "$d" = "$1" ] && { echo "${n:-0}"; return; }
  done < "$FAILURES_FILE"
  echo 0
}

# set_failures <date> <count> — record the count (0 clears the file). Only
# the oldest unjournaled date is ever retried, so one line is enough.
set_failures() {
  if [ "$2" -gt 0 ]; then
    echo "$1 $2" > "$FAILURES_FILE"
  else
    rm -f "$FAILURES_FILE"
  fi
}

# advance_marker <date> — move the last-success marker forward to <date>.
# Never backward: a --date run for an older day must not rewind it.
advance_marker() {
  local current=""
  [ -f "$STATE_FILE" ] && current=$(tr -d '[:space:]' < "$STATE_FILE")
  if [ -z "$current" ] || [[ "$1" > "$current" ]]; then
    echo "$1" > "$STATE_FILE"
  fi
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
    # on an existing vault doesn't backfill into the void. Never later than
    # yesterday, though: daytime sessions already write to today's journal,
    # and that must not make the first run skip today.
    latest=$(find "$JOURNAL_DIR" -maxdepth 1 -type f \
               -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md' \
               -exec basename {} .md \; | sort | tail -1)
    yesterday=$(date -j -v-1d +%Y-%m-%d)
    if [ -n "$latest" ] && [[ "$latest" > "$yesterday" ]]; then
      latest="$yesterday"
    fi
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

# claude -p scopes file access to its cwd (the vault) plus --add-dir (read
# only; Edit is limited to the vault by the settings file). The helper
# summarizes sessions itself; the transcripts folder is there so the run can
# open one when a summary is too thin. Plus the user's optional daily notes.
add_dirs=()
helper_roots="$VAULT"
for dir in "$HOME/.claude/projects" "$DAILY_NOTES_DIR"; do
  if [ -d "$dir" ]; then
    add_dirs+=(--add-dir "$dir")
    helper_roots="$helper_roots:$dir"
  fi
done

plugin_args=()
while IFS= read -r a; do
  [ -n "$a" ] && plugin_args+=("$a")
done <<EOF
$(sb_plugin_args)
EOF

SETTINGS_FILE=$(sb_write_job_settings nightly-journal) || {
  sb_log "$LOG_FILE" "ERROR: couldn't write the run's settings file in $SB_JOBS_DIR"
  sb_notify "Second brain" "Nightly journal failed: couldn't prepare its permissions. Log: $LOG_FILE"
  exit 1
}

# --- Run one claude -p per date, sequentially -------------------------------
#
# Oldest first. The first failure stops the run, so the marker never skips
# past a date that wasn't journaled; the next run starts again from it.

failed_date=""
auth_failed=false
gave_up_dates=()
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
  # No --permission-mode flags: the --settings allow list is the whole grant.
  (
    cd "$VAULT" || exit 1
    # The helper's list/search/modified read only inside these folders.
    export SB_HELPER_ROOTS="$helper_roots"
    "$CLAUDE_BIN" -p "${plugin_args[@]}" --settings "$SETTINGS_FILE" "${add_dirs[@]}" < "$rendered"
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
    # A manual run for today (setup's test run) leaves the marker alone, so
    # this evening's scheduled run still journals the whole day.
    [ "$FORCE_DATE" = "$TODAY" ] || advance_marker "$target_date"
    [ -z "$FORCE_DATE" ] && set_failures "$target_date" 0
    rm -f "$rendered" "$run_out"
    continue
  fi

  if sb_auth_failed "$run_out"; then
    # Not this date's fault: don't count it as an attempt.
    auth_failed=true
    sb_log "$LOG_FILE" "FAILED: $target_date — $SB_AUTH_HINT"
  else
    sb_log "$LOG_FILE" "FAILED: $target_date (exit=$claude_exit, journal file unchanged — see the output above; a 'permission' message means the run's allow list is missing a tool, see SECOND_BRAIN_JOB_EXTRA_ALLOW)"
  fi
  rm -f "$rendered" "$run_out"

  if [ -n "$FORCE_DATE" ] || [ "$auth_failed" = true ]; then
    failed_date="$target_date"
    break
  fi

  attempts=$(( $(failure_count "$target_date") + 1 ))
  if [ "$attempts" -lt "$MAX_ATTEMPTS" ]; then
    set_failures "$target_date" "$attempts"
    failed_date="$target_date"
    sb_log "$LOG_FILE" "Stopping here (attempt $attempts of $MAX_ATTEMPTS for $target_date); the next run retries it."
    break
  fi
  # Third failed run for this date: give up on it so later days still get
  # journaled.
  sb_log "$LOG_FILE" "GIVING UP on $target_date after $attempts failed runs; moving on. Journal it by hand with: run-nightly-journal.sh --date $target_date"
  gave_up_dates+=("$target_date")
  set_failures "$target_date" 0
  advance_marker "$target_date"
done

if [ "${#gave_up_dates[@]}" -gt 0 ]; then
  sb_notify "Second brain" "Nightly journal gave up on ${gave_up_dates[*]} after $MAX_ATTEMPTS tries. Log: $LOG_FILE"
fi

if [ -n "$failed_date" ]; then
  sb_log "$LOG_FILE" "Stopped at $failed_date; not attempted this run: $(
    after=false; for d in "${dates[@]}"; do
      [ "$after" = true ] && printf '%s ' "$d"
      [ "$d" = "$failed_date" ] && after=true
    done)"
  if [ "$auth_failed" = true ]; then
    sb_notify "Second brain" "Nightly journal didn't run: open Terminal, run claude, and sign in again."
  else
    sb_notify "Second brain" "Nightly journal failed for $failed_date (it will be retried). Log: $LOG_FILE"
  fi
  exit 1
fi

if [ "${#gave_up_dates[@]}" -gt 0 ]; then
  sb_log "$LOG_FILE" "Completed; skipped after repeated failures: ${gave_up_dates[*]}"
  exit 1
fi
sb_log "$LOG_FILE" "Completed successfully: ${dates[*]}"
exit 0
