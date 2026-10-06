#!/bin/bash
# adopt-dream.sh — adopt (merge) or discard a dream branch.
#
# A dream runs on an isolated branch + worktree (under SECOND_BRAIN_DREAM_DIR);
# the live vault stays on `main`.
# This script is the explicit adoption gate.
#
# Usage:
#   adopt-dream.sh <YYYY-Wxx>            # ADOPT: merge dream/<YYYY-Wxx> into main, clean up
#   adopt-dream.sh <YYYY-Wxx> --discard  # DISCARD: delete branch + worktree, main untouched
#
# The vault comes from this machine's second-brain config (SECOND_BRAIN_VAULT).
set -euo pipefail

. "$(dirname "$0")/config.sh"

WEEK="${1:?usage: adopt-dream.sh <YYYY-Wxx> [--discard]}"
MODE="${2:-adopt}"
VAULT="${SECOND_BRAIN_VAULT:?no vault configured; run /second-brain:setup}"
BRANCH="dream/${WEEK}"
VAULT="${VAULT%/}"
DREAM_DIR="${SECOND_BRAIN_DREAM_DIR:-$HOME/.claude/second-brain/dream-worktrees}"

cd "$VAULT"

if ! git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  echo "No branch '$BRANCH' in $VAULT — nothing to do." >&2
  exit 1
fi

# Ask git where the branch is checked out, whatever the folder was named.
# Fall back to the usual locations: the dream folder, then (plugin 0.2.0 and
# earlier) a sibling of the vault.
WORKTREE="$(git worktree list --porcelain | awk -v b="branch refs/heads/$BRANCH" '
  /^worktree /{w=substr($0, 10)} $0==b && !found {print w; found=1}')"
[ -n "$WORKTREE" ] || WORKTREE="${DREAM_DIR%/}/$(basename "$VAULT")-${WEEK}"
[ -d "$WORKTREE" ] || WORKTREE="$(dirname "$VAULT")/$(basename "$VAULT")-dream-${WEEK}"

# Remove the worktree first (a branch checked out in a worktree can't be merged/deleted cleanly).
git worktree remove --force "$WORKTREE" 2>/dev/null || true

if [ "$MODE" = "--discard" ]; then
  git branch -D "$BRANCH"
  echo "Discarded $BRANCH. Live vault (main) untouched."
  exit 0
fi

# ADOPT: the live vault working tree is already on `main`.
git merge --no-ff "$BRANCH" -m "Adopt dream ${WEEK}"
git branch -d "$BRANCH" 2>/dev/null || git branch -D "$BRANCH"
echo "Adopted dream ${WEEK} into main. Worktree + branch cleaned up."
echo "Obsidian now reflects the consolidated store. Recover anything via: git log / git revert."
