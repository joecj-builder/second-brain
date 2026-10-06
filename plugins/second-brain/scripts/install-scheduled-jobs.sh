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
#   3. Loads the jobs with launchctl.
#
# Permissions: this script doesn't touch ~/.claude/settings.json. Each run
# writes its own allow list to ~/.claude/second-brain/jobs/<job>-settings.json
# and passes it with `claude -p --settings` (sb_write_job_settings in
# job-lib.sh), so only the scheduled runs get these permissions; the user's
# normal Claude sessions don't change. The runs can read Slack, Gmail, Drive,
# Calendar and Granola, edit files in the vault, run a fixed set of git
# commands in the weekly-review folder, and run the plugin's read-only
# journal-helper.py (which also looks up the user's GitHub PRs).
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
#     --allow RULE           also allow this rule in the scheduled runs (repeatable),
#                            e.g. a read-only tool from a connector with a
#                            non-standard name. Saved to config.env as
#                            SECOND_BRAIN_JOB_EXTRA_ALLOW; never added globally.
#     --status               show what's installed and exit
#     --uninstall            unload and remove both jobs and everything in
#                            ~/.claude/second-brain/jobs/
#
# Reads the vault from ~/.claude/second-brain/config.env (SECOND_BRAIN_VAULT).
# When SECOND_BRAIN_CONFIG points at another config (testing), the plists
# carry it, so the scheduled runs use that config too.
# Needs macOS and Claude Code.

set -o pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPTS_DIR")"
# A non-default config (testing) is passed on to the jobs.
config_override=""
if [ -n "${SECOND_BRAIN_CONFIG:-}" ] && [ "$SECOND_BRAIN_CONFIG" != "$HOME/.claude/second-brain/config.env" ]; then
  config_override="$SECOND_BRAIN_CONFIG"
fi
. "$SCRIPTS_DIR/config.sh"

JOURNAL_LABEL="com.second-brain.nightly-journal"
DREAM_LABEL="com.second-brain.dream"
AGENTS_DIR="$HOME/Library/LaunchAgents"
JOBS_DIR="$HOME/.claude/second-brain/jobs"
LOG_DIR="${SECOND_BRAIN_LOG_DIR:-$HOME/Library/Logs/second-brain}"

journal_time="20:00"
dream_day="sun"
dream_time="21:00"
want_journal=true
want_dream=true
dry_run=false
load=true
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
    --allow)
      [ -n "${2:-}" ] || die "--allow needs a rule"
      case "$2" in *";"*) die "a rule can't contain ';' (got $2)" ;; esac
      extra_rules+=("$2"); shift 2 ;;
    --status) mode=status; shift ;;
    --uninstall) mode=uninstall; shift ;;
    -h|--help) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  echo "Scheduled jobs removed, with their launcher and permission files ($JOBS_DIR)."
  echo "Nothing was ever added to ~/.claude/settings.json, so there's nothing to undo there."
  exit 0
fi

# --- Preflight -----------------------------------------------------------------

VAULT="${SECOND_BRAIN_VAULT:-}"
[ -n "$VAULT" ] || die "no vault configured. Run /second-brain:setup first."
[ -d "$VAULT" ] || die "vault $VAULT does not exist"
case "$VAULT" in /*) ;; *) die "SECOND_BRAIN_VAULT must be an absolute path (got $VAULT)" ;; esac
VAULT="${VAULT%/}"

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

# Extra plist environment: the test config, when one is in use.
extra_env=""

xml_escape() {
  local s="$1"
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

if [ -n "$config_override" ]; then
  extra_env="
		<key>SECOND_BRAIN_CONFIG</key>
		<string>$(xml_escape "$config_override")</string>"
fi

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
  t=${t//"{{EXTRA_ENV}}"/"$extra_env"}
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

# --- 3. Extra permission rules (--allow) ----------------------------------------
#
# Saved to config.env, where each run's settings file picks them up. They
# apply to the scheduled runs only.

if [ "${#extra_rules[@]}" -gt 0 ]; then
  current_rules=$(sb_split_rules "${SECOND_BRAIN_JOB_EXTRA_ALLOW:-}")
  merged="${SECOND_BRAIN_JOB_EXTRA_ALLOW:-}"
  added=()
  for r in "${extra_rules[@]}"; do
    if ! printf '%s\n' "$current_rules" | grep -qxF -- "$r"; then
      added+=("$r")
      merged="${merged:+$merged;}$r"
      current_rules="$current_rules
$r"
    fi
  done
  echo "== Extra rules for the scheduled runs ($SECOND_BRAIN_CONFIG → SECOND_BRAIN_JOB_EXTRA_ALLOW)"
  if [ "${#added[@]}" -eq 0 ]; then
    echo "Already in place."
  else
    printf '  + %s\n' "${added[@]}"
    if [ "$dry_run" = false ]; then
      [ -f "$SECOND_BRAIN_CONFIG" ] || die "$SECOND_BRAIN_CONFIG not found; run /second-brain:setup first"
      quoted="'${merged//\'/\'\\\'\'}'"
      tmp=$(mktemp "${TMPDIR:-/tmp}/sb-config.XXXXXX")
      grep -v '^SECOND_BRAIN_JOB_EXTRA_ALLOW=' "$SECOND_BRAIN_CONFIG" > "$tmp"
      printf 'SECOND_BRAIN_JOB_EXTRA_ALLOW=%s\n' "$quoted" >> "$tmp"
      chmod "$(stat -f '%Lp' "$SECOND_BRAIN_CONFIG")" "$tmp"
      mv "$tmp" "$SECOND_BRAIN_CONFIG"
      echo "Updated $SECOND_BRAIN_CONFIG"
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
echo "Only these scheduled runs get the permissions they need, one run at a time;"
echo "your normal Claude sessions don't change."
echo "Logs: $LOG_DIR"
echo "Test the journal now: bash \"$JOBS_DIR/launch-job.sh\" nightly-journal --date $(date +%Y-%m-%d)"
