# second-brain repo

This repo is a Claude Code plugin marketplace (`.claude-plugin/marketplace.json`)
with two plugins under `plugins/`. The second-brain protocol itself (vault
lookup, writing rules, Learning Loop) lives in
`plugins/second-brain/skills/protocol/SKILL.md`. Edit it there, not here.

## Layout

- `plugins/second-brain/` — core plugin: skills (`protocol`, `document`,
  `dream`, `setup`), `hooks/hooks.json`, `scripts/`, `vault-template/`.
- `plugins/work-kit/` — work-machine skills with their bundled scripts.
- `TO_BUILD.md` — everything a plugin can't carry.
- `harness/`, `scripts/*-harness.py` — templated settings/statusline/launchd,
  generated from the live `~/.claude`.
- `scheduled-tasks/`, `config.example.yaml`, `SETUP.md` — the scheduled
  pipeline. Live launchd jobs read `scheduled-tasks/*.md` by path, so don't
  move or rename those files.

## Rules

- **Plugins stay generic.** No personal names, employer names, IDs, or
  absolute paths under `plugins/`. Say "the user". Per-machine values come
  from `~/.claude/second-brain/config.env` (loaded by
  `plugins/second-brain/scripts/config.sh`). Anything private goes in a file
  under `~/.claude/second-brain/` that the plugin reads, never in the repo.
- **Refer to bundled files with `${CLAUDE_PLUGIN_ROOT}`**, in `hooks.json` and in
  SKILL.md. Installed plugins run from a cache, so relative paths break.
- **Bump `version`** in the plugin's `.claude-plugin/plugin.json` for any
  change you want machines to pick up.
- **Test before pushing**, against a throwaway vault:
  ```bash
  printf 'SECOND_BRAIN_VAULT="%s"\n' /tmp/sb-test-vault > /tmp/sb-test.env
  SECOND_BRAIN_CONFIG=/tmp/sb-test.env claude --plugin-dir plugins/second-brain --plugin-dir plugins/work-kit
  ```
  Also run `grep -rniE '\{\{|<your-name>|<employer>' plugins --exclude-dir=vault-template`
  (substitute real strings); it should return nothing.
