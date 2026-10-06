# Second Brain

An Obsidian vault as Claude Code's persistent memory store. Sessions are
ephemeral; the vault is permanent. Claude reads it before guessing, writes
durable facts into it as it learns them, hands off each session into it, and
periodically consolidates it on a review branch.

## Not a developer? Start here

You need a Mac, Claude Code (`curl -fsSL https://claude.ai/install.sh | bash`
in Terminal, then run `claude` and sign in), and about 45 minutes. Then, inside
`claude`, paste these two lines:

```
/plugin marketplace add josephcoz/second-brain
/plugin install second-brain@second-brain
```

Type `/exit`, run `claude` again (plugins only load in a new session; if you
see `Unknown skill`, that's why), and run:

```
/second-brain:setup
```

It walks you through the rest one step at a time: Homebrew, GitHub, Obsidian,
your vault, connecting Slack / Gmail / Calendar / Drive / Granola, and the
nightly journal. It ends with a test journal entry you can open in Obsidian.
Stuck anywhere? Paste the error into `claude` and ask what to do.

This repo is a Claude Code **plugin marketplace** with two plugins:

| Plugin | Install on | What it adds |
|---|---|---|
| `second-brain` | every machine | `/second-brain:protocol` (lookup and write rules), `/second-brain:document`, `/second-brain:dream`, `/second-brain:setup`, a SessionStart hook that names the vault, an automatic `/document` when a session ends, and (macOS) a scheduled nightly journal + weekly `/dream` |
| `work-kit` | work machines | `/work-kit:make-google-doc`, `/work-kit:hex`, `/work-kit:share-scrubbed-brain` |

One machine has one second brain. The vault is picked once, at setup.

## Install

```bash
# 1. Get the vault onto the machine (or skip; setup can create a new one)
git clone <your-vault-repo> ~/obsidian-vaults/<Name>
```

Then in Claude Code:

```
/plugin marketplace add josephcoz/second-brain
/plugin install second-brain@second-brain
/plugin install work-kit@second-brain        # work machines only
/second-brain:setup
```

`/second-brain:setup` checks the prerequisites, writes
`~/.claude/second-brain/config.env`, points auto-memory at `<vault>/Memory`,
(for a new vault) scaffolds it from `plugins/second-brain/vault-template/` and
runs `git init`, checks connectors, and installs the scheduled jobs. Start a
new session afterwards; the first lines of context should name the vault.

Update later with `/plugin marketplace update second-brain`, then
`/plugin update second-brain@second-brain`. The scheduled jobs follow the
update on their own.

## How it works

- **SessionStart** injects the vault path and tells Claude to load
  `/second-brain:protocol` before touching the vault.
- **Auto-memory** writes to `<vault>/Memory/`; `MEMORY.md` there is the
  manifest Claude loads every session.
- **`/document`** writes a handoff (plan file, `NEXT_SESSION.md`, or the vault)
  and persists durable facts into the vault graph.
- **Auto-document**: when a session with at least 3 prompts ends, a
  SessionEnd hook starts a detached headless run that resumes it and runs
  `/second-brain:document --auto`. That writes `Sessions/YYYY-MM-DD <slug>.md`
  in the vault and commits it. The log is `~/.claude/second-brain/auto-document.log`.
  Each qualifying session costs one extra headless run; turn it off with
  `SECOND_BRAIN_AUTODOC=false` in the config.
- **`/dream`** consolidates the vault (dedup, archive, resolve contradictions,
  trim `MEMORY.md`) on a `dream/<week>` git branch you adopt or discard.
- **Scheduled jobs** (macOS launchd, installed by setup through
  `plugins/second-brain/scripts/install-scheduled-jobs.sh`):
  - `com.second-brain.nightly-journal` runs every evening (default 8pm) and
    writes `Journal/YYYY-MM-DD.md` for each weekday from whichever of
    Granola, Google Calendar, Slack, Gmail, Drive, GitHub, and local Claude
    sessions are available. Missed weekdays are backfilled (up to 5). The
    prompt is `plugins/second-brain/templates/nightly-journal.md`.
  - `com.second-brain.dream` runs `/second-brain:dream` weekly (default
    Sunday 9pm).
  - Headless runs can't ask for permission, so the installer adds a
    read-only allow list to `~/.claude/settings.json` (backed up first).
    Logs are in `~/Library/Logs/second-brain/`; failures also show a macOS
    notification. Re-run the installer with `--status`, new times, or
    `--uninstall`.

## What the plugins don't carry

Plugins can ship skills and hooks, but not user settings, shell config,
or secrets. Scheduled jobs ship as scripts that `/second-brain:setup`
installs. The rest is listed in [TO_BUILD.md](TO_BUILD.md), to build per
machine as needed.

## Developing

```bash
claude --plugin-dir plugins/second-brain --plugin-dir plugins/work-kit
```

loads the plugins straight from the working tree (`/reload-plugins` picks up
edits). Point `SECOND_BRAIN_CONFIG` at a throwaway config to test against a
scratch vault. Bump `version` in the plugin's `.claude-plugin/plugin.json`
when you ship a change.

## Rest of the repo

- `scheduled-tasks/`, `config.example.yaml`, `SETUP.md` — **legacy**: the
  pre-plugin journal / rollup / kickoff / meeting-debrief pipeline. The
  nightly journal and weekly dream now ship in the plugin (see "Scheduled
  jobs" above). Kept because existing machines still run these by path.
- `harness/` — templated reference copies of user settings, the statusline,
  and launchd plists. Generated by `scripts/sanitize-harness.py`, filled by
  `scripts/fill-harness.py`. Its launchd plists are **legacy**; new machines
  get theirs from `/second-brain:setup`.
- `sharing/`, `simple-setup.md` — **superseded** pre-plugin sharing kit. To
  share the second brain, point people at "Not a developer? Start here".
- [REBUILD.md](REBUILD.md) — standing everything back up on a fresh machine.
