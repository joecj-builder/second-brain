# shellcheck shell=bash
# Sourced by run-nightly-journal.sh and run-dream.sh (the scheduled jobs).
# Loads the second-brain config and defines small helpers shared by both.
#
# Written for macOS's stock /bin/bash 3.2: no associative arrays, no negative
# array offsets, and no `set -u` (3.2 treats "${empty_array[@]}" as unbound).

SB_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB_PLUGIN_ROOT="$(dirname "$SB_SCRIPTS_DIR")"
. "$SB_SCRIPTS_DIR/config.sh"

SB_LOG_DIR="$HOME/Library/Logs/second-brain"
mkdir -p "$SB_LOG_DIR"

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
