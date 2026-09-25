# Setting Up Your Own Second Brain

A step-by-step guide for a new user standing up their own Claude-powered Obsidian knowledge base using this framework.

---

## What you get

A persistent, always-current work knowledge base that:

- **Captures your day automatically** — scheduled Claude Code agents pull from your calendar, meeting transcripts (Granola / Google Drive), Slack, and Jira each night and write a structured journal entry
- **Synthesizes the week for you** — a Sunday-night rollup turns seven daily entries into one onboarding-quality summary
- **Preps tomorrow** — an evening debrief agent researches your next day's meetings and drops prep briefings
- **Remembers across sessions** — every future Claude Code session starts warm because the vault, not the conversation, is the persistent context

You end up with an Obsidian vault that any Claude Code session can navigate reliably, and you get back the time you used to spend writing status updates, meeting notes, and weekly summaries.

---

## Architecture at a glance

Two repos plus a vault:

```
second-brain/              # Shared framework (this repo) — clone-and-use
  plugins/                 # Claude Code plugins: protocol, /document, /dream, vault template
  scheduled-tasks/         # Generic prompts for each nightly/weekly agent
  scripts/                 # Setup helpers
  docs/                    # Deeper guides
  CLAUDE.md                # How Claude navigates the vault

<your-automation-repo>/    # Your private repo — you create this
  config.yaml              # Filled-in copy of config.example.yaml
  scripts/tasks/           # Prompt wrappers that run each scheduled task
  task-overrides/          # Optional per-task extensions (e.g. Jira sync)
  CLAUDE.md                # Points Claude at the shared second-brain framework

~/obsidian-vaults/Work/    # The vault itself — runtime data, unversioned
```

The shared repo is generic; the private repo is where your Slack ID, Jira keys, company-specific prompt tweaks, and credentials live. The vault is the runtime data store and stays out of git.

---

## Prerequisites

Before you start:

- **macOS** (the scripts and LaunchAgents assume macOS; Linux works with minor adjustments)
- **[Obsidian](https://obsidian.md/)** installed
- **[Claude Code CLI](https://docs.claude.com/claude-code)** installed and authenticated
- **MCP connectors** enabled in Claude Code for at least the sources you want to capture:
  - [Slack](https://docs.claude.com/en/docs/claude-code/mcp) — DMs, channel activity
  - Google Calendar — meeting debriefs
  - [Granola](https://www.granola.ai/) — meeting summaries and transcripts
  - Google Drive — Google Meet transcript documents
  - Atlassian / Jira — ticket activity (optional)
  - Gmail — (optional; low-signal for most internal roles)
- A **GitHub account** you can use for your private automation repo
- Basic comfort with the terminal and editing YAML / Markdown

---

## Setup

### 1. Clone the framework

```bash
mkdir -p ~/github-projects
cd ~/github-projects
git clone <second-brain-repo-url> second-brain
```

### 2. Create your private automation repo

This repo holds your config, credentials, and any personal prompt overrides. Nothing in it should be shared.

```bash
cd ~/github-projects
mkdir <your-automation-repo>   # e.g. "work-automation"
cd <your-automation-repo>
git init
```

Copy the config template in:

```bash
cp ~/github-projects/second-brain/config.example.yaml ./config.yaml
```

Edit `config.yaml` and fill in:

- `vault.path` — absolute path to your Obsidian vault (e.g. `~/obsidian-vaults/Work/`)
- `user.*` — your name, email, role, company, team
- `slack.user_id` and `slack.dm_channel` — pull these from Slack's "Copy member ID" / your self-DM's channel ID
- `jira.*` — your account ID, cloud ID, project key (leave blank if you don't want Jira integration)
- `calendar.timezone` — your IANA timezone string (e.g. `America/Denver`)
- `github.*` — the account and SSH alias you'll use
- `schedule.*` — cron strings for each scheduled task (defaults are sensible)

Create a minimal `CLAUDE.md` in this repo that points at the shared framework:

```markdown
# <Your Name>'s work automation

This repo hosts my personal config and overrides for the shared
[second-brain](../second-brain/) framework.

See `second-brain/CLAUDE.md` for vault conventions, 3-tier lookup, and writing rules.

- Config: `config.yaml`
- Task prompts: `scripts/tasks/` (wrap the generic prompts in `second-brain/scheduled-tasks/`)
- Overrides: `task-overrides/`
```

### 3. Initialize your vault

From the `second-brain/` repo:

```bash
cd ~/github-projects/second-brain
./scripts/setup.sh ~/github-projects/<your-automation-repo>/config.yaml
```

This copies `plugins/second-brain/vault-template/` to the `vault.path` you configured. (Installing the `second-brain` plugin and running `/second-brain:setup` does the same, and more — see README.) Open the vault in Obsidian and fill in `Onboarding.md` — that file is the cold-start document every future Claude session reads first.

Fill in these placeholders specifically:

- Who you are and what you do
- The tools you use daily
- How you prefer Claude to work with you
- Key domain knowledge Claude needs frequently
- Key people you interact with most

### 4. Create prompt wrappers in your private repo

For each scheduled task you want to run, create a thin prompt wrapper under `<your-automation-repo>/scripts/tasks/` that:

1. Reads `config.yaml`
2. Substitutes `{{variables}}` into the generic prompt from `second-brain/scheduled-tasks/<task>.md`
3. Appends any override files from `task-overrides/`
4. Pipes the result into `claude -p`

You can start with just one task (nightly journal is the most valuable) and add the others incrementally.

### 5. Schedule the tasks

The simplest path is Claude Code's `/schedule` command to run each task as a remote agent. Use the cron expressions you set in `config.yaml`:

- **Nightly journal** — 8:00 PM daily
- **Meeting debriefs** — 8:30 PM daily
- **Weekly rollup** — 9:00 PM Sunday
- **Daily kickoff** — 12:00 AM daily

Alternative: local `crontab` or `launchd`. See `scheduled-tasks/crontab.example` for the cron lines.

Verify with `claude schedule list`.

### 6. Let it run one cycle

Wait for the first nightly journal to fire (or run the prompt wrapper manually with `claude -p < scripts/tasks/nightly-journal.prompt.md`). Check `Journal/YYYY-MM-DD.md` in your vault the next morning.

If the journal looks reasonable, you're done. If not, the most common fixes are:
- **Empty journal** → MCP connectors aren't returning data. Check each MCP source independently via Claude Code.
- **Wrong timezone** → fix `calendar.timezone` in `config.yaml`.
- **Missing people/topics** → normal for the first few weeks. The vault bootstraps itself as Claude encounters new names and workstreams.

---

## How Claude uses the vault

The shared `CLAUDE.md` teaches every Claude Code session three things:

**3-tier lookup.** When Claude needs context on a topic, it checks:
1. `Topics/<name>.md` — a lightweight hub note
2. `grep` for `[[wiki links]]` across the vault
3. Cold-start: `Onboarding.md` → latest weekly rollup → recent daily journals → `TODO.md`

**Writing rules.** New notes follow consistent filename patterns (`YYYY-MM-DD.md` for journals, `Full Name.md` for people, etc.) and cross-link with `[[wiki links]]` so the graph stays navigable.

**Learning loop.** When Claude encounters a person, project, or data source the vault doesn't know about, it asks a targeted question, gets the answer, and writes it to the right file (People, Topics, DataContext, or a journal append) in the same turn. Nothing learned in a session is allowed to evaporate.

Read `second-brain/CLAUDE.md` in full once — it's the contract Claude operates under, and knowing what to expect makes the system feel less magical and more predictable.

---

## Customization

Once the baseline is working, common extensions:

- **Add a new data source** — e.g. Linear, GitHub PRs, a custom app. See `docs/customization.md`. The pattern is: add data gathering to your prompt wrapper, create a task override, no changes to the shared repo needed.
- **Domain-specific skills** — if your role has a repeated workflow (e.g. "build a Hex dashboard", "query Snowflake via saved helper"), add it as a [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills) in your private repo under `skills/`.
- **Tweak task prompts** — don't edit the shared `scheduled-tasks/<task>.md` files. Instead, put the tweak in `<your-automation-repo>/task-overrides/<task>-<feature>.md` and reference it from your prompt wrapper. This keeps you able to pull framework updates without merge conflicts.

See also:
- `docs/architecture.md` — the three-layer model and how scheduled tasks fit together
- `docs/customization.md` — detailed customization patterns
- `docs/transcript-sources.md` — how meeting transcripts flow through the system

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Nightly journal never fires | Scheduled task not registered, or Claude Code auth expired | `claude schedule list`; re-auth with `claude login` |
| Journal is empty | MCP connector returning no data | Test each MCP source in an interactive Claude Code session |
| Meetings missing from journal | Granola / Drive transcript not yet available at run time | Push the schedule 30+ minutes later, or wait for Drive to finish processing |
| Claude ignores vault conventions | `second-brain` plugin not installed or not set up | `/plugin install second-brain@second-brain`, then `/second-brain:setup` |
| Files landing in wrong vault | Config points at a different vault | Check `SECOND_BRAIN_VAULT` in `~/.claude/second-brain/config.env` and `config.yaml` `vault.path` |

---

## Mental model

Think of it as three layers working together:

1. **Obsidian vault** — the persistent data layer. Lives on disk, survives every session.
2. **Scheduled Claude tasks** — the agents that keep the vault current without your involvement.
3. **`CLAUDE.md`** — the rulebook that tells every Claude session how to read from and write to the vault consistently.

The value compounds. Week one, the vault is mostly empty and Claude asks a lot of questions. By week four, Claude cold-starts into any topic in seconds, and your weekly rollup reads like a status doc you didn't have to write.

---

## Questions

If something in the setup isn't working or a concept in `CLAUDE.md` is unclear, the fastest path is:
1. Check the `docs/` guides
2. Look at a recent journal entry or rollup for a working example of the conventions
3. Ask in a new Claude Code session with `second-brain/` on the path — Claude knows the framework
