#!/bin/bash

# Runs only the test targets whose watched paths have changed.
#
# what-changed decides, this runs. The two jobs are deliberately separate: what-changed reports and
# records, it never spawns anything, so there is exactly one place (this file) that knows how to turn
# a target name into a command.
#
# The flow:
#   1. Ask what-changed which targets have changes, via `targets`, which prints one name per line.
#   2. Run those, in the order they appear in what-changed.yaml.
#   3. Record each target's baseline, but only as that target passes.
#
# Step 3 is the part that matters. Recording after a failure would mark a broken tree as tested, and
# the next run would report nothing to do.
#
# Options:
#   --force     Run every target regardless of what changed.
#   --plan      Print which targets would run, and run nothing.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

FORCE=false
PLAN_ONLY=false

for ARGUMENT in "$@"; do
    case "$ARGUMENT" in
        --force)
            FORCE=true
            ;;
        --plan)
            PLAN_ONLY=true
            ;;
        *)
            echo "Unknown option \"$ARGUMENT\". Known options: --force, --plan."
            exit 1
            ;;
    esac
done

# Goes through mise when it is available, so the pinned Zig version is used rather than whatever
# happens to be first on PATH.
zig_run() {
    if command -v mise >/dev/null 2>&1; then
        mise exec -- zig "$@"
    else
        zig "$@"
    fi
}

# The binary the smoke tests drive and this script asks. Rebuilt from the working tree every time,
# so this always reflects the code in front of you rather than whatever was last built. That matters
# most here: this script is how the project tests itself.
BINARY="$PROJECT_DIR/bin/x64/linux/what-changed"
case "$(uname -s)" in
    Darwin)
        if [ "$(uname -m)" = "arm64" ]; then
            BINARY="$PROJECT_DIR/bin/arm64/mac/what-changed"
        else
            BINARY="$PROJECT_DIR/bin/x64/mac/what-changed"
        fi
        ;;
esac

echo -e "${BLUE}=== Building what-changed ===${NC}"
zig_run build release

what_changed() {
    "$BINARY" "$@"
}

# Runs one named target.
run_target() {
    local name="$1"
    echo ""
    echo -e "${BLUE}=== $name ===${NC}"
    case "$name" in
        compile)
            zig_run build
            ;;
        test)
            zig_run build test
            ;;
        smoke)
            ./scripts/smoke-tests.sh --binary
            ;;
        perf)
            zig_run build perf
            ;;
        *)
            echo -e "${RED}Target \"$name\" is in what-changed.yaml but this script does not know how to run it.${NC}"
            echo -e "${RED}Add it to the case statement in scripts/test-everything.sh.${NC}"
            exit 1
            ;;
    esac
}

if [ "$FORCE" = true ]; then
    # "targets list" is every target the config declares that can run on this machine. Asking rather
    # than keeping a list here is what stops --force from running a target whose toolchain this
    # platform does not have.
    TARGETS=()
    while IFS= read -r LINE; do
        if [ -n "$LINE" ]; then
            TARGETS+=("$LINE")
        fi
    done <<< "$(what_changed targets list)"
    echo -e "${YELLOW}--force given, running every target that can run here.${NC}"
else
    # read -r with a here-string keeps this to one subshell and no temporary file. An empty list
    # leaves TARGETS empty, which is the "nothing changed" case.
    TARGETS=()
    while IFS= read -r LINE; do
        if [ -n "$LINE" ]; then
            TARGETS+=("$LINE")
        fi
    done <<< "$(what_changed targets)"
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo -e "${GREEN}Nothing to run: nothing has changed since the last baseline.${NC}"
    echo "Use --force to run everything anyway."
    exit 0
fi

echo -e "${YELLOW}Targets to run: ${TARGETS[*]}${NC}"

if [ "$PLAN_ONLY" = true ]; then
    echo "--plan given, running nothing."
    exit 0
fi

#
# Each target is captured as soon as it passes, and only that target. A bare `baseline capture` here
# would capture every target in the config, including the ones this run never touched, which would
# mark them as up to date without them having run.
#
# set -e means a failing target ends the script before its own capture, so a target is only ever
# marked from the run that actually passed it.
#
for TARGET_NAME in "${TARGETS[@]}"; do
    run_target "$TARGET_NAME"
    what_changed baseline capture "$TARGET_NAME"
done


echo ""
echo -e "${GREEN}All targets passed: ${TARGETS[*]}${NC}"
