# Nightly Journal

## Configuration

This prompt is rendered by the second-brain plugin's `scripts/run-nightly-journal.sh`, which fills in the variables below before the run. Variables used:
- `target_date` — the specific date (YYYY-MM-DD) this run covers. May be today, or a past weekday being backfilled after a missed run — never assume "today" means "now."
- `target_date_next` — `target_date` + 1 calendar day (for date-range searches)
- `vault_path` — absolute path to the Obsidian vault
- `slack_user_id` — the user's Slack member ID (may be empty — see Data Source 4)
- `log_dir` — directory for task logs
- `gap_warning` — empty, or a callout noting older missed weekdays that were skipped by the backfill cap (see the wrapper script)

To customize this prompt on one machine, copy it somewhere outside the plugin and point `SECOND_BRAIN_NIGHTLY_JOURNAL_TEMPLATE` in `~/.claude/second-brain/config.env` at the copy.

## Context

This is an automated task running without user interaction. Execute autonomously — make reasonable choices and note them in your output. Only take "write" actions this task explicitly asks for.

This task is the nightly pipeline: export the day's meetings, then write the daily work journal to the Obsidian vault. It runs in the evening after the workday ends.

## Use whatever sources this machine has — skip the rest

Every data source below is optional. Different users connect different tools. Before each step, check whether the tools it needs are available in this session (connector tools are named like `mcp__<server>__<tool>`, e.g. a tool whose name contains `Granola`, `Slack`, `Gmail`, `Google_Drive`, or `Google_Calendar`). **If a source's tools aren't available, or a call is denied or errors, skip that source silently and move on.** Never stop the run because one source is missing. At the very end, if any of Granola, Slack, Gmail, or Google Calendar were unavailable, add one short line to the journal's `## Summary` such as "Sources not connected tonight: Slack, Gmail." so the user knows the entry is thinner than it could be.

## Objective

1. Export the day's meetings to the vault (Step 0 — Granola if connected, otherwise Google Calendar)
2. Gather context about everything worked on that day (WORK ONLY) and write a structured journal entry
3. Capture any Google Drive files shared that day (Data Source 5), indexed against the sharer's People note
4. Capture GitHub PR activity, if the GitHub CLI is signed in (Data Source 8)

## CRITICAL: Work content only

Only log work-related activity. Do NOT log personal topics — the user may use Claude for personal research and none of that belongs in this vault. When scanning Claude sessions, skip any conversation that is clearly personal.

## Step 0: Meeting Export (RUN THIS FIRST)

Before gathering journal data, export the day's meetings into the vault using the **Granola connector**. If no Granola tools are available, skip to **0e** (calendar fallback).

### 0a. Fetch {{target_date}}'s meetings from Granola

1. Call `list_meetings` with `time_range: "this_week"` to get a list of recent meetings. If `{{target_date}}` falls outside the current week (a backfilled date from a prior week), try `time_range: "last_week"` or an explicit date-range parameter if the tool supports one — check the live tool signature rather than assuming.
2. Filter the results to meetings from **{{target_date}}** (by date in the title or metadata).
3. For each meeting from {{target_date}}, call `get_meetings` with the meeting IDs to retrieve full details (attendees, AI-generated summary, notes).

### 0b. Check what already exists in Obsidian

```bash
MEETINGS_DIR={{vault_path}}/Meetings
PEOPLE_DIR={{vault_path}}/People
COMPANIES_DIR={{vault_path}}/Meetings/_Companies
today="{{target_date}}"

# Ensure directories exist
mkdir -p "$MEETINGS_DIR" "$COMPANIES_DIR" "$PEOPLE_DIR"

# List existing meeting files for today
ls "$MEETINGS_DIR"/${today}*.md 2>/dev/null
```

For each Granola meeting, build the expected filename as `{date} {sanitized_title}.md`. If the file already exists AND has real content (not the placeholder `*AI summary not yet available*`), skip it. If it exists but only has the placeholder, update it with the Granola summary.

### 0c. Write meeting files to Obsidian

For each new or updated meeting, use a Python script to write the markdown file. The script handles filename sanitization and index updates:

```python
import os, re

VAULT_DIR = os.environ.get("VAULT_PATH", os.path.expanduser("{{vault_path}}"))
MEETINGS_DIR = os.path.join(VAULT_DIR, "Meetings")
COMPANIES_DIR = os.path.join(MEETINGS_DIR, "_Companies")
PEOPLE_DIR = os.path.join(VAULT_DIR, "People")

def sanitize_filename(title):
    clean = re.sub(r'[<>:"/\\|?*]', '', title)
    clean = re.sub(r'\s+', ' ', clean).strip()
    return clean[:120].rsplit(' ', 1)[0] if len(clean) > 120 else clean

def write_meeting(date, title, attendees, notes):
    """
    attendees: list of dicts with keys: name, email (optional), company (optional)
    notes: string — the AI-generated summary from Granola
    """
    filename = f"{date} {sanitize_filename(title)}"
    att_links = ", ".join(f"[[{a['name']}]]" for a in attendees)
    companies = list(set(a.get("company", "") for a in attendees if a.get("company")))
    comp_links = ", ".join(f"[[{c}]]" for c in companies)

    lines = ["---", f"date: {date}", f"title: {title}", f"attendees: [{att_links}]",
             f"companies: [{comp_links}]", "source: granola", "---", "",
             f"# {title}", "", "## Attendees"]
    for a in attendees:
        email_part = f" ({a['email']})" if a.get('email') else ""
        lines.append(f"- [[{a['name']}]]{email_part}")
    lines.extend(["", "## Notes",
                   notes if notes else "*AI summary not yet available — will be updated on next export.*", ""])

    with open(os.path.join(MEETINGS_DIR, filename + ".md"), "w") as f:
        f.write("\n".join(lines))

    # Update People/ index
    for att in attendees:
        pfile = os.path.join(PEOPLE_DIR, f"{sanitize_filename(att['name'])}.md")
        if os.path.exists(pfile):
            with open(pfile) as f: pcontent = f.read()
            if filename not in pcontent:
                pcontent = pcontent.replace("## Meetings\n", f"## Meetings\n- [[{filename}]]\n")
                with open(pfile, "w") as f: f.write(pcontent)
        else:
            plines = []
            if att.get('email'): plines.extend(["---", f"email: {att['email']}", "---", ""])
            plines.extend([f"# {att['name']}", "", "## Meetings", f"- [[{filename}]]", ""])
            with open(pfile, "w") as f: f.write("\n".join(plines))

    # Update _Companies/ index
    for comp in companies:
        if not comp: continue
        cfile = os.path.join(COMPANIES_DIR, f"{sanitize_filename(comp)}.md")
        if os.path.exists(cfile):
            with open(cfile) as f: ccontent = f.read()
            if filename not in ccontent:
                ccontent = ccontent.replace("## Meetings\n", f"## Meetings\n- [[{filename}]]\n")
                with open(cfile, "w") as f: f.write(ccontent)
        else:
            with open(cfile, "w") as f:
                f.write("\n".join([f"# {comp}", "", "## Meetings", f"- [[{filename}]]", ""]))

    return filename
```

### 0d. Map Granola data to the write_meeting function

For each meeting returned by `get_meetings`:

1. **Date**: Extract from the meeting's start time or creation date. Format as `YYYY-MM-DD`.
2. **Title**: Use the meeting title from Granola.
3. **Attendees**: Build the list from Granola's attendee data. Each attendee should have `name` and optionally `email` and `company`. If company info isn't available from Granola, leave it empty.
4. **Notes**: Use the AI-generated summary from `get_meetings`. This is Granola's processed meeting summary.

Call `write_meeting(date, title, attendees, notes)` for each meeting.

Log results:
```python
from datetime import datetime

LOG_DIR = os.environ.get("LOG_DIR", os.path.expanduser("{{log_dir}}"))
LOG_FILE = os.path.join(LOG_DIR, "granola-export.log")
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
with open(LOG_FILE, "a") as f:
    f.write(f"[{ts}] Granola MCP export: {exported} new, {updated} updated, {skipped} unchanged\n")
```

After the export completes, proceed to the journal data gathering below.

### 0e. Calendar fallback (only if Granola isn't available)

If there are no Granola tools but a Google Calendar connector is available, list the user's events on {{target_date}} (`list_events` for that day on the primary calendar). For each event the user accepted that had at least one other attendee, call `write_meeting(date, title, attendees, notes)` with `notes` set to the event description if it has one, otherwise `"*No meeting notes — from calendar only.*"`. Skip declined events, all-day events, and focus/hold blocks with no other attendees. Don't overwrite a meeting file that already exists.

If neither Granola nor Google Calendar is available, skip Step 0 entirely.

## Data Sources — Check All of These (in priority order)

### 1. Claude Desktop (Cowork) Session JSONL Files
Only if the Claude desktop app's agent sessions exist on this machine (skip if the directory is missing). They are stored as JSONL files on disk. To find today's sessions:

```bash
find ~/Library/Application\ Support/Claude/local-agent-mode-sessions -name "*.jsonl" -path "*projects*" -newermt "{{target_date}} 00:00:00" -type f
```

Each JSONL file contains one JSON object per line. Parse it like this:
```python
import json
from datetime import datetime, date

today = "{{target_date}}"
with open(jsonl_path) as f:
    for line in f:
        entry = json.loads(line)
        ts = entry.get('timestamp', '')
        if not ts.startswith(today):
            continue
        msg = entry.get('message', {})
        role = msg.get('role', '')
        if role == 'user':
            content = msg.get('content', '')
            if isinstance(content, str):
                print(f"[USER] {content[:200]}")
        elif role == 'assistant':
            content = msg.get('content', [])
            if isinstance(content, list):
                for block in content:
                    if block.get('type') == 'text':
                        print(f"[ASSISTANT] {block['text'][:200]}")
```

Extract the key topics, decisions, and work done. Skip thinking blocks (type: "thinking"). Focus on user requests and assistant summaries. Filter out personal topics.

### 2. Claude Code Session JSONL Files
Same format, stored in `~/.claude/projects/`. Find today's:
```bash
find ~/.claude/projects -name "*.jsonl" -newermt "{{target_date}} 00:00:00" -type f 2>/dev/null
```
Parse identically to Cowork sessions.

### 3. Meetings (exported in Step 0)
Step 0 already exported meetings from Granola or the calendar. Check for meetings from {{target_date}}:
```bash
find {{vault_path}}/Meetings/ -name "{{target_date}}*.md" -type f 2>/dev/null
```
For each meeting file from today, read it and include a summary in the journal entry under a "## Meetings" section. Include the meeting title, attendees, and key topics discussed. If the file has a `## Transcript` section, summarize the key discussion points from it. If it only has Granola notes or is still empty, note that.

Also check the export log for any errors:
```bash
tail -20 {{log_dir}}/granola-export.log 2>/dev/null
```

### 4. Slack Activity (targeted)
Only if a Slack connector is available. The user's Slack member ID is `{{slack_user_id}}`. If that is empty, look the user up once with the Slack connector's user search (by the name or email in `{{vault_path}}/Memory/MEMORY.md`) to get their member ID; if you can't identify them with confidence, skip Slack and note it.

Search Slack for three categories ONLY:
- **Messages the user sent on {{target_date}}:** `from:<@{{slack_user_id}}> after:{{target_date}} before:{{target_date_next}}`
- **DMs and group DMs to the user:** search in DMs/group DMs for {{target_date}}
- **Channel messages where the user is tagged:** `<@{{slack_user_id}}> after:{{target_date}} before:{{target_date_next}}`

Do NOT include random channel messages the user didn't write or wasn't tagged in. Summarize themes — do NOT reproduce full messages.

### 5. Files Shared (Gmail + Slack)

People share Google Drive files constantly, especially in the first weeks at a new job — capture who shared what so it's findable later (e.g. "my manager shared a planning doc last week, find it").

Run 5a only if a Gmail connector is available, 5b only if a Google Drive connector is available (without Drive, keep the link from the email or message as-is), and 5c only if Slack was searched in Data Source 4.

**5a. Gmail Drive-share notifications.** Search Gmail:
```
search_threads: from:drive-shares-dm-noreply@google.com after:{{target_date}} before:{{target_date_next}}
```
For each thread, parse the **sharer's name and email** from the snippet (pattern: "`<Name>` shared a `<type>`", followed by their email) and the **file title and type** from the subject line (pattern: `<Type> shared with you: "<Title>"`).

**5b. Cross-reference to Drive.** For each file found in 5a, resolve it via `search_files` (`title contains '<parsed title>'`) to get the real `fileId`, `viewUrl`, and `mimeType`. A bare title isn't useful later — the point is a working link.

**5c. Slack-shared links.** Re-scan the Slack messages already gathered in Data Source #4 above (do not run a new Slack search) for `drive.google.com` or `docs.google.com` URLs pasted in message text. For each one: extract the file ID directly from the URL path (pattern: `/d/([a-zA-Z0-9_-]+)/`), use the message's sender as "shared by," and note the channel/DM as provenance. Optionally call `get_file_metadata(fileId)` for a canonical title. Skip the "Drive for Slack" bot notification DM — its messages render as empty text in search and aren't reliably parseable.

**5d. De-duplicate and write.** If the same `fileId` was found via both Gmail and Slack, merge into one record noting both channels. For each unique shared file, write it into the sharer's People note:

```python
import os, re

VAULT_DIR = os.path.expanduser("{{vault_path}}")
PEOPLE_DIR = os.path.join(VAULT_DIR, "People")

def sanitize_filename(title):
    clean = re.sub(r'[<>:"/\\|?*]', '', title)
    clean = re.sub(r'\s+', ' ', clean).strip()
    return clean[:120].rsplit(' ', 1)[0] if len(clean) > 120 else clean

def write_shared_file(date, sharer_name, sharer_email, file_title, file_id, view_url, source):
    """source: "gmail", "slack", or "gmail+slack" if de-duplicated from both."""
    pfile = os.path.join(PEOPLE_DIR, f"{sanitize_filename(sharer_name)}.md")
    marker = f"fileId:{file_id}"
    entry = f"- [{file_title}]({view_url}) — shared {date} via {source} <!-- {marker} -->"

    if os.path.exists(pfile):
        with open(pfile) as f: pcontent = f.read()
        if marker in pcontent:
            return  # already recorded — avoids duplicates if a date is re-run
        if "## Files Shared" in pcontent:
            pcontent = pcontent.replace("## Files Shared\n", f"## Files Shared\n{entry}\n")
        else:
            pcontent = pcontent.rstrip("\n") + f"\n\n## Files Shared\n{entry}\n"
        with open(pfile, "w") as f: f.write(pcontent)
    else:
        email_part = [f"email: {sharer_email}"] if sharer_email else []
        plines = ["---", *email_part, "---", "", f"# {sharer_name}", "",
                   "## Files Shared", entry, ""]
        with open(pfile, "w") as f: f.write("\n".join(plines))
```

### 6. File Changes in Obsidian Work Vault
Run: `find {{vault_path}}/ -name "*.md" -newermt "{{target_date}} 00:00:00" ! -newermt "{{target_date_next}} 00:00:00" -type f` to find files modified on {{target_date}}.
- New meetings in Meetings/ = meetings attended
- Changes to Analysis/, DataContext/, Questions-Log.md = analytical work done

### 7. Daily Notes (manual supplement)
Check `{{log_dir}}/daily-notes/{{target_date}}.md` for any manually logged notes from the day.

### 8. GitHub Activity
Only if the GitHub CLI is installed and signed in: run `gh auth status`. If it fails or `gh` isn't found, skip this source without comment.

Find pull requests the user opened or updated on {{target_date}} (read-only):

```bash
gh search prs --author=@me --updated={{target_date}} --json repository,number,title,url,state,updatedAt,createdAt,closedAt --limit 50
gh search prs --involves=@me --updated={{target_date}} --json repository,number,title,url,state,updatedAt --limit 50
```

For a PR that needs more detail, `gh pr view <number> --repo <owner/repo> --json title,body,commits,mergedAt` shows its description and commits.

For each PR, write a bullet under `## GitHub`:
- Title linked to `url`, and the repo.
- What happened that day (opened, merged, closed, or updated), from the timestamps.
- One or two lines on what it does, distilled from the description and that day's commits. Group commit themes; don't list every commit.
- Link the matching `Projects/` or `Topics/` note when the PR clearly belongs to one. Check `ls {{vault_path}}/Projects/ {{vault_path}}/Topics/`, and only link notes that exist.

If the searches error after `gh auth status` succeeded, add one line under the section saying GitHub activity couldn't be collected and why. Don't fail the run. If there are no PRs, omit the section.

## Output Format

Write the journal entry to: `{{vault_path}}/Journal/{{target_date}}.md` (use the target date — this may be a backfilled past weekday, not necessarily today).

**If the file already exists**, append a horizontal rule (`---`) and a new section header (`## Evening Summary (auto-generated)`) below the existing content. Do NOT overwrite manual notes.

**If the file does not exist**, create it fresh.

### Wiki Link Convention — Link to Existing Topics

The vault has topic hub nodes in `Topics/`. When writing the journal, use `[[wiki links]]` to reference **existing** topic nodes wherever a workstream is clearly relevant. This strengthens the Obsidian graph view over time.

First, check what topic nodes exist:
```bash
ls {{vault_path}}/Topics/
```

Then, when writing about a workstream that matches a topic node, link to it naturally in the text. For example, write "Worked on [[Commission]] calculations" instead of just "Worked on commission calculations." Use the `[[Topic Name|display text]]` syntax when the topic name doesn't fit grammatically: `[[Pricing and Packaging|pricing]] discussions`.

**Important:** Only link to topics that already exist in `Topics/`. Do NOT create new topic nodes — that's the weekly rollup's job. If a workstream doesn't have a topic node yet, just write it in plain text.

### Context Gap Surfacing

While writing the journal, you'll encounter people, projects, terms, or systems that have no vault coverage. **Do not fabricate context. Do not silently drop them.** Surface them in a `## Open Questions` section near the bottom of the journal entry (just before `## Related Topics`), so the next interactive session can engage the Learning Loop (see the `second-brain:protocol` skill) and persist the answers to the right vault location.

You cannot ask the user mid-run — you're a scheduled task, not interactive. Surface, don't block.

What to surface:
- **New attendees** for whom you created a bare `People/` file from meeting metadata but have no role or workstream context
- **Undocumented projects, systems, or terms** mentioned in transcripts that have no Topic node and no DataContext file
- **Conflicts** where the journal/transcript says one thing and TODO.md or another vault file says another
- **References to "the X model" or "the Y system"** that you can't ground in any vault file

What NOT to surface:
- Things you can verify from the vault — no need to ask
- Personal/non-work content — skip entirely
- Trivia or one-off mentions that don't affect future work
- More than ~5 questions per night — prioritize people you actually met today, then active workstreams, then stale references

Format each question to be answerable in one back-and-forth. Be specific so the next session knows exactly what's missing.

Example:

```markdown
## Open Questions
- **New person:** Created bare `People/Lukas Ming.md` from today's 11am 1:1. What's his role and which workstream does he report into?
- **Unknown topic:** "Pricing Migration" came up in 2 meetings today but there's no `Topics/` node. Standalone workstream or part of [[Pricing and Packaging]]?
- **Conflict:** TODO.md says "DATA-3110 In Progress" but Jamie's transcript says "we shipped DATA-3110 last Friday." Which is correct?
```

Omit this section entirely if there are no gaps. Don't add a "no questions today" line.

### Journal Format

Follow this format (match the style of existing journal entries):

```markdown
# Session Notes — {{target_date}}

{{gap_warning}}

## Summary
[1-3 sentence overview of what was worked on today]

---

## [Project/Topic Name]
- Key details, decisions, results
- Status updates

## [Another Project/Topic]
...

## Meetings
- [Meeting title] — attendees, key topics/decisions (from the Step 0 export)

## Slack Highlights
- Notable threads, decisions, or questions (summarized, not quoted)

## Files Shared
- [File title](link) — shared by [[Person Name]] via Gmail/Slack

## GitHub
- [PR title](url) — repo — opened/merged/N commits — what it does. Links [[Project]]

## Open Items (Carried Forward)
- [ ] Any unfinished work or next steps identified today

## Open Questions
[Only include this section if there are unanswered context gaps. See "Context Gap Surfacing" above.]
- **[Type of gap]:** [Specific question, with enough context that one back-and-forth resolves it]

---

## Related Topics
[[Topic 1]], [[Topic 2]], [[Topic 3]]

## Related Files
- Links to any files created or modified today
```

## Rules

- WORK CONTENT ONLY — no personal topics
- Be concise and factual — this is a reference log, not a narrative
- If a source has no relevant content, skip that section entirely
- If there's very little work activity across all sources, write a short log noting it was a light day
- Never fabricate work that didn't happen — only log what you can verify from sources
- Use relative Obsidian vault paths in Related Files links (e.g., `Analysis/filename.md`)
- When summarizing Claude sessions, focus on WHAT was built/decided/analyzed, not the back-and-forth of the conversation
- Use `[[wiki links]]` when referencing people and existing topic nodes (see Wiki Link Convention above)
- Always end the journal with a `## Related Topics` section listing all topic nodes referenced in the entry
- **Surface gaps, don't fabricate.** When you encounter unfamiliar people, topics, or systems, add them to `## Open Questions` (see Context Gap Surfacing) — never invent context to fill the gap
- **This entry may be a same-run backfill of a past weekday, not written same-day.** Scope every search strictly to {{target_date}} — never blend in Slack/session/meeting content from adjacent days even if it's the most readily available data
- **Don't guess at who shared a file.** If a Drive link's sharer can't be confidently identified from the Gmail snippet or the Slack message sender, skip writing it to a People note rather than attributing it to the wrong person — a missed file share is recoverable, a wrongly-attributed one pollutes the wrong person's note
