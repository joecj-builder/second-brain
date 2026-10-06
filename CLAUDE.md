# second-brain repo

This repo is a Claude Code plugin marketplace (`.claude-plugin/marketplace.json`)
with two plugins under `plugins/`. The second-brain protocol itself (vault
lookup, writing rules, Learning Loop) lives in
`plugins/second-brain/skills/protocol/SKILL.md`. Edit it there, not here.

## Layout

- `plugins/second-brain/` — core plugin: skills (`protocol`, `document`,
  `dream`, `setup`), `hooks/hooks.json`, `scripts/` (incl. the scheduled-job
  runners and `install-scheduled-jobs.sh`), `templates/` (the nightly
  journal prompt), `launchd/` (plist templates), `vault-template/`.
- `plugins/work-kit/` — work-machine skills with their bundled scripts.
- `TO_BUILD.md` — everything a plugin can't carry.
- `harness/`, `scripts/*-harness.py` — templated settings/statusline/launchd,
  generated from the live `~/.claude`.
- `scheduled-tasks/`, `config.example.yaml`, `SETUP.md` — the legacy
  pre-plugin scheduled pipeline. Live launchd jobs on older machines read
  `scheduled-tasks/*.md` by path, so don't move or rename those files.

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
  (substitute real strings). The only `{{` hits should be intentional
  placeholders: `templates/`, `launchd/`, the setup skill's vault-template
  step, and the scripts that fill them.
- **Scheduled-job scripts run under macOS's `/bin/bash` 3.2.** Check with
  `bash -n` and `shellcheck -x`, and test `install-scheduled-jobs.sh` against a
  throwaway `HOME` with `--no-load` (no `launchctl`) or `--dry-run`.
- **Scheduled jobs never touch `~/.claude/settings.json`.** Their permissions
  come from `sb_write_job_settings` in `scripts/job-lib.sh`, passed per run
  with `--settings`. If a prompt or skill the jobs run starts using a new
  tool or command, add the narrowest matching rule there (and keep
  `skills/dream/SKILL.md`'s git list in sync with `SB_DREAM_GIT`).
- **Test scheduled-job changes with real runs, not just a fake `claude`.** A
  fake can't catch CLI argument or permission problems. Use a test config
  that sets `SECOND_BRAIN_VAULT` (a throwaway vault, or a `git clone` of a
  real one for the dream), `SECOND_BRAIN_LOG_DIR` and
  `SECOND_BRAIN_DREAM_DIR`, then run from the working tree:
  ```bash
  export SECOND_BRAIN_CONFIG=/path/to/test/config.env
  bash plugins/second-brain/scripts/run-nightly-journal.sh --date YYYY-MM-DD
  bash plugins/second-brain/scripts/run-dream.sh
  ```
  (a working-tree run passes `--plugin-dir` itself). Pass if the log says
  `OK:` and the session transcript in `~/.claude/projects/<vault path>/`
  shows no unexpected permission denials. For launchd, run
  `install-scheduled-jobs.sh` with that `SECOND_BRAIN_CONFIG` set (the plist
  carries it), `launchctl kickstart gui/$(id -u)/com.second-brain.nightly-journal`,
  then `--uninstall`. On a machine that runs a real second brain, also check
  that its vault, its state file and its own jobs didn't change.
