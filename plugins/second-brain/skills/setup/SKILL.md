---
name: setup
description: >
  One-time setup of the second brain on this machine, written so a
  non-developer can finish it: check the basics (Apple developer tools,
  Homebrew, GitHub CLI, Obsidian, git identity), choose the vault, write
  ~/.claude/second-brain/config.env, point Claude Code's auto-memory at the
  vault, scaffold a new vault from the template, check connectors (Slack,
  Gmail, Calendar, Drive, Granola), install the scheduled jobs (nightly
  journal + weekly /dream) with a test run, and opt in to extras. Use right
  after installing the second-brain plugin, when the session-start context
  says the second brain isn't configured, or when the user says "/setup",
  "set up my second brain", "set up the nightly journal", or "change my vault".
allowed-tools: Bash, Read, Edit, Write, Glob
---

# setup — Agent Skill

A plugin can't write user settings, install background jobs, or sign in to
anything by itself, so this skill does the one-time, per-machine part. It is
also the runbook: someone who has never used a terminal should be able to
finish it with you.

## How to run this skill

- **Assume the user isn't a developer.** Plain English, no jargon. When you
  need them to do something, give one step at a time, the exact thing to
  type or click, and what they'll see when it worked. Wait for them before
  moving on.
- **Check before you ask.** Run the check yourself; only involve the user
  when something is missing or a choice is theirs.
- **Never fail quietly.** If a check fails, explain what it's for in one line
  and walk them through the fix below. If they want to skip something, say
  what they lose and continue.
- **Things only the user can do:** type their Mac password, sign in through a
  browser (GitHub, connectors), and approve Claude's permission prompts. A
  command you want them to run inside Claude Code starts with `!` (for
  example `! gh auth login`); tell them to type it at the prompt and press
  Enter. Anything that asks for the Mac password goes in a separate
  Terminal window (Cmd+Space, type "Terminal", Enter).
- **When a restart is needed, say so plainly:** "Type `/exit`, then run
  `claude` again." New plugins, slash commands, and some shell changes only
  load in a fresh session. If the user ever sees `Unknown skill`, that's the
  fix.
- Confirm before every write outside the vault, and keep every step safe to
  re-run. If the user comes back halfway through, pick up where they left off.

## 1. Read what's already there

```bash
cat ~/.claude/second-brain/config.env 2>/dev/null
jq '.autoMemoryDirectory' ~/.claude/settings.json 2>/dev/null
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-scheduled-jobs.sh" --status
```

If a config exists, show it in a few plain lines and ask what to change
instead of starting over.

## 2. Check the basics

Run all of these, then tell the user in one short list what's in place and
what isn't. Fix the missing ones in this order, one at a time.

```bash
xcode-select -p 2>/dev/null || echo "MISSING: command line tools"
command -v brew || ls /opt/homebrew/bin/brew 2>/dev/null || echo "MISSING: brew"
grep -q 'brew shellenv' ~/.zshrc 2>/dev/null || echo "MISSING: brew in ~/.zshrc"
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 && echo "gh: signed in" || echo "MISSING: gh, or not signed in"
ls -d /Applications/Obsidian.app 2>/dev/null || echo "MISSING: Obsidian"
command -v jq || echo "MISSING: jq"
git config --global user.name; git config --global user.email
command -v claude
```

- **Apple's command line tools** (git and python3 are only stubs without
  them; the vault's history and the nightly journal need both). Homebrew's
  installer adds them. On their own: `xcode-select --install`, then click
  Install in the window that pops up (5–10 minutes).
- **Homebrew** (an app store for the tools Claude uses). In a Terminal
  window, paste the command from https://brew.sh:
  `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`.
  It asks for their Mac password; warn them that nothing appears while they
  type it, which is normal. It takes 5–10 minutes.
- **Homebrew on the PATH.** If `brew` exists at `/opt/homebrew/bin/brew` but
  `command -v brew` fails, or the `~/.zshrc` check says missing, add the line
  to **`~/.zshrc`** (not `~/.zprofile`; Claude's `!` shell only reads
  `~/.zshrc`):
  ```bash
  grep -q 'brew shellenv' ~/.zshrc 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zshrc
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ```
  Without it they'll keep getting `command not found: brew`. Use the full
  `/opt/homebrew/bin/...` paths for the rest of this session if needed.
- **GitHub CLI** (backs up the vault, lets the journal see their pull
  requests). Install with `brew install gh`. Then the user signs in
  themselves, so they can see the one-time code: have them type
  `! gh auth login --web --git-protocol https`, copy the 8-character code it
  prints, press Enter, and paste the code into the browser page that opens.
  If that gets stuck, have them run `gh auth login` in a Terminal window
  instead (choose GitHub.com → HTTPS → Login with a web browser). Never run
  `gh auth login` yourself: the code would be hidden in your output. Then
  run `gh auth setup-git`. Skippable: without it, the journal skips GitHub.
- **Obsidian** (the app for reading the vault). `brew install --cask obsidian`.
- **jq** (needed to update Claude's settings safely). It ships with recent
  macOS; otherwise `brew install jq`.
- **Git name and email** (every vault commit needs them). If either is
  empty, ask for their name and work email and set
  `git config --global user.name "<name>"` and
  `git config --global user.email "<email>"`.
- **claude** must be found on the PATH or at `~/.local/bin/claude`; the
  scheduled jobs look there. If it isn't, add
  `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`.

## 3. Choose the vault

If the user already created a vault in Obsidian, use that folder. Otherwise
suggest `~/work-vault` on a work machine (or `~/obsidian-vaults/<Name>`).
Expand `~` to the full path before writing it anywhere. Then find out which
case applies:

- **Existing vault on disk** — use it as is.
- **Vault in a git repo, not cloned yet** — ask for the URL and
  `git clone <url> <path>`.
- **New vault** — go to step 5 after writing the config.

If Obsidian doesn't have this folder open yet, tell them: open Obsidian →
"Open folder as vault" → choose the folder. (For a new vault, do this after
step 5 creates it.)

One machine, one vault. A different vault for a different purpose belongs on
a different machine (or a different config file via `SECOND_BRAIN_CONFIG`).

## 4. Write `~/.claude/second-brain/config.env`

Ask about each optional key and explain it in one line. Keep the defaults
unless the user says otherwise:

| Key | Default | What it does |
|---|---|---|
| `SECOND_BRAIN_VAULT` | (required) | Absolute vault path |
| `SECOND_BRAIN_TIMEZONE` | output of `readlink /etc/localtime` (the part after `zoneinfo/`) | Used for dates in journals and rollups |
| `SECOND_BRAIN_AUTODOC` | `true` | Run `/second-brain:document --auto` when a session ends. Costs one extra headless run per qualifying session |
| `SECOND_BRAIN_AUTODOC_MIN_PROMPTS` | `3` | Skip sessions shorter than this |
| `SECOND_BRAIN_SLACK_USER_ID` | filled in step 7 | The user's Slack member ID, for the nightly journal |
| `SECOND_BRAIN_SLACK_DM` | empty | Slack channel or member ID that `/dream --notify` DMs the weekly report to |
| `SECOND_BRAIN_NIGHTLY_JOURNAL_CAP` | `5` | Most missed weekdays one nightly run will catch up |
| `SECOND_BRAIN_KEEP_AWAKE` | `false` | macOS: keep the Mac awake with the lid closed while Claude works (step 9) |

Write it as plain `KEY="value"` lines with a header comment saying the file
was written by `/second-brain:setup`. `mkdir -p ~/.claude/second-brain` first.
Later steps add to this file; edit the line in place rather than appending a
duplicate.

## 5. Scaffold a new vault (new vaults only)

Only when the target directory is missing or empty:

```bash
mkdir -p <vault>
cp -R ${CLAUDE_PLUGIN_ROOT}/vault-template/. <vault>/
```

Then ask for the user's name, role, and (if it's a work machine) company.
Replace `{{user_name}}`, `{{user_role}}`, `{{company}}`, and `{{vault_path}}` in the
copied files; on a personal machine, drop the "at {{company}}" phrases instead. Fill `Memory/MEMORY.md`'s identity section from the same
answers. Leave `[Fill in: …]` prompts for the user to complete in Obsidian.

Then make it git-backed (`/dream` and auto-document need git):

```bash
git -C <vault> init -b main && git -C <vault> add -A && git -C <vault> commit -m "Scaffold second brain"
```

For an existing vault that isn't a git repo, offer the same `git init`.

## 6. Point auto-memory at the vault

Show the change first, then merge `autoMemoryDirectory` into
`~/.claude/settings.json` without touching other keys:

```bash
tmp=$(mktemp) && jq --arg d "<vault>/Memory" '.autoMemoryDirectory = $d' ~/.claude/settings.json > "$tmp" && mv "$tmp" ~/.claude/settings.json
```

If `settings.json` doesn't exist, create it as `{"autoMemoryDirectory": "<vault>/Memory"}`.
Make sure `<vault>/Memory/MEMORY.md` exists.

## 7. Check connectors

The nightly journal is built from the user's work tools. Without them it can
only see Claude sessions and vault edits, and entries will be thin.

Look at the tools available in this session. For each of **Slack, Gmail,
Google Calendar, Google Drive, and Granola**, a connector counts as
connected when tools with that name in them are listed (for example
`mcp__claude_ai_Slack__slack_search_users`). Tell the user which are
connected and which aren't, and that they only need the tools they actually
use at work.

For the missing ones, you can't sign in for them. Walk them through it:

1. Type `/mcp` and press Enter.
2. Pick the tool, choose to authenticate, and sign in in the browser window
   that opens. Repeat for each one.
3. If a tool isn't in the `/mcp` list, add it first at claude.ai → Settings
   → Connectors, then come back to `/mcp`.

If the new tools still don't show up, have them restart (`/exit`, then
`claude`) and run `/second-brain:setup` again; it picks up where it left off.

**Connector names matter for the scheduled jobs.** The install script allows
the standard claude.ai connector tools (`mcp__claude_ai_Slack__…`,
`mcp__claude_ai_Gmail__…`, `mcp__claude_ai_Google_Calendar__…`,
`mcp__claude_ai_Google_Drive__…`, `mcp__claude_ai_Granola__…`). If a
connector's tools use a different prefix here (say `mcp__slack__…`), note
the read-only tools the journal needs (search, list, read, and get tools
only — never send, create, update, or delete) and pass each one to the
install script in step 8 with `--allow <tool name>`.

**Slack member ID.** If Slack is connected and `SECOND_BRAIN_SLACK_USER_ID`
is empty, look the user up yourself (search Slack users by their name or
work email, or read their own profile) instead of asking for the ID.
Confirm the name with them, then write `SECOND_BRAIN_SLACK_USER_ID="<id>"`
to `config.env`.

## 8. Scheduled jobs (recommended)

Explain in two lines: every weekday evening Claude writes a journal of the
day (meetings, Slack, files shared, Claude sessions, GitHub) into the vault,
and once a week it tidies the vault on a review branch (`/dream`) that they
can adopt or discard. This is what makes the vault fill itself.

If they want it (recommend yes):

1. **Ask for times.** Nightly journal: default **8:00 pm**. Weekly review:
   default **Sunday 9:00 pm**. Ask whether they want a Slack DM when the
   weekly review is ready; if yes, set `SECOND_BRAIN_SLACK_DM` to their
   member ID. Tell them that also lets the scheduled runs send Slack
   messages without asking.
2. **Preview.** Run the installer in dry-run mode yourself and summarize
   what it will do in plain words (two background jobs, and which
   permissions it adds to `~/.claude/settings.json`):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-scheduled-jobs.sh" --dry-run --journal-time 20:00 --dream-day sun --dream-time 21:00
   ```
   Why the permissions: the scheduled runs happen with nobody at the
   keyboard, so anything not on that list is silently refused and the run
   writes nothing. The list is read-only connector tools, edits inside the
   vault (and its dream review folder), and a few basic commands.
3. **Install.** Have the user run it themselves, with their chosen times
   and any `--allow` flags from step 7 (Claude Code blocks Claude from
   changing its own permission settings, and this way they see what it
   does). Give them the line with the real path filled in:
   ```
   ! bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-scheduled-jobs.sh" --journal-time 20:00 --dream-day sun --dream-time 21:00
   ```
   It backs up `settings.json` before changing it, only adds rules, and is
   safe to run again (for example, to change the times). Never add
   `--permission-mode` or `--dangerously-skip-permissions` to anything; the
   allow list is the whole grant.
4. **Test run.** Run one journal now, in the background, and tell the user it
   takes about 3–10 minutes:
   ```bash
   bash ~/.claude/second-brain/jobs/launch-job.sh nightly-journal --date "$(date +%Y-%m-%d)"
   ```
   When it finishes, check both: the log ends with `OK: <date>`
   (`tail -20 ~/Library/Logs/second-brain/nightly-journal.log`), and
   `<vault>/Journal/<date>.md` exists. Don't trust the exit code alone;
   `claude -p` can exit cleanly after being refused a permission. Tell the
   user to open today's note in Obsidian.
   If it failed, read the log. A "permission" or "denied" message names the
   missing tool: have them re-run the install line with `--allow <tool>`. A
   sign-in error means they should run `claude` once in Terminal and sign
   in. Then test again.
5. **What to expect.** Tell them, briefly:
   - The Mac needs to be on. If it's asleep at run time, the job runs when it
     wakes; if it was off, the next evening's run catches up the missed
     weekdays (up to 5). Weekends are skipped.
   - If the journal or review fails, a Mac notification says so. The usual
     cause is Claude's sign-in expiring when they haven't opened `claude` in
     a while: open Terminal, run `claude`, sign in if asked, `/exit`.
   - Logs live in `~/Library/Logs/second-brain/`. To change times, run the
     install line again; `--uninstall` removes both jobs.

## 9. Extras (ask about each; all optional)

- **Keep-awake** (`SECOND_BRAIN_KEEP_AWAKE`): keeps the Mac awake with the
  lid closed while Claude is working. **Recommend No** unless the user is a
  developer comfortable editing system files: it needs a sudoers rule. If
  they want it, print this line and tell them to add it with
  `sudo visudo -f /etc/sudoers.d/claude-nosleep` themselves, in a Terminal
  window. Never run sudo for them:
  `<whoami output> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep *`
- **Things the plugin doesn't carry.** Point at `TO_BUILD.md` in the plugin's
  repo (https://github.com/josephcoz/second-brain) for the statusline and
  user settings.

## 10. Confirm

Tell the user what was set up, in 4–6 plain lines:
- the vault, and that auto-memory now points at it
- whether auto-document is on
- which connectors are connected
- whether the scheduled jobs are installed, their times, and whether the test
  journal worked

Then tell them to restart (`/exit`, then `claude`) so the next session starts
with the vault loaded, and that a good first question is "What do you know
about me?". The first week, they just use Claude normally; the vault fills
in each night.
