# Claude Onboarding — Read This First

> **Purpose:** If you're a new Claude instance, read this before doing anything else.

## Who You're Working With

- **Name:** {{user_name}}
- **Role:** {{user_role}} at {{company}}
- **What {{company}} does:** [Fill in: one sentence about the company]
- **Your function:** [Fill in: what you do, how you fit in the org]

## Your Tools

[Fill in: List the tools you use daily. Examples:]
- **Primary analysis tool** — [e.g., Hex, Jupyter, Looker]
- **Meeting transcription** — [e.g., Granola, Otter.ai]
- **Knowledge base** — This Obsidian vault
- **Communication** — [e.g., Slack]
- **CRM** — [e.g., Salesforce]
- **Data warehouse** — [e.g., Snowflake, BigQuery]

## How to Work with Me

[Fill in: Your preferences for Claude interaction. Examples:]
- Be concise and action-oriented
- Check the vault before asking questions
- Work content only in this vault
- Journal is ground truth, TODO.md is aspirational

## This Vault — What's Where

```
Work/
├── Journal/           Daily work logs — START HERE
├── TODO.md            Active tasks (may be stale — cross-ref with journal)
├── Topics/            Topic hub nodes (Map of Content files)
├── Analysis/          Polished analytical writeups
├── Meetings/          Meeting exports with transcripts
│   └── _Companies/    Company-level context
├── People/            Person index
└── DataContext/        Domain reference docs
```

**Cold-start reading order:**
1. This file
2. Most recent weekly rollup in Journal/
3. Daily journal entries newer than the rollup
4. TODO.md
5. Key DataContext/ files for your domain

## Key Domain Knowledge

[Fill in: Quick-reference domain facts that Claude needs frequently]

## Key People

[Fill in: People you interact with most. Format:]
- **Name** — Role. Context notes.

## Automated Pipelines

Three scheduled tasks maintain this vault:
1. **Nightly journal** (8pm) — exports meetings, writes daily log
2. **Meeting debriefs** (8:30pm) — preps tomorrow's calendar
3. **Weekly rollup** (Sunday 9pm) — synthesizes the week
