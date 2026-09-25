---
name: make-google-doc
description: >
  Convert an existing markdown file into a Google Doc in the user's My Drive. Use
  when the user says "share this as a gdoc", "make a Google Doc out of this",
  "convert this writeup to a doc", "upload this to Drive as a doc", or similar.
  Default workflow: the user writes a .md file (in whatever working folder they're in),
  then asks for a Doc — this skill pipes the .md through the gdoc-create
  helper. The default destination is My Drive root (no folder).
allowed-tools: Bash, Read
---

# make-google-doc — Agent Skill

A common writeup format is a local `.md` file. When the user wants to share that
writeup with someone, they ask to "make it a Google Doc". This skill is the
consistent, low-token workflow for that conversion.

## Workflow

1. **Identify the source `.md` file.** the user will usually point at it ("the
   writeup I just made", a path, "the file in this directory"). If it's
   ambiguous and there's more than one candidate `.md` in the conversation
   context, ask before guessing.

2. **Pick the title.** Default rule: use the first H1 in the file (`# Title`),
   stripped of leading `#` and whitespace. If there's no H1, fall back to the
   filename without `.md`, with hyphens/underscores converted to spaces.
   the user can override by stating a title explicitly.

3. **Pick the folder.** Default: **none** (lands in the user's My Drive root). Only
   pass `--folder` when the user explicitly names one (e.g. "put it in the X
   folder"). Don't infer.

4. **Run the helper.** Read the `.md` via `cat` and pipe to the script:

   ```bash
   cat <path-to-md> \
     | python3 ${CLAUDE_PLUGIN_ROOT}/skills/make-google-doc/scripts/gdoc-create.py \
         --title "<title>"
   ```

   Add `--folder "<folder name>"` only when the user named one.

5. **Return the URL.** The script prints a single JSON line:
   `{"id":"...","url":"https://docs.google.com/document/d/.../edit"}`.
   Surface the `url` to the user as a clickable link. Don't echo the JSON.

## Notes

- **Don't pre-process the markdown.** Drive's import handles headings,
  bullets, tables, code blocks, links, and bold/italic correctly. Sending raw
  `.md` produces a cleanly-formatted Doc.
- **Auth.** Uses the user's OAuth credentials at `~/.config/gspread/authorized_user.json`
  (full Drive scope). The Doc lands in their My Drive — not a Shared
  Drive, not a service account drive. If the file is missing, see the
  work-kit section of `TO_BUILD.md` in the plugin's repo.
- **Python deps.** Needs `google-api-python-client` and `google-auth`
  (`pip install google-api-python-client google-auth`).
- **The `.md` stays put.** This skill only publishes; it doesn't move,
  rename, or delete the source file.
- **Don't use this for recurring/programmatic Drive workflows** that need to
  land in a Shared Drive — those need a service account.
- **Permission prompt on first run:** the bash command may need user approval
  the first time it runs from a new working directory. That's expected.
