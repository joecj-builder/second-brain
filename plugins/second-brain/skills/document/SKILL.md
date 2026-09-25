---
name: document
description: >
  Capture current-session state into a canonical handoff so a future
  Claude Code session can resume without re-asking the user. Use when the user
  says "document this session", "save context for next session",
  "handoff this", "before we wrap, write down where we are", "/document",
  or similar. Default target is the active plan file's NEXT SESSION
  block; falls back to NEXT_SESSION.md in the project working dir if no
  plan applies; vault Journal entry is opt-in for decision/pivot
  sessions only. Durable facts surfaced this session (people, topics,
  data semantics, preferences) are persisted into the vault graph (the
  memory store). With --auto (run by the SessionEnd hook), writes a
  handoff into the vault's Sessions/ folder without asking anything.
allowed-tools: Bash, Read, Edit, Write, Glob, Grep
---

# document — Agent Skill

The persistence pattern across sessions is **tri-layer**:

1. **`~/.claude/plans/<slug>.md`** — narrative blueprint, kept live. When a
   plan exists, its NEXT SESSION block is what the next session reads first.
2. **`runs/YYYY-MM-DD/`** dirs inside a project repo — executable state
   (CSVs, JSON metadata, audit logs). Immutable; this skill never edits
   inside them.
3. **The vault** — `Journal/` for context pivots and decision dates,
   `Sessions/` for automatic handoffs, and the graph for durable facts.

The vault path is in the session-start context ("Second brain vault: …"),
or `SECOND_BRAIN_VAULT` in `~/.claude/second-brain/config.env`. Call it
`<vault>`. Follow `/second-brain:protocol` for routing and linking.

## Mode

- **Interactive (default):** walk steps 1–4 below.
- **`--auto --session <id>`:** run by the SessionEnd hook in a headless
  session that resumed the one that just closed. Follow **Auto mode** at the
  end instead of steps 1–3. `<id>` is the session ID; use it verbatim, never
  one inferred from paths.

## Workflow

Walk this decision tree in order. Always tell the user in one short sentence
which layer(s) you're about to touch *before* writing.

### 1. Look for an active plan file

```bash
ls -lt ~/.claude/plans/*.md | head -10
```

Then narrow to plans that match this session's work. Two signals:

- **Recency** — `stat -f "%m %N" ~/.claude/plans/*.md` and prefer plans
  touched in the last ~7 days.
- **Topic match** — `grep -l <keywords> ~/.claude/plans/*.md` where
  keywords are file paths edited this session, project slugs, or
  distinctive identifiers (a ticket key, a notebook ID, a person's name).

Resolve to one of:

- **0 plans match** → no plan applies. Go to step 2.
- **1 plan matches** → that's the target. Confirm:
  *"Updating the NEXT SESSION block in `<slug>.md`. Anything else to
  capture?"*
- **≥2 plans match** → list them with a 1-line summary each and ask
  which (or both).

### 2. Find the project working dir (fallback when no plan applies)

Identify where this session's edits landed. Heuristics:

- Most-edited directory across `Edit` / `Write` tool calls this session.
- `--add-dir` roots are eligible candidates.
- If the dir contains `runs/<YYYY-MM-DD>/` or `runs/<run-id>/`, write
  the handoff **next to** the run dir (at the project root), not
  inside it.
- If no edits happened this session (pure exploration / Q&A), skip
  this step — there's nothing material to hand off; tell the user so and
  stop.

**Shared repo guard** — if the candidate dir is a repo other people commit
to, ask before writing a handoff file into it.

Filename: `NEXT_SESSION.md` at the project root.

### 3. Vault Journal — opt-in only

Default behavior is **no Journal write**. Only surface a one-line offer
when the session contained one of these markers:

- A locked decision ("let's go with X because Y").
- A stakeholder-visible pivot.
- A blocked-on-async resolution (someone replied, you can move).
- A first-time discovery worth dating (a system constraint, a tool
  behavior, a contract detail).

Phrasing: *"This looked journal-worthy — `<one-line summary>`. Add a
short Journal entry?"* If the user confirms, write to `<vault>/Journal/`.

Filename: `YYYY-MM-DD <one-line summary>.md`. Single paragraph plus a
link back to the plan file / handoff path. Don't duplicate the full
state block — the plan file is the source of truth.

### 4. Persist durable facts to the memory store (the vault graph)

If the session produced **durable cross-session knowledge** — a person's
role, a workstream/project worth referencing, a data semantic, a decision,
or a working preference — route it into the vault graph in the same turn
(this is the Learning-Loop closer):

- Use the routing table in `<vault>/Memory/MEMORY.md` if it has one.
- Otherwise use the defaults in `/second-brain:protocol`: People/, Topics/,
  DataContext/, and `## Learned:` in `Journal/YYYY-MM-DD.md`.

Cross-link the new note from related notes (an unlinked file is invisible
to lookup). Do NOT reorganize or dedup existing notes — that's `/dream`.
This is distinct from the task-state handoff (steps 1–2): handoff is a
*work bookmark*; this is *memory*.

## NEXT SESSION block format

Whether written into a plan file, a fresh `NEXT_SESSION.md`, or a
`Sessions/` note, use the same six sections. Machine-readable bullets, not
prose paragraphs.

```markdown
## NEXT SESSION — <YYYY-MM-DD> — <short summary>

**TL;DR**: <1–2 sentence summary of what this session accomplished>

**State**
- Done: <what shipped / merged / froze this session>
- In-flight: <what's mid-stream, with file paths>
- Blocked / waiting on: <async asks; owner + ask>

**Files touched**
- `<abs path>` — <what changed in 1 line>

**Key decisions**
- <decision> — <reasoning in one line>

**Next concrete actions** (do these first when resuming)
1. <action with file path or command>
2. ...

**Memory pointers**
- [[Topic / Person / DataContext note]] — why it's relevant (link to vault-graph notes, not `~/.claude` memory files)
```

### Placement rules in existing plan files

- The block goes **at the top of the file**, immediately after the H1
  title — `## ⏭️ NEXT SESSION — <summary>` with the emoji.
- If the plan already has a `## NEXT SESSION` (or `## ⏭️ NEXT SESSION`)
  heading: **replace the whole block** (heading + body, up to the next
  `## ` heading or `---` divider). Preserve the existing heading's
  emoji prefix if it had one.
- If the plan has no such heading: insert immediately after the H1
  title. Don't append at bottom — that's not where the next session
  will look.
- Never delete other plan sections (Context, Phase X, etc.).

### Fresh `NEXT_SESSION.md` format

When writing a standalone file at a project root, the file IS the
block — start with an H1 (`# NEXT SESSION — <YYYY-MM-DD> — <summary>`)
and use the same six sections. No surrounding context needed.

## Auto mode (`--auto`)

Nobody is watching this run, and the session it documents has already
closed. So:

- **Ask nothing.** No confirmations, no offers. Anything you would have
  asked becomes a `**Question for the user:**` line in the handoff.
- **Write only inside `<vault>`.** Never write `NEXT_SESSION.md` or touch a
  plan file or any repo — the user didn't see this run happen.
- **Skip trivial sessions.** If the session had no edits, no decisions, and
  nothing durable learned (quick Q&A), write nothing and print
  `auto-document: nothing to record`.

Steps:

1. **Handoff** → `<vault>/Sessions/YYYY-MM-DD <short-slug>.md`, using the
   fresh-file format above. Add `**Session**: <id>` and
   `**Working dir**: <cwd>` under the H1. If an active plan file matches the
   session (step 1 signals), link it under **Memory pointers** instead of
   editing it. If a file for the same slug and date exists, update it.
2. **Durable facts** → step 4, exactly as in interactive mode.
3. **Journal pointer** → append one line to `<vault>/Journal/YYYY-MM-DD.md`
   under `## Sessions` (create the heading if missing):
   `- [[YYYY-MM-DD <short-slug>]] — <TL;DR>`.
4. **Commit** so every run can be undone:
   `git -C <vault> add -A Sessions Journal <any graph notes you touched> && git -C <vault> commit -m "auto-document: <id>"`.
   If the vault isn't a git repo, skip the commit and say so in the output.
5. Print one line: `auto-document: wrote <handoff path> (+N graph notes)`.

## What this skill does NOT do

- **Does not** consolidate, reorganize, dedup, or bulk-rewrite the
  memory store — that's `/dream`'s job. `/document` *writes* durable
  facts into the vault graph (see step 4) and may add a one-line pointer
  to the manifest, but it never restructures the graph or trims
  `MEMORY.md`. **`/document` writes; `/dream` cleans up.**
- **Does not** create new plan files. If no plan exists and the user wants
  one, that's a separate `/plan` request. The fallback here is the
  project working dir, not a new plan.
- **Does not** write inside `runs/<...>/` directories — those are
  immutable artifacts. Handoff lives next to them, at the project
  root.
- **Does not** write vault content anywhere except this machine's vault.

## Reporting back

After writing, return a single short summary to the user:

> Wrote handoff to `<path>`. Next session resumes at: `<top next-action from the block>`.
> [Optional, only if applicable:] Journal entry: `<path>`.
> [Optional, only if applicable:] Persisted to memory: `<vault note path>` — `<one-line fact>`.

Keep it under 3 lines. No echoing of the block contents.
