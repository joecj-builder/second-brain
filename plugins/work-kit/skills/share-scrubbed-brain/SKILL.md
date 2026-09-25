---
name: share-scrubbed-brain
description: >
  Publish a SCRUBBED, shareable copy of the second-brain vault to Google Drive,
  diffed against what's already there — e.g. for colleagues covering while the
  user is out, or a successor after they leave. Scope is KNOWLEDGE ONLY
  (Topics/DataContext/Analysis/Projects/People by default); Journal, Meetings,
  Sessions, Memory are excluded. It scope-filters, runs a regex pre-pass AND an
  LLM judgment pass to redact compensation, opinions-on-people, and personal
  info (redact spans in place; exclude whole episodic/comp files), builds a
  git-backed staging tree you review, then syncs to Drive as Google Docs. Runs
  NON-DESTRUCTIVELY and is REVIEW-GATED — nothing uploads until the user
  approves. Use when the user says "/share-scrubbed-brain", "share a scrubbed
  copy of the vault", "update the scrubbed brain", "scrub and share the vault".
  Modes: default (full), --report-only (audit, no build/upload), --since <ref>
  (incremental).
allowed-tools: Bash, Read, Write, Glob, Grep, Task
---

# share-scrubbed-brain — Agent Skill

Produces a redacted, shareable mirror of the vault's *knowledge* and pushes it
to a Google Drive folder. Mirrors `/second-brain:dream`'s staged,
non-destructive, review-before-adopt pattern — except "adopt" here means
"publish to Drive", and that step is gated on the user's explicit approval.

**Why this is careful:** a work vault can hold compensation figures and candid
opinions on people. Regex alone is NOT safe — it redacts a line that says
"OTE" but misses the roster table beneath it. So the safety model is two
layers: an **LLM judgment pass** that reads each file, plus a **human review
gate** before anything leaves the machine. Never skip either.

Files this skill drives (`$SCRIPTS` = `${CLAUDE_PLUGIN_ROOT}/skills/share-scrubbed-brain/scripts`):
- `~/.claude/second-brain/scrub-config.toml` — the sensitivity ruleset
  (vault + staging paths, Drive folder, scope allowlist, tiered regex,
  per-item exclusions). Single source of truth. Kept out of the plugin repo
  because it names real people and paths.
- `$SCRIPTS/scrub_vault.py` — `--report-only` (audit) and
  `--apply --decisions <file>` (build staging tree + git commit).
- `$SCRIPTS/sync_scrubbed_to_drive.py` — manifest diff → create/update/trash
  Google Docs, wiki-link → Doc hyperlink rewrite.
- Staging dir `[vault].staging` from the config — git-backed; `vault/` is the
  scrubbed tree, plus `Scrub-Report.md`, `scrub-decisions.json`,
  `.gdoc-manifest.json`.

Call the vault `<vault>` and the staging dir `<staging>` below.

---

## Step 0 — Setup & guards

1. If `~/.claude/second-brain/scrub-config.toml` doesn't exist, copy
   `${CLAUDE_PLUGIN_ROOT}/skills/share-scrubbed-brain/scrub-config.example.toml`
   there. Then walk the user through `[vault]`, `[drive]`, and
   `[scope].exclude_paths` (ask which folders hold private or personnel
   content) before continuing.
2. Confirm `[vault].path` matches this machine's second-brain vault.
3. Python deps: `google-api-python-client`, `google-auth` (for the Drive
   sync); Python 3.11+ for `tomllib`.
4. Parse args: `--report-only` (stop after the audit), `--since <git-ref|date>`
   (only re-judge vault files changed since then — the incremental path),
   default = full.
5. The vault should be committed-ish (it's git-backed); not required, but note
   any uncommitted changes so the audit reflects current content.

## Step 1 — Audit (regex pre-pass)

Run `python3 $SCRIPTS/scrub_vault.py --report-only`. Read
`<staging>/Scrub-Report.md` and `scrub-candidates.json`. This gives the
in-scope file list, the heat ranking, and per-line candidate hits. If
`--report-only`, print the summary and STOP here.

## Step 2 — LLM judgment pass (the core safety layer)

Decide which files to judge:
- **Full run:** every in-scope file. Prioritize the flagged/heat-ranked ones,
  but also sample "clean" files — regex misses keyword-less sensitivity (e.g.
  a note about rehiring someone, roster tables with no "OTE" header on the
  data rows).
- **`--since` run:** only files changed in the vault since the ref
  (`git -C <vault> diff --name-only <ref>`), intersected with scope. Reuse
  prior `scrub-decisions.json` entries for unchanged files.

Spawn **parallel sub-agents in batches** (Task tool, ~15–25 files each). Give
each batch the file paths + the rubric below; have each return STRICT JSON
that gets merged into the decisions set. Rubric (audience = internal
colleagues; real names/customers/pricing are fine — do NOT redact those):

- **Redact (span):** any individual's compensation (OTE / salary / OTC /
  paymix / base / variable / bonus / equity) — including in tables/rosters,
  redact every such cell or row; comp-PLAN design dollar figures (keep the
  reasoning); the user's own leave or personal-life references; any candid
  assessment of a named person ("top rep", "high performer", "being
  considered for X", "50% attainment", "underperforming", "not a fit").
  Quote the EXACT substring to redact so the apply step is surgical.
- **Exclude (whole file):** files that are fundamentally per-person pay or a
  candid personnel/1:1/handoff artifact that slipped scope.
- **Keep:** everything else — the reusable knowledge.
- **When unsure → choose the safer action (redact/exclude) and flag it** for
  the user.

Decisions JSON shape (merge all batches into `<staging>/scrub-decisions.json`):
```json
{ "files": {
    "Projects/2026-03-17 Pipeline Model Analysis.md": {
      "action": "redact",
      "redactions": [
        {"line": 125, "match": "$100K | $107,500 | Ramping (hired Jan 1)", "reason": "comp"},
        {"line": 194, "match": "underperforming by ~$240K annual", "reason": "opinion on person"}
      ]
    },
    "DataContext/reference/rehire-notes.md": {"action": "exclude", "reason": "personnel"}
}}
```
(`line` is 1-based; `match` is replaced with `[redacted — reason]`. Omit
`match` to blank the whole line; `line: 0` matches the substring anywhere in
the file.)

## Step 3 — Apply (build the staging tree)

`python3 $SCRIPTS/scrub_vault.py --apply --decisions <staging>/scrub-decisions.json`

This copies in-scope, non-excluded files to `<staging>/vault/`, applies
redactions, flattens wiki-links that point at excluded/out-of-scope notes,
and commits the result (the staging git history is the audit trail of what
shipped).

## Step 4 — REVIEW GATE (do not skip)

1. **Self-check leak grep** on the staged tree — a BACKSTOP, not proof (a
   clean grep does NOT mean the tree is safe — the LLM pass is what catches
   keyword-less leaks like roster tables). Include evaluative phrases, not
   just comp keywords:
   ```bash
   cd <staging>/vault
   grep -rniE '\bOTE\b|\bsalary\b|\bpaymix\b|on-target (comm|earn)' . | grep -v 'redacted'
   grep -rniE 'underperform|top rep|high performer|attainment|being considered for|not a (good )?fit|managing out' . | grep -v 'redacted'
   # roster heuristic: person-name rows carrying $NNK comp figures
   grep -rnE '\| *[A-Z][a-z]+ [A-Z][a-z]+ *\|.*\$[0-9]+[Kk]' . | grep -v 'redacted'
   ```
   Any real comp/opinion hit → fix the decisions file and re-run Step 3.
2. Show the user: the apply summary, `git -C <staging> show --stat HEAD`,
   and the list of excluded files + a few sample redactions from
   `scrub-decisions.json`. Call out anything in the "unsure/flagged" bucket.
3. **Wait for the user's explicit approval to publish.** Nothing has left the
   machine yet.

## Step 5 — Publish to Drive (only after approval)

1. Dry-run: `python3 $SCRIPTS/sync_scrubbed_to_drive.py --dry-run` (shows
   create/update/trash counts).
2. If first run, confirm `[drive].share_with` is set in the config. Then
   live: `python3 $SCRIPTS/sync_scrubbed_to_drive.py`.
3. Report the folder URL, and created/updated/trashed counts. On the first
   run, confirm sharing was applied to the intended group only.

## Step 6 — Record

Append a one-line entry to today's `<vault>/Journal/YYYY-MM-DD.md`
(`## Learned:` or a run log): files shared, redactions, excluded, Drive
folder URL, staging commit hash.

---

## Rules / safety

- **Never upload a `--auto` baseline.** `scrub_vault.py --auto` only
  whole-line-redacts regex hits and leaks roster tables — it exists for
  engine testing, not publishing.
- **Never publish without the user's explicit approval** of the review gate
  (Step 4).
- **Default to over-redaction.** If a file is borderline, exclude or redact
  and flag it.
- **Tune the ruleset, not one-off hacks:** systematic false
  positives/negatives go into `scrub-config.toml`; re-run the audit.
- **Stay in scope:** never widen beyond the `include_dirs` allowlist without
  the user's say — Journal/Meetings/Sessions hold candid content and must
  remain excluded.
- The staging repo and Drive manifest make every run a diff: changed files
  re-judged and re-uploaded, removed files trashed, unchanged files skipped.
