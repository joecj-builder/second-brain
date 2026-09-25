#!/bin/bash
# SessionEnd hook — run /second-brain:document on the session that just closed.
#
# The closing session can't take another turn, so this starts a separate,
# detached headless run that resumes it by ID. The hook returns immediately;
# the run's output goes to ~/.claude/second-brain/auto-document.log.
#
# Skips when:
#   - this is itself an auto-document run (recursion guard)
#   - SECOND_BRAIN_AUTODOC=false, or no vault is configured
#   - fewer than SECOND_BRAIN_AUTODOC_MIN_PROMPTS prompts since the session
#     started, or since /document last ran in it

[ "${SECOND_BRAIN_AUTODOC_RUN:-}" = 1 ] && exit 0

. "$(dirname "$0")/config.sh"
[ "${SECOND_BRAIN_AUTODOC:-true}" = true ] || exit 0
vault="${SECOND_BRAIN_VAULT:-}"
[ -n "$vault" ] && [ -d "$vault" ] || exit 0

payload="$(cat)"
fields="$(printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("session_id", ""))
print(d.get("transcript_path", ""))
print(d.get("cwd", ""))
' 2>/dev/null)" || exit 0
sid="$(sed -n 1p <<<"$fields")"
transcript="$(sed -n 2p <<<"$fields")"
cwd="$(sed -n 3p <<<"$fields")"
[ -n "$sid" ] && [ -f "$transcript" ] && [ -d "$cwd" ] || exit 0

min="${SECOND_BRAIN_AUTODOC_MIN_PROMPTS:-3}"
# Count the user's prompts since the last /document in this session.
since="$(python3 - "$transcript" <<'PY'
import json, re, sys

# A typed /document or a Skill tool call. Only real invocations count; the
# transcript also records the skill listing, which names every skill.
TYPED = re.compile(r"<command-name>/(second-brain:)?document</command-name>")
SKILLS = {"document", "second-brain:document"}

count = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    kind = entry.get("type")
    content = entry.get("message", {}).get("content")
    if kind == "assistant" and isinstance(content, list):
        if any(c.get("type") == "tool_use" and c.get("name") == "Skill"
               and c.get("input", {}).get("skill") in SKILLS
               for c in content if isinstance(c, dict)):
            count = 0
        continue
    if kind != "user" or entry.get("isMeta"):
        continue
    if isinstance(content, list):
        texts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
        content = texts[0] if texts else None
    if not isinstance(content, str) or not content.strip():
        continue
    if TYPED.search(content):
        count = 0
        continue
    if content.lstrip().startswith(("<local-command", "<system-reminder>", "<task-notification>")):
        continue
    count += 1
print(count)
PY
)"
[ "${since:-0}" -ge "$min" ] 2>/dev/null || exit 0

claude_bin="$(command -v claude || echo "$HOME/.local/bin/claude")"
[ -x "$claude_bin" ] || exit 0

# Installed plugins load on their own. A --plugin-dir plugin (development)
# has to be passed through to the headless run.
plugin_args=()
case "$CLAUDE_PLUGIN_ROOT" in
  "$HOME/.claude/plugins/"*) ;;
  *) plugin_args=(--plugin-dir "$CLAUDE_PLUGIN_ROOT") ;;
esac

logdir="$HOME/.claude/second-brain"
mkdir -p "$logdir"
log="$logdir/auto-document.log"
printf '\n=== %s  session %s  (%s prompts)  cwd %s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$sid" "$since" "$cwd" >> "$log"

cd "$cwd" || exit 0
SECOND_BRAIN_AUTODOC_RUN=1 nohup "$claude_bin" -p --resume "$sid" \
  "${plugin_args[@]}" \
  --add-dir "$vault" \
  --permission-mode acceptEdits \
  --allowedTools "Read,Glob,Grep,Edit,Write,Bash(git:*),Bash(ls:*),Bash(date:*),Bash(mkdir:*)" \
  <<< "/second-brain:document --auto --session $sid" \
  >> "$log" 2>&1 &
disown
exit 0
