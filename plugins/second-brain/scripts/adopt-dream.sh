#!/bin/bash
# adopt-dream.sh — adopt (merge) or discard a dream branch.
#
# A dream runs on an isolated branch + worktree; the live vault stays on `main`.
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
WORKTREE="$(dirname "$VAULT")/$(basename "$VAULT")-dream-${WEEK}"

cd "$VAULT"

if ! git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  echo "No branch '$BRANCH' in $VAULT — nothing to do." >&2
  exit 1
fi

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
