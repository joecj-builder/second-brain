---
name: setup
description: >
  One-time setup of the second brain on this machine: choose the vault,
  write ~/.claude/second-brain/config.env, point Claude Code's auto-memory at
  the vault, scaffold a new vault from the template, and opt in to extras
  (auto-document on session end, keep-awake). Use right after installing the
  second-brain plugin, when the session-start context says the second brain
  isn't configured, or when the user says "/setup", "set up my second brain",
  or "change my vault".
allowed-tools: Bash, Read, Edit, Write, Glob
---

# setup — Agent Skill

A plugin can't write user settings or ask for a vault path by itself, so this
skill does the one-time, per-machine part. Run each step in order, confirm
before every write outside the vault, and make every step safe to re-run.

## 1. Read what's already there

```bash
cat ~/.claude/second-brain/config.env 2>/dev/null
jq '.autoMemoryDirectory' ~/.claude/settings.json 2>/dev/null
```

If a config exists, show it and ask what to change instead of starting over.

## 2. Choose the vault

Ask for the vault's absolute path. Suggest `~/obsidian-vaults/<Name>` if they
have nothing yet. Then find out which case applies:

- **Existing vault on disk** — use it as is.
- **Vault in a git repo, not cloned yet** — ask for the URL and
  `git clone <url> <path>`.
- **New vault** — go to step 4 after writing the config.

One machine, one vault. If the user wants a different vault for a
different purpose, that belongs on a different machine (or a different
config file via `SECOND_BRAIN_CONFIG`).

## 3. Write `~/.claude/second-brain/config.env`

Ask about each optional key and explain it in one line. Keep the defaults
unless the user says otherwise:

| Key | Default | What it does |
|---|---|---|
| `SECOND_BRAIN_VAULT` | (required) | Absolute vault path |
| `SECOND_BRAIN_TIMEZONE` | output of `readlink /etc/localtime` (the part after `zoneinfo/`) | Used for dates in journals and rollups |
| `SECOND_BRAIN_AUTODOC` | `true` | Run `/second-brain:document --auto` when a session ends. Costs one extra headless run per qualifying session |
| `SECOND_BRAIN_AUTODOC_MIN_PROMPTS` | `3` | Skip sessions shorter than this |
| `SECOND_BRAIN_SLACK_DM` | empty | Slack channel for `/dream --notify` |
| `SECOND_BRAIN_KEEP_AWAKE` | `false` | macOS: keep the Mac awake with the lid closed while Claude works. Needs a sudoers rule (step 6) |

Write it as plain `KEY="value"` lines with a header comment saying the file
was written by `/second-brain:setup`. `mkdir -p ~/.claude/second-brain` first.

## 4. Scaffold a new vault (new vaults only)

Only when the target directory is missing or empty:

```bash
mkdir -p <vault>
cp -R ${CLAUDE_PLUGIN_ROOT}/vault-template/. <vault>/
```

Then ask for the user's name, role, and (if it's a work machine) company.
Replace `{{user_name}}`, `{{user_role}}`, `{{company}}`, and `{{vault_path}}` in the
copied files; on a personal machine, drop the "at {{company}}" phrases instead. Fill `Memory/MEMORY.md`'s identity section from the same
answers. Leave `[Fill in: …]` prompts for the user to complete in Obsidian.

Then make it git-backed (`/dream` and auto-document need git):

```bash
git -C <vault> init -b main && git -C <vault> add -A && git -C <vault> commit -m "Scaffold second brain"
```

For an existing vault that isn't a git repo, offer the same `git init`.

## 5. Point auto-memory at the vault

Show the change first, then merge `autoMemoryDirectory` into
`~/.claude/settings.json` without touching other keys:

```bash
tmp=$(mktemp) && jq --arg d "<vault>/Memory" '.autoMemoryDirectory = $d' ~/.claude/settings.json > "$tmp" && mv "$tmp" ~/.claude/settings.json
```

If `settings.json` doesn't exist, create it as `{"autoMemoryDirectory": "<vault>/Memory"}`.
Make sure `<vault>/Memory/MEMORY.md` exists.

## 6. Extras (ask about each; all optional)

- **Keep-awake** (only if `SECOND_BRAIN_KEEP_AWAKE=true`): print this line and
  tell the user to add it with `sudo visudo -f /etc/sudoers.d/claude-nosleep`
  themselves. Never run sudo for them:
  `<whoami output> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep *`
- **Things the plugin doesn't carry.** Point at `TO_BUILD.md` in the plugin's
  repo (https://github.com/josephcoz/second-brain) for statusline, scheduled
  jobs, MCP connectors, and user settings.

## 7. Confirm

Tell the user what was written, in 3–5 lines:
- the config path and vault
- whether auto-memory now points at the vault
- whether auto-document is on

Then tell them the session-start context takes effect in their next session.
