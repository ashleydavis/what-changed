#!/usr/bin/env bash
# Points git at this project's checked-in hooks, once per clone.
#
# Git does not use a checked-in hooks directory on its own: it only ever runs what is in the clone's
# own hooks directory, which is not version controlled. Setting core.hooksPath is what makes
# .githooks live, and it is per-clone configuration, so everyone who clones has to run this once.
# Nothing runs it automatically.
#
# The path is set relative, not absolute, so it resolves against whichever working tree git is
# running in. That is what makes the hooks work in a git worktree as well as the main clone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

if [ ! -d .githooks ]; then
    echo "ERROR: no .githooks directory in $PROJECT_DIR. Run this from a checkout of the project." >&2
    exit 1
fi

git config core.hooksPath .githooks

echo "Hooks installed: core.hooksPath = $(git config --get core.hooksPath)"
echo "  pre-commit: ./scripts/test-everything.sh (only the targets whose watched paths changed)"
echo "Bypass a single git command with --no-verify."
