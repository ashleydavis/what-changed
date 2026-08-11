#!/usr/bin/env bash

# Runs the test suite only when something it watches has changed.
#
# This is the whole point of what-changed, in the smallest form that still shows it: ask what is
# affected, and run only that. Recording the baseline is not done here: each target's own command
# does it as its last step, so it happens however that command was started.

set -e

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Every target with changes, one name per line. Empty means nothing to do.
TARGETS=()
while IFS= read -r LINE; do
    if [ -n "$LINE" ]; then
        TARGETS+=("$LINE")
    fi
done <<< "$(what-changed targets)"

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "Nothing has changed since the last passing run. Skipping the tests."
    exit 0
fi

# Each target's own command records its baseline as its last step, so nothing here has to remember
# to. See the "test" script in package.json.
for TARGET_NAME in "${TARGETS[@]}"; do
    echo "Running: $TARGET_NAME"
    case "$TARGET_NAME" in
        test)
            npm test
            ;;
        *)
            echo "This script does not know how to run \"$TARGET_NAME\"." >&2
            exit 1
            ;;
    esac
done
