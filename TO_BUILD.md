# TO_BUILD

What the plugins can't carry. A plugin ships skills and hooks; it can't
write user settings, edit your shell, install launchd jobs, or hold secrets.
Build these per machine, only if that machine needs them.

## Every machine

- [ ] **User settings.** `harness/settings.json` is a reference copy:
  `effortLevel`, `tui`, `agentPushNotifEnabled`, `skipAutoPermissionPrompt`,
  and permissions. Merge in the keys you want. Don't copy a `hooks` block;
  the plugin provides the hooks.
- [ ] **Statusline.** Copy `harness/statusline-command.sh` to
  `~/.claude/statusline-command.sh` and set
  `"statusLine": {"type": "command", "command": "bash ~/.claude/statusline-command.sh"}`.
  `/second-brain:setup` offers to do this.
- [ ] **Keep-awake sudoers rule** (only with `SECOND_BRAIN_KEEP_AWAKE=true`;
  not recommended for non-developers):
  `sudo visudo -f /etc/sudoers.d/claude-nosleep`, then add
  `<whoami> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep *`.
- [ ] **Connectors / MCP servers.** Slack, Google Calendar, Gmail, Granola,
  Atlassian, etc. are account-level connectors or `claude mcp add`; the user
  signs in with `/mcp`. `/second-brain:setup` checks for the ones the nightly
  journal uses. The
  private vault's `harness-private/claude/mcp-servers.json` lists what was
  registered before.
- [ ] **Obsidian.** Open the vault folder as a vault. Exclude any config
  folders (e.g. `harness-private`) under Settings → Files & Links.

## Scheduled jobs

Shipped in the `second-brain` plugin (v0.2.0) for macOS. `/second-brain:setup`
installs them; by hand:

```bash
bash <plugin>/scripts/install-scheduled-jobs.sh --dry-run   # preview
bash <plugin>/scripts/install-scheduled-jobs.sh             # install (defaults: journal 20:00, dream Sun 21:00)
bash <plugin>/scripts/install-scheduled-jobs.sh --status    # what's installed
bash <plugin>/scripts/install-scheduled-jobs.sh --uninstall
```

- `com.second-brain.nightly-journal` → `scripts/run-nightly-journal.sh`
  (prompt: `templates/nightly-journal.md`; `--dry-run`, `--date YYYY-MM-DD`,
  `--cap N`).
- `com.second-brain.dream` → `scripts/run-dream.sh` (`/second-brain:dream`,
  plus `--notify` when `SECOND_BRAIN_SLACK_DM` is set).
- Both go through `~/.claude/second-brain/jobs/launch-job.sh`, which finds
  the current plugin directory on each run, so `/plugin update` doesn't
  break them.

Lessons baked in (from the first hand-built setup):

- launchd has no shell PATH; the plists set `PATH` (incl. `~/.local/bin`,
  `/opt/homebrew/bin`) and `HOME`.
- Headless `claude -p` silently denies anything not in
  `permissions.allow`, and can still exit 0. The runners check that the
  journal file / dream branch actually changed. `Edit(...)` rules cover
  file writes; `Write(...)` rules are ignored. No `--permission-mode`
  flags (auto mode blocks creating jobs with them).
- macOS ships bash 3.2: no associative arrays, no negative array offsets,
  no `set -u` with possibly-empty arrays.
- Headless sign-in can expire ("OAuth session expired"). The runners detect
  it, log the fix, and show a macOS notification: open `claude` once and
  sign in.
- Run tracking uses `~/Library/Logs/second-brain/nightly-journal.last-success`,
  not "does today's journal exist", because daytime sessions write to the
  journal too.

Still not migrated: the legacy meeting-debriefs, daily-kickoff, and
weekly-rollup tasks in `scheduled-tasks/` and `harness/launchd/`. Port them
the same way (prompt in `templates/`, a runner script, a plist template)
if they're wanted. Cloud `/schedule` routines don't fit these jobs: they
run on a fresh clone with no access to local transcripts or a local vault.

## Work machines (`work-kit`)

- [ ] **Google OAuth for Drive.** `make-google-doc` and `share-scrubbed-brain`
  read `~/.config/gspread/authorized_user.json` (full Drive scope). Create an
  OAuth client, authorize once, and save the authorized-user JSON there.
  Python deps: `pip install google-api-python-client google-auth`.
- [ ] **Scrub ruleset.** `/work-kit:share-scrubbed-brain` copies
  `scrub-config.example.toml` to `~/.claude/second-brain/scrub-config.toml` on
  first run. Fill in the private exclusions there. It stays out of git.
- [ ] **Hex CLI** for `/work-kit:hex`: https://hex.tech/product/cli.
- [ ] **Branded slide decks.** Not shipped: the old `google-slides` skill
  embedded an employer's template ID and palette. To rebuild at a new job:
  1. **Cache the brand template.** Export the org's `.pptx` once and keep
     it in a work repo. Don't fetch it from Drive at runtime.
  2. **Build on its layouts, don't restyle.** Add slides with the template's
     own layouts (`python-pptx`) so theme colors, fonts, and the 16:9 canvas
     come through.
  3. **Centralize brand constants.** A small `<org>_deck.py` exports
     `load_blank_deck()`, `COLORS`, `FONT`, `LAYOUT`.
  4. **Upload with conversion.** Push to Drive with
     `mimeType: application/vnd.google-apps.presentation` so it lands as native
     Slides.
  5. **Clear unused placeholders.** Otherwise their prompt text renders.

  Watch for short title placeholders with large default fonts: long titles
  overflow silently. Set run-level font sizes instead of resizing the
  placeholder.

## Optional

- **Two brains on one machine.** The old `claude work` / `claude personal`
  shell wrapper is gone. If you ever need it again, write a zsh function that
  sets `SECOND_BRAIN_CONFIG` to a different config file per context before
  running `command claude`.
- **`harness-private/` in the private vault** is a verbatim backup of
  `~/.claude`. With skills and hooks now in the plugins, it only matters for
  settings and MCP config. Its `harness-scrub.toml` whitelist still lists the
  old skill and hook files; trim it to match
  `scripts/harness-scrub.example.toml`.
