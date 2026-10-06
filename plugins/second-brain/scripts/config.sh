# Sourced by the other scripts. Loads this machine's second-brain config,
# written by /second-brain:setup. SECOND_BRAIN_CONFIG points elsewhere for
# testing against a throwaway vault.
#
# Keys (all optional except SECOND_BRAIN_VAULT):
#   SECOND_BRAIN_VAULT                 absolute path to the Obsidian vault
#   SECOND_BRAIN_TIMEZONE              IANA timezone, e.g. America/Denver
#   SECOND_BRAIN_SLACK_DM              Slack channel/user ID for /dream --notify
#   SECOND_BRAIN_KEEP_AWAKE            true = keep the Mac awake while Claude works
#   SECOND_BRAIN_AUTODOC               false = don't /document on session end (default true)
#   SECOND_BRAIN_AUTODOC_MIN_PROMPTS   prompts needed before auto-document runs (default 3)
#   SECOND_BRAIN_SLACK_USER_ID         the user's Slack member ID, for the nightly journal's Slack search
#   SECOND_BRAIN_NIGHTLY_JOURNAL_CAP   max missed weekdays one nightly run backfills (default 5)
#   SECOND_BRAIN_NIGHTLY_JOURNAL_TEMPLATE  custom nightly journal prompt (default: templates/nightly-journal.md)
#   SECOND_BRAIN_JOB_NOTIFY            false = no macOS notifications from the scheduled jobs (default true)

SECOND_BRAIN_CONFIG="${SECOND_BRAIN_CONFIG:-$HOME/.claude/second-brain/config.env}"
if [ -f "$SECOND_BRAIN_CONFIG" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$SECOND_BRAIN_CONFIG"
  set +a
fi
