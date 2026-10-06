#!/bin/bash
# Stable entry point for the second-brain launchd jobs.
#
# install-scheduled-jobs.sh copies this file to ~/.claude/second-brain/jobs/
# and the plists call it there. Installed plugins run from a versioned cache
# directory (~/.claude/plugins/cache/<marketplace>/second-brain/<version>/)
# that changes on every /plugin update, so a plist pointing into the plugin
# would break after the first update. This finds the current plugin directory
# each time and hands off to the job script inside it.
#
# Usage: launch-job.sh nightly-journal|dream [job args...]

job="${1:?usage: launch-job.sh nightly-journal|dream [args...]}"
shift

jobs_dir="$(cd "$(dirname "$0")" && pwd)"
registry="$HOME/.claude/plugins/installed_plugins.json"
# Written at install time: the plugin directory install-scheduled-jobs.sh ran from.
fallback="$(cat "$jobs_dir/plugin-root" 2>/dev/null)"

root=""
case "$fallback" in
  "$HOME/.claude/plugins/"*|"")
    # Installed from a marketplace: ask the plugin registry for the current
    # install path, so updates are picked up without reinstalling the jobs.
    if [ -f "$registry" ] && command -v jq >/dev/null 2>&1; then
      while IFS= read -r p; do
        if [ -n "$p" ] && [ -f "$p/scripts/run-$job.sh" ]; then
          root="$p"
          break
        fi
      done <<EOF
$(jq -r '.plugins // {} | to_entries[] | select(.key | startswith("second-brain@")) | .value[]? | .installPath // empty' "$registry" 2>/dev/null)
EOF
    fi
    ;;
esac
# A development checkout (or a registry miss) uses the install-time path.
[ -z "$root" ] && [ -f "$fallback/scripts/run-$job.sh" ] && root="$fallback"

if [ -z "$root" ]; then
  log_dir="$HOME/Library/Logs/second-brain"
  mkdir -p "$log_dir"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: couldn't find the second-brain plugin (job $job). Reinstall it, then run /second-brain:setup." >> "$log_dir/$job.log"
  [ "${SECOND_BRAIN_JOB_NOTIFY:-true}" = true ] && osascript -e 'display notification "Scheduled job could not find the second-brain plugin. Run /second-brain:setup in Claude." with title "Second brain"' >/dev/null 2>&1
  exit 1
fi

exec /bin/bash "$root/scripts/run-$job.sh" "$@"
