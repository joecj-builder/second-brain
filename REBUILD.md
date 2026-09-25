# REBUILD

How to stand the second brain back up on a machine that has nothing on it.

Written for the case that matters: **you have left the employer whose laptop
this was built on.** Anything that lived only on that machine, or only in a
repo behind their SSO, is gone. What survives is what was pushed to your
personal GitHub account.

## What you are rebuilding

| Layer | Comes from | How it comes back |
|---|---|---|
| Vault content | your vault repo (e.g. `obsidian-vault-personal`, private) | `git clone` |
| Behavior: skills, hooks, protocol | this repo's plugins | `/plugin install` |
| Machine config: settings, statusline, connectors | `harness/` + [TO_BUILD.md](TO_BUILD.md) | by hand, as needed |
| Scheduled jobs | `harness/launchd/` + `scheduled-tasks/` | by hand, as needed |

The first two are the second brain. The last two depend on what the machine
is for.

## 0. Prerequisites

```bash
# Homebrew, if the machine is fresh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install git gh jq python@3.12
brew install --cask obsidian

# Claude Code
curl -fsSL https://claude.ai/install.sh | bash

gh auth login          # personal account
```

Python 3.11+ is needed for the work-kit scripts and `scripts/*.py` (`tomllib`).

## 1. Vault

```bash
mkdir -p ~/obsidian-vaults
git clone https://github.com/josephcoz/obsidian-vault-personal.git ~/obsidian-vaults/Personal
```

Starting fresh instead? Skip this; setup scaffolds a new vault.

## 2. Plugins

In Claude Code:

```
/plugin marketplace add josephcoz/second-brain
/plugin install second-brain@second-brain
/plugin install work-kit@second-brain        # work machines only
/second-brain:setup
```

Setup asks for the vault path and writes `~/.claude/second-brain/config.env`.
It also points `autoMemoryDirectory` at `<vault>/Memory` and asks about
auto-document and keep-awake.

## 3. Machine config

Work through [TO_BUILD.md](TO_BUILD.md) and skip what this machine doesn't
need: settings keys, statusline, connectors, Google OAuth, scrub ruleset.

**Just want your old setup back verbatim?** The private vault carries a raw
backup of `~/.claude` that rewrites the old home path to the new one:

```bash
~/obsidian-vaults/Personal/harness-private/restore-harness.sh
```

It predates the plugins and restores the old skills and hooks as loose files
in `~/.claude/`. After running it, delete `~/.claude/skills/{document,dream}`
and `~/.claude/hooks/session-start-context.sh`, and remove their
`settings.json` hook entries, so they don't run alongside the plugin.

## 4. Scheduled jobs (optional)

```bash
cd ~/github-projects/second-brain     # clone it first
cp scripts/harness-values.example.toml scripts/harness-values.toml
$EDITOR scripts/harness-values.toml    # every field is commented
python3 scripts/fill-harness.py        # writes ./harness-filled for review
cp harness-filled/launchd/*.plist ~/Library/LaunchAgents/
for f in ~/Library/LaunchAgents/com.*.plist; do launchctl load "$f"; done
```

- **`home`** must be absolute. launchd doesn't expand `~`, and a plist that
  contains one loads fine and then never runs.
- The work-side jobs need a host repo at `work_automation_repo` with
  `config.yaml` and `scripts/tasks/*.prompt.md`. At a new employer that repo
  doesn't exist yet. See `SETUP.md`, and start from `config.example.yaml`.

## 5. Verify

Start a new session in any directory:

- The first lines of context read `Second brain vault: <path>`.
- `/second-brain:dream --quick` creates a `dream/<week>` branch in the vault.
- Ask something only the vault knows (`"who is <someone in People/>"`). It
  should do the 3-tier lookup rather than guess.
- Have a session with 3+ prompts, then exit. Within a minute,
  `~/.claude/second-brain/auto-document.log` has an entry and the vault has
  an `auto-document:` commit.

---

## Keeping this true

- **Plugins.** Edit under `plugins/`, bump `version` in `plugin.json`,
  push. Each machine picks up the change with `/plugin update`.
- **`harness/`** is generated from the live `~/.claude` by
  `python3 scripts/sanitize-harness.py`, and `--check` confirms it's current.
  It only covers settings, statusline, and launchd now. The sanitizer fails
  closed: if a new secret or employer name shows up in `~/.claude`, the
  forbidden-pattern gate stops the run instead of publishing it.
