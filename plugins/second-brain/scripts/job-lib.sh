# shellcheck shell=bash
# Sourced by run-nightly-journal.sh and run-dream.sh (the scheduled jobs).
# Loads the second-brain config and defines small helpers shared by both.
#
# Written for macOS's stock /bin/bash 3.2: no associative arrays, no negative
# array offsets, and no `set -u` (3.2 treats "${empty_array[@]}" as unbound).

SB_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB_PLUGIN_ROOT="$(dirname "$SB_SCRIPTS_DIR")"
. "$SB_SCRIPTS_DIR/config.sh"

# SECOND_BRAIN_LOG_DIR (env or config) moves the logs and the journal's state
# file, so a test run never touches the real ones.
SB_LOG_DIR="${SECOND_BRAIN_LOG_DIR:-$HOME/Library/Logs/second-brain}"
mkdir -p "$SB_LOG_DIR"
# Per-run settings files (see sb_write_job_settings) and the launchd launcher.
SB_JOBS_DIR="$HOME/.claude/second-brain/jobs"
# Where weekly dream worktrees go. Holds nothing but worktrees, so the dream
# run can be given this folder alone.
SB_DREAM_DIR="${SECOND_BRAIN_DREAM_DIR:-$HOME/.claude/second-brain/dream-worktrees}"
SB_DREAM_DIR="${SB_DREAM_DIR%/}"
SB_JOURNAL_HELPER="$SB_SCRIPTS_DIR/journal-helper.py"

# log <file> <message...> — timestamped line to the job log and stdout.
sb_log() {
  local file="$1"; shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$file"
}

# sb_notify <title> <message> — macOS notification. Best effort; the jobs run
# unattended, so this is how a failure gets noticed without reading logs.
sb_notify() {
  [ "${SECOND_BRAIN_JOB_NOTIFY:-true}" = true ] || return 0
  command -v osascript >/dev/null 2>&1 || return 0
  local title msg
  # Drop characters that would break the AppleScript string.
  title=$(printf '%s' "$1" | tr -d '\042\134')   # " and backslash
  msg=$(printf '%s' "$2" | tr -d '\042\134')
  osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1 || true
}

# sb_claude_bin — print the claude executable. launchd has no shell PATH, so
# fall back to the default install location.
sb_claude_bin() {
  if command -v claude >/dev/null 2>&1; then
    command -v claude
  elif [ -x "$HOME/.local/bin/claude" ]; then
    echo "$HOME/.local/bin/claude"
  else
    return 1
  fi
}

# sb_plugin_args — print "--plugin-dir <root>" when this plugin was loaded from
# a working tree (development) rather than installed. Installed plugins load
# on their own in headless runs.
sb_plugin_args() {
  case "$SB_PLUGIN_ROOT" in
    "$HOME/.claude/plugins/"*) ;;
    *) printf '%s\n%s\n' --plugin-dir "$SB_PLUGIN_ROOT" ;;
  esac
}

# sb_auth_failed <output file> — true if a run failed because Claude's login
# expired. Headless runs can't open a browser to sign in again.
sb_auth_failed() {
  grep -qiE 'oauth session expired|failed to authenticate|not logged in|please run /login|invalid api key' "$1" 2>/dev/null
}

# shellcheck disable=SC2034  # used by the runners that source this file
SB_AUTH_HINT="Claude's sign-in expired, so the scheduled run couldn't start. Open Terminal, run 'claude', sign in if asked, then type /exit. The next run will work again."

# --- Per-run permissions --------------------------------------------------------
#
# The scheduled runs can't ask for approval, so they need an allow list. It is
# written to its own file and passed with `claude -p --settings <file>`, so it
# applies to these runs only; the user's own settings.json is never changed.
# Rebuilt on every run, so plugin paths stay right after /plugin update.
#   - Edit(...) covers every file-writing tool (Write rules aren't consulted
#     for file edits). "//" starts an absolute path in a rule.
#   - The deny list is a backstop; deny beats allow, including rules in the
#     user's own settings.
#   - No --permission-mode anywhere: the allow list is the whole grant.

# sb_json_str <string> — print it as a JSON string literal.
sb_json_str() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

# sb_json_array <items...> — print a JSON array of strings.
sb_json_array() {
  local first=true item
  printf '['
  for item in "$@"; do
    [ "$first" = true ] || printf ','
    first=false
    printf '\n      '
    sb_json_str "$item"
  done
  printf '\n    ]'
}

# sb_helper_cmd — the exact command prefix for journal-helper.py, as the
# prompt tells Claude to type it and as the allow rule matches it.
sb_helper_cmd() {
  case "$SB_JOURNAL_HELPER" in
    *[[:space:]]*) printf 'python3 -I "%s"' "$SB_JOURNAL_HELPER" ;;
    *) printf 'python3 -I %s' "$SB_JOURNAL_HELPER" ;;
  esac
}

# Read-only connector tools the nightly journal uses. Missing connectors are
# fine; a rule for a tool that doesn't exist does nothing.
SB_JOURNAL_READ_TOOLS="mcp__claude_ai_Granola__get_account_info
mcp__claude_ai_Granola__get_meeting_transcript
mcp__claude_ai_Granola__get_meetings
mcp__claude_ai_Granola__list_meeting_folders
mcp__claude_ai_Granola__list_meetings
mcp__claude_ai_Granola__query_granola_meetings
mcp__claude_ai_Slack__slack_read_canvas
mcp__claude_ai_Slack__slack_read_channel
mcp__claude_ai_Slack__slack_read_file
mcp__claude_ai_Slack__slack_read_list
mcp__claude_ai_Slack__slack_read_thread
mcp__claude_ai_Slack__slack_read_user_profile
mcp__claude_ai_Slack__slack_list_channel_members
mcp__claude_ai_Slack__slack_list_user_channels
mcp__claude_ai_Slack__slack_get_reactions
mcp__claude_ai_Slack__slack_search_channels
mcp__claude_ai_Slack__slack_search_public
mcp__claude_ai_Slack__slack_search_public_and_private
mcp__claude_ai_Slack__slack_search_users
mcp__claude_ai_Gmail__search_threads
mcp__claude_ai_Gmail__get_thread
mcp__claude_ai_Google_Drive__search_files
mcp__claude_ai_Google_Drive__get_file_metadata
mcp__claude_ai_Google_Calendar__list_events
mcp__claude_ai_Google_Calendar__get_event"

# The git subcommands skills/dream/SKILL.md runs, and nothing else (no push,
# no merge, no branch deletion, no -C). Keep in sync with the skill.
SB_DREAM_GIT="rev-parse
status
for-each-ref
log
diff
show
worktree add
worktree list
add
commit
rm"

# sb_write_job_settings <nightly-journal|dream> — write this run's settings
# file and print its path. Needs SECOND_BRAIN_VAULT.
sb_write_job_settings() {
  local job="$1" vault="${SECOND_BRAIN_VAULT%/}" file line
  local allow=() deny=()
  case "$job" in
    nightly-journal)
      # $vault is absolute, so "Edit(/$vault/**)" comes out as "Edit(//Users/...)".
      allow+=("Edit(/$vault/**)" "Bash($(sb_helper_cmd):*)" "Bash(date:*)")
      while IFS= read -r line; do allow+=("$line"); done <<EOF
$SB_JOURNAL_READ_TOOLS
EOF
      ;;
    dream)
      allow+=("Edit(/$SB_DREAM_DIR/**)" "Bash($(sb_helper_cmd):*)" "Bash(date:*)")
      while IFS= read -r line; do allow+=("Bash(git $line:*)"); done <<EOF
$SB_DREAM_GIT
EOF
      [ -n "${SECOND_BRAIN_SLACK_DM:-}" ] && allow+=("mcp__claude_ai_Slack__slack_send_message")
      ;;
    *) echo "sb_write_job_settings: unknown job $job" >&2; return 1 ;;
  esac
  while IFS= read -r line; do [ -n "$line" ] && allow+=("$line"); done <<EOF
$(sb_split_rules "${SECOND_BRAIN_JOB_EXTRA_ALLOW:-}")
EOF

  deny+=("Bash(git push:*)" "Bash(rm:*)" "Bash(curl:*)" "Bash(python3 -c:*)")
  while IFS= read -r line; do [ -n "$line" ] && deny+=("$line"); done <<EOF
$(sb_split_rules "${SECOND_BRAIN_JOB_EXTRA_DENY:-}")
EOF

  mkdir -p "$SB_JOBS_DIR" || return 1
  file="$SB_JOBS_DIR/$job-settings.json"
  {
    printf '{\n  "permissions": {\n    "allow": '
    sb_json_array "${allow[@]}"
    printf ',\n    "deny": '
    sb_json_array "${deny[@]}"
    printf '\n  }\n}\n'
  } > "$file.tmp" && mv "$file.tmp" "$file" || return 1
  printf '%s\n' "$file"
}
