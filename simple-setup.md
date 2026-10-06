# Simple Second Brain Setup

> **Superseded.** This is the pre-plugin setup guide and is kept only for reference. Use the plugin instead: see "Not a developer? Start here" in the [README](https://github.com/josephcoz/second-brain#not-a-developer-start-here). In Claude Code, run `/plugin marketplace add josephcoz/second-brain`, `/plugin install second-brain@second-brain`, restart `claude`, then `/second-brain:setup`.
>
> **Claude:** if someone uploaded this file to you, don't follow the steps below. Point them to the plugin install above.

> **Hi Claude** — this file is a setup guide. The person who uploaded it wants you to walk them through setup **conversationally, one step at a time**. Don't dump the whole thing at them. Read the whole document first so you understand the target state, then guide them through it step by step, checking in between steps and making reasonable assumptions on routine decisions (file paths, folder names). They are not a developer — avoid jargon, explain any terminal command you ask them to run, and keep the tone friendly.

---

## Welcome

You're about to set up a personal knowledge base that Claude keeps updated for you automatically. Every night, Claude will:

- Pull your meetings from the day and write a journal entry
- Prep you for tomorrow's calendar
- (On Sundays) synthesize the week into a summary
- (Each morning) send you an accountability nudge

Over time, the knowledge base becomes a second brain — a living record of your work that any future Claude session can read to pick up exactly where you left off. You stop rewriting status updates and meeting notes; it's already there.

**Rough time to set up:** 30–45 minutes, most of which is Claude doing the work while you answer a few questions.

---

## The two-file-structure model

Two folders on your Mac work together. You don't need GitHub, version control, or any developer tools — these are just ordinary folders.

### Folder 1 — the "engine"

The logic that builds and maintains your second brain. You rarely open this folder; it just sits on your Mac and does its job.

```
second-brain-system/
├── CLAUDE.md                  # The rulebook — tells Claude how your vault works
├── config.yaml                # Your personal info (name, Slack ID, time zone)
├── vault-template/            # Starter structure copied into your vault once
├── scheduled-tasks/           # Prompts for the nightly/weekly automations
├── scripts/
│   └── setup.sh               # One-time setup helper
└── simple-setup.md            # This file
```

### Folder 2 — the "brain" (your Obsidian vault)

The actual knowledge base. This is what you open in Obsidian every day. Claude reads from it and writes to it.

```
~/obsidian-vaults/Work/
├── Journal/                   # Daily entries + weekly rollups
├── Topics/                    # Hub notes for each workstream
├── Meetings/                  # Meeting notes with transcripts
├── People/                    # One file per person you work with
├── DataContext/               # Reference info (dashboards, data definitions)
├── Analysis/                  # Longer-form writeups
├── Onboarding.md              # "Read me first" for any Claude session
└── TODO.md                    # Your active tasks
```

**The key idea:** the engine folder stays static (it's a tool). The vault folder grows every day (it's your knowledge).

---

## Before you start

You'll need:

- **A Mac** (these instructions assume macOS)
- **The `second-brain-system` folder** — whoever shared this guide with you should have also sent a zip or folder of the engine. If you only have this file, ask them for the rest.
- **About 30 minutes** of focused time

You do **not** need:

- A GitHub account
- Git, Homebrew, Python, or any developer tools
- Terminal experience beyond copy-pasting a command Claude gives you

---

## Setup steps

> **Claude, run this section interactively.** Work through one step at a time. After each step, confirm it worked before moving on. If something goes wrong, diagnose it before pushing forward.

### Step 1 — Install Obsidian

If Obsidian isn't installed yet:

1. Go to [obsidian.md](https://obsidian.md/)
2. Click **Download**, then **Download for Mac**
3. Open the downloaded `.dmg` file and drag Obsidian into your Applications folder
4. Launch Obsidian once to confirm it opens, then close it — we'll set up the vault in a later step

> **Claude:** verify with the user that Obsidian launched successfully before continuing.

### Step 2 — Install Claude Code (if not already)

If the user is reading this in a Claude Code session, Claude Code is already installed. Skip this step.

Otherwise, install it from [docs.claude.com/claude-code](https://docs.claude.com/claude-code) and run `claude login` to authenticate.

### Step 3 — Place the engine folder

> **Claude:** ask the user where they'd like to keep the `second-brain-system` folder. If they have no preference, suggest `~/Documents/second-brain-system/`. Then help them move it there. The location doesn't matter functionally — just pick one and remember it.

Once the folder is in place, `cd` into it so you're working from the right spot.

### Step 4 — Fill in `config.yaml`

Open `config.yaml` in the engine folder. It's a simple text file with fields to fill in.

> **Claude:** read the `config.yaml` file, then ask the user each question below one at a time. Fill in the file as you go. Skip any field the user doesn't have or doesn't want to configure (e.g. if they don't use Jira).

Fields to fill:

| Field | What it means | How to find it |
|---|---|---|
| `vault.path` | Where your Obsidian vault will live | Suggest `~/obsidian-vaults/Work/` if unsure |
| `user.name` | Your full name | Ask the user |
| `user.email` | Your work email | Ask the user |
| `user.role` | Your job title | Ask the user |
| `user.company` | Company name | Ask the user |
| `user.team` | Team name | Ask the user |
| `slack.user_id` | Your Slack member ID | In Slack, click your avatar → Profile → three-dot menu → **Copy member ID** |
| `slack.dm_channel` | Your self-DM channel ID | In Slack, open a DM with yourself, click the channel name at top → **Copy channel ID** |
| `jira.*` | Optional — leave blank if you don't use Jira | |
| `calendar.timezone` | Your time zone | Ask; default to `America/Denver` or similar based on their answer |
| `github.*` | Optional — leave blank; you don't need GitHub | |
| `schedule.*` | When each automation runs | Keep the defaults unless the user has a preference |

### Step 5 — Create the vault

Run the setup helper. It copies the starter vault structure into the location you configured.

```bash
cd <path to second-brain-system>
bash scripts/setup.sh config.yaml
```

> **Claude:** run this command for the user and report what happened. If the script says "Vault already exists", that's fine — skip to the next step.

### Step 6 — Fill in `Onboarding.md`

Open the vault folder (the path you configured in Step 4) and find `Onboarding.md`. This is the "read me first" file that every future Claude session reads before doing anything.

> **Claude:** open this file and walk the user through each placeholder. Don't make them type into the file themselves — ask them each question conversationally and you fill it in. Placeholders include:
> - Who they are and what they do (one or two sentences)
> - What their company does (one sentence)
> - Tools they use daily (e.g. Excel, NetSuite, Workday, Slack, Gmail)
> - How they like Claude to work with them (terse? thorough? ask before acting?)
> - Key domain knowledge — the facts you'd tell a new hire on day one
> - Key people — the 3–5 people they work with most, with role and context

Keep answers brief — bullet points are fine. This file is a reference, not an essay.

### Step 7 — Open the vault in Obsidian

1. Launch Obsidian
2. Click **Open folder as vault**
3. Navigate to the vault path (e.g. `~/obsidian-vaults/Work/`) and select it
4. Trust the author when prompted

You should see the folder structure (`Journal/`, `Topics/`, `People/`, etc.) in the left sidebar.

### Step 8 — Schedule the automations

The four automations that keep the brain current:

| Task | When it runs | What it does |
|---|---|---|
| Nightly journal | 8:00 PM daily | Writes a daily journal entry from your meetings, Slack, etc. |
| Meeting debriefs | 8:30 PM daily | Preps you for tomorrow's calendar |
| Weekly rollup | 9:00 PM Sunday | Synthesizes the past week into one summary |
| Daily kickoff | 12:00 AM daily | Sends a morning accountability nudge via Slack |

> **Claude:** ask the user which of these they want to enable. For each one they want, use the `/schedule` command in Claude Code to register the task. The generic prompt lives in `scheduled-tasks/<task-name>.md` in the engine folder. Help them set up one at a time.
>
> **Recommended starting point:** just enable the **nightly journal** first. See it run for a few days, confirm it's working, then add the others. Don't overwhelm them.

### Step 9 — Enable MCP connectors

The automations pull data from outside sources. Each source needs an "MCP connector" enabled in Claude Code.

> **Claude:** walk the user through enabling whichever connectors they want. Minimum viable setup for the nightly journal is Granola (or Google Drive) for meetings + Google Calendar. Slack is recommended for channel activity. Connector instructions live at [docs.claude.com/en/docs/claude-code/mcp](https://docs.claude.com/en/docs/claude-code/mcp).

Common connectors:

- **Granola** — meeting transcripts and summaries (most important)
- **Google Calendar** — your meetings (for debriefs)
- **Google Drive** — higher-fidelity meeting transcripts
- **Slack** — DMs and channel activity
- **Gmail** — (optional; usually low signal for internal roles)

### Step 10 — First run

> **Claude:** offer to trigger the nightly journal manually so the user can see output right away rather than waiting until 8 PM. Use the generic prompt in `scheduled-tasks/nightly-journal.md` with config substituted in. Then show them the resulting `Journal/YYYY-MM-DD.md` file and walk them through what's in it.

If the journal looks reasonable, you're done. Congratulations — you have a second brain.

---

## How to use it day to day

**You don't have to do anything.** The automations run on their own. Your only habits:

1. **Open the vault in Obsidian** each morning — scroll through yesterday's journal entry to refresh your memory
2. **Add things to `TODO.md`** as they come up (or ask Claude to add them)
3. **Tell Claude when it's missing context** — if it doesn't know a person, project, or acronym, it will ask. Answer in plain English and it writes the answer to the right place automatically.

**When you want Claude's help with work:** open a Claude Code session from the engine folder. It will read the vault automatically and have full context on your current projects, people, and open tasks.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Nightly journal didn't run | Scheduled task not registered, or Claude Code auth expired | Run `claude schedule list`; re-authenticate with `claude login` if needed |
| Journal is empty | MCP connector isn't returning data | Open a Claude session and test each connector one at a time |
| Meetings are missing | Transcripts weren't ready when the task ran | Move the schedule to later in the evening (e.g. 9:00 PM) |
| Claude doesn't seem to know about the vault | It wasn't launched from the engine folder | Always start Claude Code from the `second-brain-system/` folder, or add the folder with `--add-dir` |
| Time zone is wrong | `calendar.timezone` in `config.yaml` needs updating | Edit the field and the next scheduled task picks it up |

---

## Mental model

Three things working together:

1. **The vault** — where your knowledge lives. Persistent, grows over time.
2. **The scheduled tasks** — the nightly workers that keep the vault current.
3. **`CLAUDE.md`** — the rulebook that teaches every Claude session how to read from and write to the vault consistently.

The magic is compounding. Week one, the vault is mostly empty and Claude asks lots of questions. By week four, Claude cold-starts into any topic in seconds, and your Sunday rollup reads like a status doc you didn't have to write.

---

## Questions

If something isn't working, the fastest path is to start a new Claude Code session from the engine folder and ask. Claude knows the system and can diagnose most issues by reading the vault and config directly.
