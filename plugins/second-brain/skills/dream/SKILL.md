---
name: dream
description: >
  Consolidate (defragment) the second-brain memory store. Like a disk
  defragmenter for the Obsidian vault: merges duplicates, archives stale
  notes, resolves contradictions, surfaces insights from the week's
  sessions, regenerates the Topic-Index, and trims MEMORY.md back under
  its size limit. Runs NON-DESTRUCTIVELY on a git branch you review, then
  adopt or discard. Use when the user says "/dream", "defrag the vault",
  "consolidate memory", "clean up the second brain", or on the weekly
  schedule. Modes: default (full weekly consolidation), --quick (fast
  MEMORY.md trim + obvious merges), --notify (Slack DM the report; the
  weekly scheduled run only).
allowed-tools: Bash, Read, Edit, Write, Glob, Grep
---

# dream — Agent Skill

A **dream** reads the memory store (the Obsidian vault) alongside the recent
session transcripts, and produces a *reorganized* version of the store:
duplicates merged, stale entries archived, contradictions replaced with the
latest value, new insights folded in, `MEMORY.md` trimmed. This mirrors
Anthropic's managed-agents "dreams": **the live vault is never modified in
place** — the dream works on a git branch you review, then merge (adopt) or
delete (discard).

Mental model: a **defragmenter**. It clears out old/duplicate cruft so the
store stays fast for Claude to consume.

---

## Step 0 — Resolve context, mode, and guards

1. **Vault + config.** The vault is in the session-start context ("Second brain
   vault: …"). Read `~/.claude/second-brain/config.env` for `SECOND_BRAIN_VAULT`
   (fallback), `SECOND_BRAIN_TIMEZONE`, and `SECOND_BRAIN_SLACK_DM`. Call the
   vault `<vault>`.
2. **Parse args:** `--quick` (fast mode), `--notify` (send Slack DM — the weekly
   scheduled run passes this; on-demand `/dream` must NOT), `--since YYYY-MM-DD`
   (override the window).
3. **Guards — bail with a clear message if any fail:**
   - Vault must be a git repo: `git -C <vault> rev-parse --git-dir` succeeds. If not:
     *"Vault isn't git-backed yet — run `git init` in `<vault>` first. Dreams need git for the non-destructive review branch."* Stop.
   - Working tree should be clean-ish on `main`: `git -C <vault> status --porcelain`.
     If there are uncommitted changes, commit them first (`pre-dream snapshot`) so
     the dream branch diffs cleanly. Tell the user you did this.
   - No existing dream branch for this period (see Step 1); if one exists, ask
     whether to resume it or start fresh.

## Step 1 — Set up the dream worktree (non-destructive)

Compute the period label from the window end date: ISO week `YYYY-Wxx`
(`date +%G-W%V`). Then create an **isolated git worktree** so Obsidian (which
follows the live vault on `main`) is never disturbed while the dream runs:

```bash
cd <vault>
git worktree add ../$(basename <vault>)-dream-<YYYY-Wxx> -b dream/<YYYY-Wxx>
```

All reads-of-the-store for *editing* and **all writes** happen inside that
worktree dir (call it `$DREAM`). Never edit files under the live `<vault>`
path during a dream.

## Step 2 — Gather inputs (the two dream input types)

- **The memory store** (read from `$DREAM`): `Memory/MEMORY.md`, `Topics/`,
  `People/`, `DataContext/`. This is what gets reorganized.
- **The sessions** (read-only, NEVER rewritten — the evidence the dream mines):
  - This window's Claude Code transcripts: `~/.claude/projects/*/*.jsonl`
    modified within the window (`find ~/.claude/projects -name '*.jsonl' -newermt <start>`).
  - This window's `Sessions/` handoffs (written by `/document --auto`).
  - This window's `Journal/` daily entries and `Meetings/` notes.
  Window = `--since` if given, else since the last dream (most recent
  `dream/*` merge or `Journal/*-rollup.md`), else the current ISO week.

`Journal/` and `Meetings/` are the immutable episodic record — read them for
evidence and timestamps, do not edit or delete them.

## Step 3 — Consolidation pass (the core)

Operate only on the **semantic memory**: `Topics/`, `People/`, `DataContext/`,
and `Memory/`. Apply the locked prune policy:

- **Dedup / merge.** Find notes covering the same person/topic/datum (near-dup
  filenames, heavy backlink overlap, restated content). Merge into the single
  best canonical note; fix inbound `[[wikilinks]]` to point at it;
  **hard-delete** the redundant copy (its content survives in the merge target
  and in git history).
- **Promote the inbox.** For each flat note the harness dropped in `Memory/`
  (anything other than `MEMORY.md`): route its durable content into the right
  graph note (`People/Topics/DataContext`) per the `MEMORY.md` routing table,
  cross-link it, then delete the inbox file. Drop one-off/episodic scraps into
  the relevant `Journal/` day as a `## Learned:` note instead.
- **Resolve contradictions.** When two notes disagree, keep the **latest** value
  (use Journal timestamps / git dates as tiebreaker). Replace the stale value in
  place and add a one-line `> superseded YYYY-MM-DD: was <old>` note.
- **Archive stale.** Whole notes that are clearly outdated (superseded
  workstream, departed person, retired model) **move to `_archive/`** (preserves
  recoverability, drops them out of the Tier-2 backlink grep). Don't hard-delete
  whole notes — archive them. Honor existing `_archive/` subfolders.
- **Surface insights.** Fold recurring patterns from the window's sessions into
  the graph: create/enrich Topic nodes and People files for things mentioned
  repeatedly but thinly grounded.
- **Trim `MEMORY.md`.** Push any detail that crept into the manifest down into
  the graph; keep it a thin mount-description (identity + routing table + pointer
  to `Topic-Index.md` + a few durable hot facts). Target well under the 25KB /
  200-line auto-load limit.
- **Regenerate `Topics/Topic-Index.md`** by scanning `Topics/`, `People/`,
  `DataContext/` (the recall entry point — keeping it current saves tokens in
  every daytime session).

Commit the consolidation to the branch:
`git -C $DREAM add -A && git -C $DREAM commit -m "dream <YYYY-Wxx>: consolidate memory store"`.

## Step 4 — Weekly rollup (full mode only; skip in --quick)

Write the episodic digest `Journal/<YYYY-Wxx>-rollup.md`, following
`<vault>/DataContext/Weekly-Rollup-Template.md` if it exists. Include: week's theme, key
deliverables by topic, decisions, blockers, people, topic-node updates,
`## Open Questions for the user` (recurring gaps — capped at 10), `## Questions
Resolved This Week` (if `DataContext/kickoff-resolutions.md` exists, scan it for
`→ Written to` this week), and staleness escalations (questions appearing 3+
consecutive days).
This is an append (new file) — the rollup never rewrites prior journals.
Commit it.

## Step 5 — Dream Report (always)

Write `$DREAM/Dream-Report.md` AND print it to the terminal. Open with a
**fragmentation summary**, then details:

```markdown
# Dream Report — <YYYY-Wxx>

## Defrag summary
- Duplicate clusters merged: N   (files deleted: M)
- Notes archived (stale):    N
- Contradictions resolved:   N
- Inbox notes promoted:      N
- Insights surfaced (new/enriched Topics & People): N
- MEMORY.md: <before>KB → <after>KB
- Orphan notes linked:       N

## Merges
- `People/Jon Doe (1).md` → merged into `People/Jon Doe.md` (deleted dup)
## Archived
- `Topics/Old Thing.md` → `_archive/` — superseded by [[New Thing]]
## Contradictions
- `DataContext/x.md`: PEPM floor $5 → $6 (latest, per 2026-05-20 journal)
## Insights
- New `Topics/<X>.md` — mentioned in 4 sessions, was ungrounded

## Review
- Diff:    git -C <vault> diff main..dream/<YYYY-Wxx>
- Adopt:   bash ${CLAUDE_PLUGIN_ROOT}/scripts/adopt-dream.sh <YYYY-Wxx>
- Discard: git -C <vault> worktree remove ../<...>-dream-<YYYY-Wxx> && git -C <vault> branch -D dream/<YYYY-Wxx>
```

## Step 6 — Notify (ONLY if --notify)

If and only if `--notify` was passed (weekly scheduled run), send the Defrag
summary + Review block as a Slack DM to `SECOND_BRAIN_SLACK_DM` (via the Slack
connector). If it isn't set or no Slack tool is available, say so and skip. On
on-demand `/dream`, send nothing to Slack — the terminal + `Dream-Report.md`
are the whole output.

## Step 7 — Hand off (do NOT merge)

Leave the branch + worktree for review. Print the Review block. The dream never
merges itself — adoption is the user's explicit `adopt-dream.sh` (or merge),
discard is `adopt-dream.sh <YYYY-Wxx> --discard`.

---

## --quick mode

Skip Steps 2's session-mining, Step 4 (rollup), and Step 5's insight surfacing.
Do only: trim `MEMORY.md` under limit, promote the `Memory/` inbox, merge
obvious duplicates, regenerate `Topic-Index.md`. Still runs on the worktree/branch
and still writes a (shorter) Dream Report. For when the manifest is bloating and
the user wants a fast defrag.

## Rules / safety

- **Never edit the live vault working tree during a dream** — only the worktree.
- **Never rewrite `Journal/` or `Meetings/`** — episodic record is read-only.
- **Archive whole notes, hard-delete only merged duplicates** (locked prune policy).
- **Never merge the branch yourself.** Adoption and discard are the user's.
- **Be concrete and conservative:** if unsure whether two notes are truly
  duplicates or whether a note is stale, leave it and note it in the report under
  a `## Needs the user's call` section rather than acting.
- Don't fabricate. Surface gaps as Open Questions; don't invent content.
