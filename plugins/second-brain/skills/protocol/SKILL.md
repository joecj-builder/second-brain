---
name: protocol
description: >
  How to read from and write to the second-brain vault (an Obsidian vault that
  is Claude's persistent memory store): the 3-tier lookup, vault structure,
  naming and wiki-link conventions, writing rules, and the Learning Loop. Load
  before any vault lookup or vault write, when the user mentions a person,
  project, or prior work you have no context on, or when they say "check the
  vault", "look that up", or "remember this".
---

# Second brain protocol

This machine has one second brain: an Obsidian vault that is your persistent
memory store. Its path is in the session-start context ("Second brain vault:
…"). If that line is missing, read `SECOND_BRAIN_VAULT` from
`~/.claude/second-brain/config.env`; if neither exists, tell the user to run
`/second-brain:setup`.

`<vault>` below means that path.

## The vault is the memory store

- **Auto-memory writes here.** `/second-brain:setup` points Claude Code's
  `autoMemoryDirectory` at `<vault>/Memory`.
- **`<vault>/Memory/MEMORY.md` is the auto-loaded manifest**: identity, a
  routing table, and pointers into the graph. Keep it thin; detail lives in
  the graph notes. **If `MEMORY.md` has its own routing table, it overrides
  the defaults on this page.**
- **The vault is git-backed.** Every write is a recoverable version.
- **`/second-brain:document` writes; `/second-brain:dream` cleans up.**
  `/document` flushes task state and durable facts at the end of a session
  (and runs automatically when a session ends). `/dream` consolidates the
  vault on a review branch.

## 3-tier lookup

Follow in order. Stop as soon as you have enough.

1. **Topic node.** Check `<vault>/Topics/` for a hub note on the subject.
   Topic nodes are short: description, key people, pointers to Analysis and
   DataContext notes, status.
2. **Backlink grep.** `grep -rl '[[Search Term]]' <vault>` surfaces every
   note that links the term.
3. **Cold start.** With no context at all, read `<vault>/Onboarding.md`, the
   latest `Journal/YYYY-Wxx-rollup.md`, recent `Journal/` days, then
   `<vault>/TODO.md`.

## Vault structure

```
<vault>/
  Memory/        # MEMORY.md manifest + auto-memory inbox
  Topics/        # hub notes, one per workstream or area
  People/        # one file per person
  Projects/      # projects and builds
  DataContext/   # reference data, schemas, systems, working preferences
  Analysis/      # detailed write-ups
  Meetings/      # meeting notes
  Journal/       # daily entries and weekly rollups (episodic record)
  Sessions/      # session handoffs written by /document --auto
  Onboarding.md  # orientation for a new Claude instance
  TODO.md        # current priorities
```

A vault may add its own folders (e.g. `Preferences/`, `Health/`). Follow
`MEMORY.md` when it says where something goes.

## Naming

| Type | Pattern | Example |
|---|---|---|
| Journal day | `YYYY-MM-DD.md` | `2026-03-17.md` |
| Weekly rollup | `YYYY-WXX-rollup.md` | `2026-W12-rollup.md` |
| Meeting | `YYYY-MM-DD Meeting Title.md` | `2026-03-17 Pipeline Review.md` |
| Analysis | `YYYY-MM-DD Analysis Title.md` | `2026-03-17 Churn Deep Dive.md` |
| Session handoff | `YYYY-MM-DD short-slug.md` | `2026-03-17 plugin-split.md` |
| Person | `Full Name.md` | `Jane Smith.md` |
| Topic | `Topic Name.md` | `Revenue Forecasting.md` |
| DataContext | `kebab-case-name.md` | `monthly-arr-snapshot.md` |

## Wiki links

Always reference vault entities with `[[wiki links]]`; Obsidian resolves them
by filename: `[[Full Name]]`, `[[Topic Name]]`, `[[YYYY-MM-DD Meeting Title]]`,
`[[kebab-case-name]]`.

## Writing rules

1. **Vault content goes only to this machine's vault.** Code and tools can come
   from anywhere; outputs land here.
2. **Use wiki links** for every person, topic, meeting, or data source.
3. **Only link to existing targets**, unless you're about to create the file.
4. **Be concrete.** IDs, file names, full names, figures, dates.
5. **Don't duplicate reference data.** Link to the DataContext note instead.
6. **Journal is ground truth** for what happened. **TODO is aspirational.**
7. **Topic nodes are hubs, not documents.** ~1–2 KB of pointers and status;
   depth goes in `Analysis/`.

## Learning Loop

You maintain the vault, not just read it. If you don't write it down,
future-you won't have it.

**Engage when:** the lookup finds nothing on a person/topic you need; two
notes contradict and timestamps don't settle it; the user mentions something
with no coverage; or you're about to assume something you can't verify.

**Ask** one targeted question at a time, showing what you already know. In
headless or scheduled runs, don't block: surface the question in the output
(a `**Question for the user:**` line).

**Route the answer:**

| Kind of knowledge | Destination |
|---|---|
| Person: name, role, team, relationships | `People/Full Name.md` |
| Workstream / project others will reference | `Topics/Topic Name.md` (or `Projects/`) |
| Data semantics, schemas, systems | `DataContext/kebab-name.md` |
| How the user likes to work | `DataContext/working-with-user/<theme>.md` |
| One-off decision or finding | `## Learned: <topic>` in `Journal/YYYY-MM-DD.md` |
| Deep write-up | `Analysis/YYYY-MM-DD Title.md` |
| Foundational fact every session needs | `Onboarding.md` (sparingly) |

When in doubt: Topic node + Journal append.

**Cross-link every new file.** A new Person goes in the relevant Topic's Key
People; a new Topic links its Analysis/DataContext notes both ways; a new
Analysis is linked from its Topic and today's Journal. Unlinked notes are
invisible to Tier 2.

**Confirm the write** in the same turn: "**Learned:** created
`People/Jane Smith.md`, linked from `Topics/Pricing.md`." That gives the user
a chance to correct routing.

**No loose context.** If you ask a question and use the answer, persist it
before moving on. Same for context the user volunteers. The only exception is
"this is one-off, don't save it".

**Don't:** fabricate (write `Status unknown — needs investigation.`),
duplicate across notes, bloat Topic nodes, skip cross-linking, or ask
without persisting.
