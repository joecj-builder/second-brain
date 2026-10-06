#!/bin/bash
# Install (or remove) the second brain's scheduled jobs on macOS:
#
#   com.second-brain.nightly-journal  every evening; journals each weekday
#                                     and backfills missed ones
#   com.second-brain.dream            once a week; runs /second-brain:dream
#
# What it does, in order (safe to re-run; it replaces its own earlier install):
#   1. Copies launch-job.sh to ~/.claude/second-brain/jobs/ (a stable path the
#      plists can point at; the plugin's own directory changes on every update).
#   2. Renders launchd/*.plist.template into ~/Library/LaunchAgents/.
#   3. Adds the permissions the unattended runs need to
#      ~/.claude/settings.json → permissions.allow (backs the file up first,
#      only appends missing rules, never removes anything).
#   4. Loads the jobs with launchctl.
#
# Usage:
#   install-scheduled-jobs.sh [options]
#     --journal-time HH:MM   nightly journal time, 24h (default 20:00)
#     --dream-day DAY        sun mon tue wed thu fri sat, or 0-6 with 0=Sunday (default sun)
#     --dream-time HH:MM     weekly dream time, 24h (default 21:00)
#     --no-journal           don't install the nightly journal (removes it if installed)
#     --no-dream             don't install the weekly dream (removes it if installed)
#     --dry-run              show what would change; write nothing
#     --no-load              write the files but don't call launchctl (testing)
#     --skip-permissions     don't touch ~/.claude/settings.json
#     --allow RULE           also allow this permission rule (repeatable), e.g. a
#                            read-only tool from a connector with a non-standard name
#     --status               show what's installed and exit
#     --uninstall            unload and remove both jobs (permissions are left in place)
#
# Reads the vault from ~/.claude/second-brain/config.env (SECOND_BRAIN_VAULT).
# Needs macOS, jq (ships with macOS 15+ at /usr/bin/jq), and Claude Code.

set -o pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPTS_DIR")"
. "$SCRIPTS_DIR/config.sh"

JOURNAL_LABEL="com.second-brain.nightly-journal"
DREAM_LABEL="com.second-brain.dream"
AGENTS_DIR="$HOME/Library/LaunchAgents"
JOBS_DIR="$HOME/.claude/second-brain/jobs"
LOG_DIR="$HOME/Library/Logs/second-brain"
SETTINGS="$HOME/.claude/settings.json"

journal_time="20:00"
dream_day="sun"
dream_time="21:00"
want_journal=true
want_dream=true
dry_run=false
load=true
do_permissions=true
mode=install
extra_rules=()

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --journal-time) journal_time="$2"; shift 2 ;;
    --dream-day) dream_day="$2"; shift 2 ;;
    --dream-time) dream_time="$2"; shift 2 ;;
    --no-journal) want_journal=false; shift ;;
    --no-dream) want_dream=false; shift ;;
    --dry-run) dry_run=true; shift ;;
    --no-load) load=false; shift ;;
    --skip-permissions) do_permissions=false; shift ;;
    --allow) [ -n "${2:-}" ] || die "--allow needs a rule"; extra_rules+=("$2"); shift 2 ;;
    --status) mode=status; shift ;;
    --uninstall) mode=uninstall; shift ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (try --help)" ;;
  esac
done

[ "$(uname)" = Darwin ] || die "scheduled jobs use launchd, which is macOS only"

# parse_time HH:MM → sets PARSED_HOUR / PARSED_MIN (no leading zeros).
# Sets globals rather than echoing, so die() exits the script, not a subshell.
parse_time() {
  case "$1" in
    [0-9]:[0-5][0-9]|[01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
    *) die "time must be HH:MM in 24-hour form, e.g. 20:00 (got '$1')" ;;
  esac
  PARSED_HOUR=$((10#${1%%:*}))
  PARSED_MIN=$((10#${1##*:}))
}

# parse_day DAY → sets PARSED_DAY (0 = Sunday ... 6 = Saturday)
parse_day() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    0|sun|sunday) PARSED_DAY=0 ;; 1|mon|monday) PARSED_DAY=1 ;;
    2|tue|tuesday) PARSED_DAY=2 ;; 3|wed|wednesday) PARSED_DAY=3 ;;
    4|thu|thursday) PARSED_DAY=4 ;; 5|fri|friday) PARSED_DAY=5 ;;
    6|sat|saturday) PARSED_DAY=6 ;;
    *) die "unknown day '$1' (use sun..sat or 0-6)" ;;
  esac
}

# run <cmd...> — run it, or just print it under --dry-run.
run() {
  if [ "$dry_run" = true ]; then
    echo "  would run: $*"
  else
    "$@"
  fi
}

gui_domain="gui/$(id -u)"

unload_job() {
  local label="$1" plist="$AGENTS_DIR/$1.plist"
  if [ "$load" = true ]; then
    if [ "$dry_run" = true ]; then
      echo "  would run: launchctl bootout $gui_domain/$label (if loaded)"
    else
      launchctl bootout "$gui_domain/$label" >/dev/null 2>&1 || true
    fi
  fi
  if [ -f "$plist" ]; then
    run rm -f "$plist"
    [ "$dry_run" = true ] || echo "Removed $plist"
  fi
}

show_status() {
  local label plist
  for label in "$JOURNAL_LABEL" "$DREAM_LABEL"; do
    plist="$AGENTS_DIR/$label.plist"
    if [ ! -f "$plist" ]; then
      echo "$label: not installed"
      continue
    fi
    local h m wd loaded
    h=$(/usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Hour' "$plist" 2>/dev/null)
    m=$(/usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Minute' "$plist" 2>/dev/null)
    wd=$(/usr/libexec/PlistBuddy -c 'Print :StartCalendarInterval:Weekday' "$plist" 2>/dev/null)
    loaded="not loaded"
    launchctl print "$gui_domain/$label" >/dev/null 2>&1 && loaded="loaded"
    if [ -n "$wd" ]; then
      echo "$label: installed, $loaded, weekly on day $wd (0=Sun) at $(printf '%02d:%02d' "$h" "$m")"
    else
      echo "$label: installed, $loaded, daily at $(printf '%02d:%02d' "$h" "$m") (journals weekdays only)"
    fi
  done
  echo "Logs: $LOG_DIR"
}

if [ "$mode" = status ]; then
  show_status
  exit 0
fi

if [ "$mode" = uninstall ]; then
  unload_job "$JOURNAL_LABEL"
  unload_job "$DREAM_LABEL"
  run rm -rf "$JOBS_DIR"
  echo "Scheduled jobs removed. The permission rules in $SETTINGS were left in place;"
  echo "they only allow read-only connector tools and edits inside the vault."
  exit 0
fi

# --- Preflight -----------------------------------------------------------------

VAULT="${SECOND_BRAIN_VAULT:-}"
[ -n "$VAULT" ] || die "no vault configured. Run /second-brain:setup first."
[ -d "$VAULT" ] || die "vault $VAULT does not exist"
case "$VAULT" in /*) ;; *) die "SECOND_BRAIN_VAULT must be an absolute path (got $VAULT)" ;; esac
VAULT="${VAULT%/}"

JQ=$(command -v jq || true)
if [ -z "$JQ" ] && [ -x /usr/bin/jq ]; then JQ=/usr/bin/jq; fi
[ -n "$JQ" ] || die "jq not found. Install it with: brew install jq"

claude_bin=$(command -v claude || true)
[ -n "$claude_bin" ] || { [ -x "$HOME/.local/bin/claude" ] && claude_bin="$HOME/.local/bin/claude"; }
[ -n "$claude_bin" ] || die "claude not found on PATH or at ~/.local/bin/claude"

parse_time "$journal_time"; journal_hour=$PARSED_HOUR; journal_min=$PARSED_MIN
parse_time "$dream_time"; dream_hour=$PARSED_HOUR; dream_min=$PARSED_MIN
parse_day "$dream_day"; dream_weekday=$PARSED_DAY

if [ "$want_dream" = true ] && ! git -C "$VAULT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "WARNING: $VAULT isn't a git repo yet. The weekly dream needs git; it will"
  echo "         skip itself until you run: git -C \"$VAULT\" init -b main"
fi

# launchd starts jobs with a bare PATH, so give it the places claude, git,
# gh, python3 and Homebrew tools live. Deduplicated, order kept.
job_path=""
for p in "$(dirname "$claude_bin")" "$HOME/.local/bin" /opt/homebrew/bin /opt/homebrew/sbin \
         /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
  case ":$job_path:" in *":$p:"*) ;; *) job_path="${job_path:+$job_path:}$p" ;; esac
done

xml_escape() {
  local s="$1"
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

# render_plist <template> <label> <hour> <minute> [weekday]
render_plist() {
  local t
  t=$(cat "$1")
  t=${t//"{{LABEL}}"/"$2"}
  t=${t//"{{HOUR}}"/"$3"}
  t=${t//"{{MINUTE}}"/"$4"}
  t=${t//"{{WEEKDAY}}"/"${5:-0}"}
  t=${t//"{{HOME}}"/"$(xml_escape "$HOME")"}
  t=${t//"{{PATH}}"/"$(xml_escape "$job_path")"}
  t=${t//"{{VAULT}}"/"$(xml_escape "$VAULT")"}
  t=${t//"{{LOG_DIR}}"/"$(xml_escape "$LOG_DIR")"}
  t=${t//"{{LAUNCHER}}"/"$(xml_escape "$JOBS_DIR/launch-job.sh")"}
  printf '%s\n' "$t"
}

# install_job <label> <template> <hour> <minute> [weekday]
install_job() {
  local label="$1" template="$PLUGIN_ROOT/launchd/$2" plist="$AGENTS_DIR/$1.plist" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/sb-plist.XXXXXX")
  render_plist "$template" "$label" "$3" "$4" "$5" > "$tmp"
  if grep -q '{{' "$tmp"; then
    rm -f "$tmp"; die "unfilled placeholder in $template"
  fi
  plutil -lint -s "$tmp" || { rm -f "$tmp"; die "rendered $label plist failed plutil -lint"; }

  if [ "$dry_run" = true ]; then
    echo "--- would write $plist:"
    cat "$tmp"
    rm -f "$tmp"
    [ "$load" = true ] && echo "  would run: launchctl bootstrap $gui_domain $plist"
    return 0
  fi

  if [ "$load" = true ]; then
    launchctl bootout "$gui_domain/$label" >/dev/null 2>&1 || true
  fi
  mv "$tmp" "$plist"
  chmod 644 "$plist"
  echo "Wrote $plist"
  if [ "$load" = true ]; then
    launchctl bootstrap "$gui_domain" "$plist" || die "launchctl bootstrap failed for $label"
    echo "Loaded $label"
  fi
}

# --- 1. Stable launcher -------------------------------------------------------

echo "== Scheduled jobs for vault $VAULT"
if [ "$dry_run" = true ]; then
  echo "  would copy launch-job.sh to $JOBS_DIR/ and record the plugin path $PLUGIN_ROOT"
else
  mkdir -p "$JOBS_DIR" "$AGENTS_DIR" "$LOG_DIR"
  cp "$SCRIPTS_DIR/launch-job.sh" "$JOBS_DIR/launch-job.sh"
  chmod 755 "$JOBS_DIR/launch-job.sh"
  printf '%s\n' "$PLUGIN_ROOT" > "$JOBS_DIR/plugin-root"
fi

# --- 2. Plists ------------------------------------------------------------------

if [ "$want_journal" = true ]; then
  install_job "$JOURNAL_LABEL" nightly-journal.plist.template "$journal_hour" "$journal_min"
else
  unload_job "$JOURNAL_LABEL"
fi
if [ "$want_dream" = true ]; then
  install_job "$DREAM_LABEL" dream.plist.template "$dream_hour" "$dream_min" "$dream_weekday"
else
  unload_job "$DREAM_LABEL"
fi

# --- 3. Permissions for the unattended runs ------------------------------------
#
# Headless `claude -p` can't ask for approval, so anything not allowed here is
# silently denied and the run produces nothing. Notes:
#   - Edit(...) covers every file-writing tool. Write(...) rules are ignored by
#     file permission checks, so none are added.
#   - "//" starts an absolute path in a permission rule.
#   - Connector tools are read-only, except slack_send_message, which is only
#     added when the weekly dream is set to DM its report (SECOND_BRAIN_SLACK_DM).
#   - No --permission-mode flags anywhere; this allow list is the whole grant.

if [ "$do_permissions" = true ] && { [ "$want_journal" = true ] || [ "$want_dream" = true ]; }; then
  # $VAULT is absolute, so "Edit(/$VAULT/**)" comes out as "Edit(//Users/...)".
  rules=(
    "Edit(/$VAULT/**)"
    "Bash(ls:*)" "Bash(find:*)" "Bash(mkdir:*)" "Bash(date:*)" "Bash(wc:*)"
  )
  if [ "$want_journal" = true ]; then
    rules+=(
      "Bash(python3:*)"
      "Bash(gh auth status:*)" "Bash(gh search:*)" "Bash(gh pr view:*)"
      "mcp__claude_ai_Granola__get_account_info"
      "mcp__claude_ai_Granola__get_meeting_transcript"
      "mcp__claude_ai_Granola__get_meetings"
      "mcp__claude_ai_Granola__list_meeting_folders"
      "mcp__claude_ai_Granola__list_meetings"
      "mcp__claude_ai_Granola__query_granola_meetings"
      "mcp__claude_ai_Slack__slack_read_canvas"
      "mcp__claude_ai_Slack__slack_read_channel"
      "mcp__claude_ai_Slack__slack_read_file"
      "mcp__claude_ai_Slack__slack_read_list"
      "mcp__claude_ai_Slack__slack_read_thread"
      "mcp__claude_ai_Slack__slack_read_user_profile"
      "mcp__claude_ai_Slack__slack_list_channel_members"
      "mcp__claude_ai_Slack__slack_list_user_channels"
      "mcp__claude_ai_Slack__slack_get_reactions"
      "mcp__claude_ai_Slack__slack_search_channels"
      "mcp__claude_ai_Slack__slack_search_public"
      "mcp__claude_ai_Slack__slack_search_public_and_private"
      "mcp__claude_ai_Slack__slack_search_users"
      "mcp__claude_ai_Gmail__search_threads"
      "mcp__claude_ai_Gmail__get_thread"
      "mcp__claude_ai_Google_Drive__search_files"
      "mcp__claude_ai_Google_Drive__get_file_metadata"
      "mcp__claude_ai_Google_Calendar__list_events"
      "mcp__claude_ai_Google_Calendar__get_event"
    )
  fi
  if [ "$want_dream" = true ]; then
    rules+=(
      "Bash(git:*)"
      "Edit(/$(dirname "$VAULT")/$(basename "$VAULT")-dream-*/**)"
    )
    [ -n "${SECOND_BRAIN_SLACK_DM:-}" ] && rules+=("mcp__claude_ai_Slack__slack_send_message")
  fi

  [ "${#extra_rules[@]}" -gt 0 ] && rules+=("${extra_rules[@]}")

  rules_json=$(printf '%s\n' "${rules[@]}" | "$JQ" -R . | "$JQ" -s .)

  if [ -f "$SETTINGS" ]; then
    "$JQ" empty "$SETTINGS" 2>/dev/null || die "$SETTINGS isn't valid JSON; fix it (or move it aside) and re-run"
    current="$SETTINGS"
  else
    current=""
  fi

  # shellcheck disable=SC2016  # $a/$new/$r are jq variables
  missing=$(
    { if [ -n "$current" ]; then cat "$current"; else echo '{}'; fi; } |
      "$JQ" -r --argjson new "$rules_json" \
        '(.permissions.allow // []) as $a | $new[] | select(. as $r | $a | any(. == $r) | not)'
  )

  echo "== Permissions for the unattended runs ($SETTINGS → permissions.allow)"
  if [ -z "$missing" ]; then
    echo "Already in place."
  else
    echo "Adding:"
    printf '%s\n' "$missing" | sed 's/^/  + /'
    if [ "$dry_run" = false ]; then
      mkdir -p "$(dirname "$SETTINGS")"
      if [ -n "$current" ]; then
        backup="$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$SETTINGS" "$backup"
        echo "Backed up the old settings to $backup"
      fi
      tmp=$(mktemp "${TMPDIR:-/tmp}/sb-settings.XXXXXX")
      # shellcheck disable=SC2016  # jq variables
      { if [ -n "$current" ]; then cat "$current"; else echo '{}'; fi; } |
        "$JQ" --argjson new "$rules_json" '
          .permissions = (.permissions // {})
          | .permissions.allow = ((.permissions.allow // []) as $a
              | $a + [$new[] | select(. as $r | $a | any(. == $r) | not)])
        ' > "$tmp" || { rm -f "$tmp"; die "couldn't update $SETTINGS"; }
      [ -n "$current" ] && chmod "$(stat -f '%Lp' "$SETTINGS")" "$tmp"
      mv "$tmp" "$SETTINGS"
      echo "Updated $SETTINGS"
    fi
  fi
fi

# --- 4. Summary -----------------------------------------------------------------

echo
if [ "$dry_run" = true ]; then
  echo "Dry run: nothing was changed."
  exit 0
fi
echo "Done."
[ "$want_journal" = true ] && printf 'Nightly journal: every evening at %02d:%02d (weekdays are journaled; missed ones are caught up).\n' "$journal_hour" "$journal_min"
if [ "$want_dream" = true ]; then
  days=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)
  printf 'Weekly review (/dream): %ss at %02d:%02d.\n' "${days[$dream_weekday]}" "$dream_hour" "$dream_min"
fi
echo "If the Mac is asleep at that time, the job runs when it wakes up. If it's"
echo "shut down, the next evening's journal run catches up the missed weekdays."
echo "Logs: $LOG_DIR"
echo "Test the journal now: bash \"$JOBS_DIR/launch-job.sh\" nightly-journal --date $(date +%Y-%m-%d)"
