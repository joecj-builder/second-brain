# Vault Contract

This document defines the structure, conventions, and rules for all writers (human and automated) of this Obsidian vault.

## Vault Location

```
{{vault_path}}
```

## Folder Structure

```
{{vault_path}}/
├── Onboarding.md          # Read-first file for new Claude instances
├── TODO.md                # Active task tracker
├── Journal/               # Daily work logs and weekly rollups
├── Topics/                # Map of Content (MoC) hub nodes
├── Analysis/              # Polished analytical writeups
├── Meetings/              # Meeting exports with transcripts
│   └── _Companies/        # Company-level context files
├── People/                # Person index (one file per person)
├── DataContext/            # Domain reference docs (including this file)
└── Scripts/               # Automation scripts (excluded from Obsidian)
```

## File Naming Conventions

| Folder | Pattern | Example |
|--------|---------|---------|
| Journal (daily) | `YYYY-MM-DD.md` | `2026-04-05.md` |
| Journal (weekly) | `Week-of-YYYY-MM-DD.md` | `Week-of-2026-03-30.md` |
| Meetings | `YYYY-MM-DD Meeting-Title.md` | `2026-04-05 Pipeline Review.md` |
| Meetings/_Companies | `Company-Name.md` | `Acme-Corp.md` |
| People | `Firstname-Lastname.md` | `Jane-Smith.md` |
| Topics | `Topic-Name.md` | `Churn-Analysis.md` |
| Analysis | `Descriptive-Title.md` | `Q1-Revenue-Deep-Dive.md` |
| DataContext | `descriptive-name.md` | `vault-contract.md` |

## Wiki Link Conventions

### Link Targets by Type

| Content Type | Link Target | Example |
|-------------|-------------|---------|
| Person | `People/Firstname-Lastname` | `[[People/Jane-Smith]]` |
| Company | `Meetings/_Companies/Company-Name` | `[[Meetings/_Companies/Acme-Corp]]` |
| Topic | `Topics/Topic-Name` | `[[Topics/Churn-Analysis]]` |
| Meeting | `Meetings/YYYY-MM-DD Title` | `[[Meetings/2026-04-05 Pipeline Review]]` |
| Analysis | `Analysis/Title` | `[[Analysis/Q1-Revenue-Deep-Dive]]` |
| Journal | `Journal/YYYY-MM-DD` | `[[Journal/2026-04-05]]` |

### When to Create Links

- **Always link** people, companies, and topics on first mention in any document
- **Link meetings** when referencing a specific conversation
- **Link journal entries** when cross-referencing across days
- **Do not over-link** — if a term appears 10 times, link it once (first mention)

## Automated Task Outputs

### 1. Nightly Journal (runs at 8pm daily)

**Produces:** `Journal/YYYY-MM-DD.md`

Contents:
- Meeting summaries exported from the transcription tool
- Key decisions and action items extracted from meetings
- Links to full meeting files in `Meetings/`
- End-of-day context snapshot

### 2. Meeting Debriefs (runs at 8:30pm daily)

**Produces:** Updated notes in relevant `Meetings/_Companies/` files

Contents:
- Tomorrow's calendar review
- Prep notes for upcoming meetings
- Company context refreshed from recent interactions

### 3. Weekly Rollup (runs Sunday at 9pm)

**Produces:** `Journal/Week-of-YYYY-MM-DD.md`

Contents:
- Week synthesis across all daily journals
- Key themes and patterns
- Progress against TODO.md items
- Upcoming priorities for next week

## Rules for All Vault Writers

### Rule 1: Stay in the Vault
All work content lives in this vault. Do not create files outside the vault structure. Do not store work artifacts in other locations.

### Rule 2: Follow Naming Conventions
Use the file naming patterns defined above. Consistency enables automation and linking.

### Rule 3: Link Generously but Not Redundantly
Create wiki links to people, companies, and topics on first mention. Do not link the same target multiple times in one section.

### Rule 4: Journal Is Ground Truth
The daily journal is the authoritative record of what happened. TODO.md is aspirational and may be stale. When in conflict, journal wins.

### Rule 5: Append, Don't Overwrite
When updating existing files (especially company files and people files), append new information with a date header. Do not delete or overwrite previous content unless it is factually wrong.

### Rule 6: Keep Meeting Transcripts Intact
Meeting files in `Meetings/` should preserve the original transcript. Add analysis and summaries above or below the transcript, clearly separated. Never edit the transcript itself.
