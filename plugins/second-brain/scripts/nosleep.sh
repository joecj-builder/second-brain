#!/bin/bash
# nosleep.sh — keep the Mac awake on lid close ONLY while Claude Code is working.
#
# Wired to Claude Code hooks:
#   UserPromptSubmit -> acquire   (you hit enter; work begins -> stay awake)
#   Stop             -> release   (Claude finished its turn; waiting on you -> allow sleep)
#   SessionEnd       -> release   (exit / Ctrl-C / crash cleanup)
#   SessionStart     -> sweep     (clear this session's stale lock on entry)
#
# Mechanism: only `pmset disablesleep 1` defeats lid-close sleep (caffeinate can't).
# Reference-counted via one lock file per session_id so concurrent sessions don't
# prematurely re-enable sleep. Requires a narrowly-scoped passwordless sudoers rule:
#   <your-username> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep *
# If that rule is missing, this degrades gracefully (logs a failure, never prompts).
#
# Off unless SECOND_BRAIN_KEEP_AWAKE=true in the second-brain config.

set -u

. "$(dirname "$0")/config.sh"
if [ "${SECOND_BRAIN_KEEP_AWAKE:-false}" != true ] || [ "$(uname)" != Darwin ]; then
  cat >/dev/null 2>&1
  exit 0
fi

ACTION="${1:-}"
LOCK_DIR="$HOME/.claude/nosleep-locks"
STALE_MIN=30          # safety valve: locks older than this are swept (orphaned crashes)
LOG="$HOME/.claude/nosleep.log"

mkdir -p "$LOCK_DIR"

# --- best-effort session_id from the hook JSON on stdin ---
payload="$(cat 2>/dev/null || true)"
sid="$(printf '%s' "$payload" \
  | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -1 \
  | sed -E 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
[ -z "$sid" ] && sid="default"
sid="$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')"   # sanitize for filename

ensure_state() {
  # drop orphaned locks first
  find "$LOCK_DIR" -type f -mmin +"$STALE_MIN" -delete 2>/dev/null || true

  local want cur
  if [ -n "$(ls -A "$LOCK_DIR" 2>/dev/null)" ]; then want=1; else want=0; fi

  cur="$(pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2}')"
  [ -z "$cur" ] && cur=0

  if [ "$cur" != "$want" ]; then
    if sudo -n /usr/bin/pmset -a disablesleep "$want" 2>>"$LOG"; then
      printf '%s  disablesleep=%s  active=[%s]\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$want" \
        "$(ls -A "$LOCK_DIR" 2>/dev/null | tr '\n' ' ')" >>"$LOG"
    else
      printf '%s  FAILED disablesleep=%s (missing sudoers rule?)\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$want" >>"$LOG"
    fi
  fi
}

case "$ACTION" in
  acquire) : > "$LOCK_DIR/$sid"; ensure_state ;;
  release) rm -f "$LOCK_DIR/$sid"; ensure_state ;;
  sweep)   rm -f "$LOCK_DIR/$sid"; ensure_state ;;
  *) echo "usage: $0 {acquire|release|sweep}" >&2; exit 2 ;;
esac

exit 0
