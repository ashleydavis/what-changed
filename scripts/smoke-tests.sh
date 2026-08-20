#!/bin/bash

# What changed smoke tests
#
# Drives the real CLI as a real process and asserts on its exit codes and output. That is the part
# the unit tests cannot reach: they call run directly and see a return value or an exception,
# where this sees what the shell sees.
#
# Scenarios 1 to 7 run outside any git repository. Scenarios 8 onwards run against a throwaway
# repository created by the single `git init` documented in the banner further down. Read that banner
# before adding any git command here.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# How the CLI is invoked. By default the TypeScript source runs under bun, which is the fast loop
# while developing. With --binary it is the compiled single-file executable instead, which is what
# actually ships, so the release build gets exercised by the same scenarios rather than trusted.
RUN_CLI=("bun" "$PROJECT_DIR/src/cli.ts")
CLI_DESCRIPTION="source under bun"

if [ "$1" = "--binary" ]; then
    # Which build to drive, from the platform this is running on. The layout is the one
    # `zig build release` produces.
    #
    # Windows is picked out by the OS variable it sets, rather than by uname, which reports the
    # name of whichever shell is emulating a POSIX system rather than the system underneath.
    if [ "${OS:-}" = "Windows_NT" ]; then
        BINARY_PATH="$PROJECT_DIR/bin/x64/win/what-changed.exe"
    elif [ "$(uname -s)" = "Darwin" ]; then
        if [ "$(uname -m)" = "arm64" ]; then
            BINARY_PATH="$PROJECT_DIR/bin/arm64/mac/what-changed"
        else
            BINARY_PATH="$PROJECT_DIR/bin/x64/mac/what-changed"
        fi
    else
        BINARY_PATH="$PROJECT_DIR/bin/x64/linux/what-changed"
    fi
    if [ ! -x "$BINARY_PATH" ]; then
        echo "No executable at $BINARY_PATH. Build it first with 'zig build release'."
        exit 1
    fi
    RUN_CLI=("$BINARY_PATH")
    CLI_DESCRIPTION="compiled executable at $BINARY_PATH"
fi

# A throwaway directory well away from any checkout. Deliberately not a git repository.
WORK_DIR="$(mktemp -d)"
OUTPUT_FILE="$WORK_DIR/cli-output.txt"

# The exit code of the most recent CLI run.
LAST_EXIT=0

# Counts of the checks that passed and failed, so every failure is reported rather than only the first.
PASS_COUNT=0
FAIL_COUNT=0

echo -e "${BLUE}=== What Changed Smoke Tests ===${NC}"
echo -e "${BLUE}Driving the $CLI_DESCRIPTION${NC}"
echo ""

# Announces a scenario, so the checks below it read as a group.
scenario() {
    echo -e "${YELLOW}$1${NC}"
}

# Records a passing check.
pass() {
    echo -e "  ${GREEN}PASS${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

# Records a failing check, printing the CLI's output so the failure can be read without a re-run.
fail() {
    echo -e "  ${RED}FAIL${NC} $1"
    echo "    --- CLI output ---"
    sed 's/^/    /' "$OUTPUT_FILE" || true
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Runs the CLI from the throwaway directory, capturing its exit code and its output.
run_cli() {
    set +e
    (cd "$WORK_DIR" && "${RUN_CLI[@]}" "$@") > "$OUTPUT_FILE" 2>&1
    LAST_EXIT=$?
    set -e
}

# Asserts the CLI exited with the expected code.
assert_exit() {
    local expected="$1"
    if [ "$LAST_EXIT" = "$expected" ]; then
        pass "exit code $expected"
    else
        fail "expected exit code $expected, got $LAST_EXIT"
    fi
}

# Asserts the CLI exited with any non-zero code.
assert_failed() {
    if [ "$LAST_EXIT" != "0" ]; then
        pass "exited non-zero ($LAST_EXIT)"
    else
        fail "expected a non-zero exit, got 0"
    fi
}

# Asserts the CLI's output contains the given text.
assert_output_contains() {
    local expected="$1"
    # The -- matters: the expected text is often an option name like "--files", which grep would
    # otherwise try to interpret as one of its own flags.
    if grep -qF -- "$expected" "$OUTPUT_FILE"; then
        pass "output mentions \"$expected\""
    else
        fail "expected the output to mention \"$expected\""
    fi
}

# Asserts the CLI printed something.
assert_output_not_empty() {
    if [ -s "$OUTPUT_FILE" ]; then
        pass "output is not empty"
    else
        fail "expected some output, got nothing"
    fi
}

# Asserts the CLI's output does NOT contain the given text.
assert_output_lacks() {
    local unexpected="$1"
    if grep -qF -- "$unexpected" "$OUTPUT_FILE"; then
        fail "expected the output NOT to mention \"$unexpected\""
    else
        pass "output does not mention \"$unexpected\""
    fi
}

# Writes a valid YAML config into the throwaway directory.
write_config() {
    cat > "$WORK_DIR/what-changed.yaml" <<'CONFIG'
targets:
  - name: alpha
    paths:
      - dir-a
CONFIG
}

scenario "1. --help prints the usage text and lists the subcommands"
run_cli --help
assert_exit 0
assert_output_contains "summary"
assert_output_contains "changes"
assert_output_contains "targets"
assert_output_contains "baseline"
assert_output_contains "cache"

scenario "1b. With no subcommand it prints the usage text rather than doing anything"
run_cli
assert_exit 0
assert_output_contains "Usage: what-changed"
assert_output_contains "summary"
assert_output_lacks "Changed since the baseline"

scenario "2. An unknown option fails, names it, and exits non-zero"
run_cli --nosuchoption
assert_failed
assert_output_contains "--nosuchoption"

scenario "3. --config with no value fails"
run_cli summary --config
assert_failed
assert_output_contains "option '--config <path>' argument missing"

scenario "3b. --config on a subcommand actually reaches it"
#
# Regression guard. --config was once declared on the program as well as on each subcommand, and
# commander resolved it to the program's copy, where nothing read it. The flag was accepted, silently
# ignored, and the default config used instead.
#
run_cli summary --config definitely-not-here.yaml
assert_failed
assert_output_contains "definitely-not-here.yaml"

scenario "4. No config file at all fails and lists every name it looked for"
run_cli summary
assert_exit 1
assert_output_contains "what-changed.yaml"
assert_output_contains "what-changed.yml"
assert_output_contains "what-changed.json"

scenario "5. A malformed YAML config fails rather than falling back to a default"
printf 'targets:\n  - name: alpha\n   paths: [bad indent]\n' > "$WORK_DIR/what-changed.yaml"
run_cli summary
assert_failed
assert_output_contains "not valid YAML"

scenario "6. A malformed JSON config names JSON, not YAML"
rm -f "$WORK_DIR/what-changed.yaml"
echo "{ not json" > "$WORK_DIR/what-changed.json"
run_cli summary
assert_failed
assert_output_contains "not valid JSON"

scenario "7. A config with a bad field fails and names the field"
rm -f "$WORK_DIR/what-changed.json"
echo 'targets: []' > "$WORK_DIR/what-changed.yaml"
run_cli summary
assert_failed
assert_output_contains "targets"

scenario "8. A TOML config is refused rather than parsed"
rm -f "$WORK_DIR/what-changed.yaml"
printf '[[targets]]\nname = "alpha"\npaths = ["dir-a"]\n' > "$WORK_DIR/what-changed.toml"
run_cli summary --config what-changed.toml
assert_failed
assert_output_contains "unrecognised extension"

scenario "9. An unrecognised config extension is refused rather than guessed at"
rm -f "$WORK_DIR/what-changed.toml"
write_config
echo 'targets: []' > "$WORK_DIR/what-changed.conf"
run_cli summary --config what-changed.conf
assert_failed
assert_output_contains "unrecognised extension"

scenario "10. Running outside a git repository fails and names git"
write_config
run_cli summary
assert_failed
assert_output_contains "git ls-files failed"

####################################################################################################
#
# Reporting changes, against a real git repository.
#
# READ THIS BEFORE EDITING ANYTHING BELOW.
#
# `git init` on the line marked below is the ONLY git command in this entire file that changes any
# state. There is no `git add`, no `git commit`, no `git config`, no `git checkout`, and none may
# ever be added. An earlier version of this script ran `git init` and `git add -A` in a directory it
# believed was a throwaway, those commands landed on the real repository instead, and its branch
# pointer and index were overwritten with the test's fixture.
#
# None of the rest is needed, because the tool enumerates with
# `git ls-files --cached --others --exclude-standard`. `--others` lists untracked files, so a
# repository with zero commits and nothing staged already gives the tool everything it reads. Files
# are created by plain writes and are never staged.
#
# Three things make the one remaining command safe, and they are not a guard-if bolted on the front:
#
# 1. REPO_DIR comes from `mktemp -d`, so it is an absolute path inside the system temporary
#    directory. It is never computed from the script's own location, which is how the path went
#    wrong last time. `pwd -P` resolves symlinks up front so the check in 3 cannot fail spuriously
#    on macOS, where mktemp returns a path under a symlinked /var.
# 2. `git init` is run with GIT_DIR and GIT_WORK_TREE both set explicitly. With both set, git uses
#    exactly those paths and does NOT search upward for an enclosing repository. That upward search
#    is the mechanism by which the command escaped into the real repository before, and setting
#    these turns it off rather than hoping it does not trigger.
# 3. The script then asks git where it actually is and refuses to run a single check unless the
#    answer is REPO_DIR.
#
# Everything after that point runs the CLI, which only ever calls `git ls-files`: read-only.
#
####################################################################################################

# An absolute path in the system temporary directory, with symlinks already resolved.
REPO_DIR="$(cd "$(mktemp -d)" && pwd -P)"

# vvv THE ONLY STATE-CHANGING GIT COMMAND IN THIS FILE vvv
GIT_DIR="$REPO_DIR/.git" GIT_WORK_TREE="$REPO_DIR" git init --quiet
# ^^^ THE ONLY STATE-CHANGING GIT COMMAND IN THIS FILE ^^^

# Refuse to go any further unless git agrees that the repository is the throwaway one.
ACTUAL_TOPLEVEL="$(cd "$REPO_DIR" && git rev-parse --show-toplevel)"

# On Windows git answers with a Windows path (C:/Users/...) while mktemp and pwd give the POSIX form
# (/c/Users/...). Both name the same directory, so the check below has to compare them in one form
# or the other or it refuses a repository that is exactly where it should be. cygpath does that
# conversion and ships with Git for Windows; it does not exist elsewhere, so this is skipped there.
if command -v cygpath >/dev/null 2>&1; then
    ACTUAL_TOPLEVEL="$(cygpath -u "$ACTUAL_TOPLEVEL")"
fi

if [ "$ACTUAL_TOPLEVEL" != "$REPO_DIR" ]; then
    echo -e "${RED}ABORTING: expected the repository at $REPO_DIR but git reports $ACTUAL_TOPLEVEL.${NC}"
    echo -e "${RED}Refusing to run any check rather than risk touching a real repository.${NC}"
    exit 1
fi

# Runs the CLI from the throwaway repository, capturing its exit code and its output.
run_repo_cli() {
    set +e
    (cd "$REPO_DIR" && "${RUN_CLI[@]}" "$@") > "$OUTPUT_FILE" 2>&1
    LAST_EXIT=$?
    set -e
}

echo ""
echo -e "${BLUE}=== Against a real git repository ===${NC}"
echo ""

cat > "$REPO_DIR/what-changed.yaml" <<'CONFIG'
ignore:
  - .md

targets:
  - name: unit
    paths:
      - src

  - name: documentation
    paths:
      - documentation
CONFIG

# The cache must be invisible to the file listing, or every run would see its own last run as a
# change. This is the .gitignore the README tells users to write.
cat > "$REPO_DIR/.gitignore" <<'IGNORE'
.what-changed/
IGNORE

mkdir -p "$REPO_DIR/src" "$REPO_DIR/documentation"
echo "original source" > "$REPO_DIR/src/a.ts"
echo "original docs" > "$REPO_DIR/documentation/guide.txt"
echo "notes" > "$REPO_DIR/src/notes.md"

scenario "11. With no baseline it says so and points at the baseline command"
run_repo_cli summary
assert_exit 0
assert_output_contains "No baseline recorded yet, so every file counts as new"
#
# The note explains the listing, it does not replace it. With no baseline every file really has
# changed as far as this tool is concerned, so the files are still reported.
#
assert_output_contains "src/a.ts"
assert_output_contains "unit:"

scenario "12. targets with no baseline names every target"
run_repo_cli targets
assert_exit 0
assert_output_contains "unit"
assert_output_contains "documentation"

scenario "13. baseline capture records the current tree"
run_repo_cli baseline capture
assert_exit 0
assert_output_contains "Captured the baseline for"

scenario "14. Immediately after the baseline nothing has changed"
run_repo_cli summary
assert_exit 0
assert_output_contains "No files have changed since the baseline"

scenario "15. targets prints nothing when nothing has changed"
run_repo_cli targets
assert_exit 0
assert_output_lacks "unit"

scenario "16. An edit is reported under the target that watches it, and not under the other"
echo "edited source" > "$REPO_DIR/src/a.ts"
run_repo_cli summary
assert_exit 0
assert_output_contains "unit: 1 changed"
assert_output_contains "documentation: unchanged"
assert_output_contains "src/a.ts"

scenario "17. targets names only the affected target"
run_repo_cli targets
assert_exit 0
assert_output_contains "unit"
assert_output_lacks "documentation"

scenario "18. changes lists the changed file without grouping it"
run_repo_cli changes
assert_exit 0
assert_output_contains "Changed since the baseline:"
assert_output_contains "src/a.ts"
assert_output_lacks "unit:"

scenario "19. Reporting is not destructive: a second look reports the same change"
run_repo_cli summary
assert_exit 0
assert_output_contains "src/a.ts"

scenario "20. An added file is reported under its target"
echo "brand new" > "$REPO_DIR/src/b.ts"
run_repo_cli summary
assert_exit 0
assert_output_contains "src/b.ts"

scenario "21. An ignored extension is never reported"
echo "edited notes" > "$REPO_DIR/src/notes.md"
run_repo_cli summary
assert_exit 0
assert_output_lacks "notes.md"

scenario "22. A changed file no target watches is called out separately"
mkdir -p "$REPO_DIR/stray"
echo "stray" > "$REPO_DIR/stray/thing.ts"
run_repo_cli summary
assert_exit 0
assert_output_contains "Watched by no target"
assert_output_contains "stray/thing.ts"

scenario "23. --output json renders the same change as machine-readable data"
run_repo_cli changes --output json
assert_exit 0
assert_output_contains "\"changed\""
assert_output_contains "src/a.ts"
assert_output_lacks "Changed since the baseline:"

scenario "24. --output yaml renders the same thing again"
run_repo_cli changes --output yaml
assert_exit 0
assert_output_contains "changed:"
assert_output_contains "src/a.ts"
assert_output_lacks "Changed since the baseline:"

scenario "25. --output json on targets is a list a parser can read"
run_repo_cli targets --output json
assert_exit 0
assert_output_contains "\"targets\""
assert_output_contains "unit"

scenario "26. An unknown --output format is refused and names the accepted ones"
run_repo_cli changes --output xml
assert_failed
assert_output_contains "Unknown --output format"
assert_output_contains "text, json, yaml"

scenario "27. A fresh baseline capture clears everything back to unchanged"
run_repo_cli baseline capture
assert_exit 0
run_repo_cli summary
assert_exit 0
assert_output_contains "No files have changed since the baseline"

scenario "27b. Capturing one target leaves every other target still affected"
#
# The rule the per-target baseline exists for. Capturing "unit" after the unit suite passed must not
# mark "documentation" as up to date, because that suite never ran.
#
echo "changed for both" > "$REPO_DIR/src/a.ts"
echo "changed for both" > "$REPO_DIR/documentation/guide.txt"
run_repo_cli baseline capture unit
assert_exit 0
assert_output_contains "unit"
assert_output_lacks "documentation"
run_repo_cli targets
assert_exit 0
assert_output_contains "documentation"
assert_output_lacks "unit"

scenario "27c. Capturing an unknown target name is refused"
run_repo_cli baseline capture nosuchtarget
assert_failed
assert_output_contains "nosuchtarget"

# The version is written into src/lib/version.ts by the release workflow, so the string differs
# between a working copy ("dev") and a release build ("0.0.1"). These assert only that the plumbing
# reaches the output. Asserting the value would fail on exactly the builds that ship.
scenario "28. --version and -v print the version and exit cleanly"
run_cli --version
assert_exit 0
assert_output_not_empty
run_cli -v
assert_exit 0
assert_output_not_empty

scenario "29. The version subcommand says which build this is"
run_cli version
assert_exit 0
assert_output_contains "what-changed"

scenario "30. version --output json is a list a parser can read"
run_cli version --output json
assert_exit 0
assert_output_contains "\"version\""
assert_output_contains "\"commitHash\""

# Platform filtering, against the real CLI reading process.platform.
#
# One target names this machine's platform and one names a platform this machine is not, so the same
# config exercises both sides of the check wherever the suite runs. Naming a fixed platform would
# make these pass for the wrong reason on some machines and fail on others.
case "$(uname -s)" in
    Linux)  HOST_PLATFORM="linux";  OTHER_PLATFORM="darwin" ;;
    Darwin) HOST_PLATFORM="darwin"; OTHER_PLATFORM="linux"  ;;
    *)      HOST_PLATFORM="win32";  OTHER_PLATFORM="linux"  ;;
esac

cat > "$REPO_DIR/what-changed.yaml" <<CONFIG
ignore:
  - .md

targets:
  - name: unit
    paths:
      - src

  - name: here-only
    paths:
      - src
    platforms:
      - $HOST_PLATFORM

  - name: elsewhere-only
    paths:
      - src
    platforms:
      - $OTHER_PLATFORM
CONFIG

scenario "31. A target for another platform is never named as affected"
run_repo_cli baseline capture
assert_exit 0
echo "changed again" > "$REPO_DIR/src/a.ts"
run_repo_cli targets
assert_exit 0
assert_output_contains "unit"
assert_output_contains "here-only"
assert_output_lacks "elsewhere-only"

scenario "32. summary says wrong-platform rather than unchanged"
run_repo_cli summary
assert_exit 0
assert_output_contains "elsewhere-only: wrong-platform"
assert_output_lacks "elsewhere-only: unchanged"

scenario "33. A file a wrong-platform target watches is not called watched by no target"
assert_output_lacks "Watched by no target"

scenario "34. json output records whether each target applies here"
run_repo_cli summary --output json
assert_exit 0
assert_output_contains "\"appliesHere\": false"
assert_output_contains "\"appliesHere\": true"

scenario "35. targets list names every runnable target and still excludes the wrong platform"
run_repo_cli targets list
assert_exit 0
assert_output_contains "unit"
assert_output_contains "here-only"
assert_output_lacks "elsewhere-only"

scenario "36. targets list names them whatever has changed, where targets names none"
run_repo_cli baseline capture
assert_exit 0
run_repo_cli targets
assert_exit 0
assert_output_lacks "unit"
run_repo_cli targets list
assert_exit 0
assert_output_contains "unit"

scenario "37. targets list honours --output on the subcommand rather than the parent"
#
# Regression guard. "targets" declares --output and so does "targets list". Without positional
# options commander resolves the flag to the parent's copy, where the subcommand never reads it, and
# the request for json quietly returns text.
#
run_repo_cli targets list --output json
assert_exit 0
assert_output_contains "\"targets\""
assert_output_contains "unit"

####################################################################################################
#
# Parallel captures.
#
# This is how the tool is really driven: a build script runs its suites at once and has each one
# capture its own target the moment it passes, so a dozen captures land within the same second. Both
# ways that used to go wrong are invisible to a single-process test.
#
# The first was loud. Every writer built its temp file from the destination name alone, so they all
# picked the same one; the first rename moved it away and the next found nothing there and died with
# ENOENT, failing a build whose tests had all passed.
#
# The second was silent, and worse for it. Each capture read the baseline, added its own target and
# wrote the whole thing back, so a capture that read before another wrote erased that other's
# target. Nothing failed. The target simply had no record, so it ran again next time for no reason.
#
####################################################################################################

scenario "38. Captures running at the same time all survive, none crashing and none lost"

PARALLEL_TARGETS="p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 p11 p12"

{
    echo "targets:"
    for parallel_target in $PARALLEL_TARGETS; do
        echo "  - name: $parallel_target"
        echo "    paths:"
        echo "      - src"
    done
} > "$REPO_DIR/what-changed.yaml"

run_repo_cli baseline reset
assert_exit 0

# Each capture is its own process, started without waiting, so they genuinely overlap. Their exit
# codes are collected through the filesystem because a backgrounded subshell cannot report back.
PARALLEL_DIR="$WORK_DIR/parallel"
mkdir -p "$PARALLEL_DIR"
for parallel_target in $PARALLEL_TARGETS; do
    (
        # set +e inside the subshell, or a capture that exits non-zero kills the subshell before it
        # can record why, and the failure reads as a missing file rather than as the crash it was.
        set +e
        cd "$REPO_DIR" && "${RUN_CLI[@]}" baseline capture "$parallel_target" > "$PARALLEL_DIR/$parallel_target.log" 2>&1
        echo "$?" > "$PARALLEL_DIR/$parallel_target.exit"
    ) &
done
wait

# Every one of them has to have succeeded. A crash here is the ENOENT coming back.
PARALLEL_FAILED=""
for parallel_target in $PARALLEL_TARGETS; do
    if [ ! -f "$PARALLEL_DIR/$parallel_target.exit" ] || [ "$(cat "$PARALLEL_DIR/$parallel_target.exit")" != "0" ]; then
        PARALLEL_FAILED="$PARALLEL_FAILED $parallel_target"
    fi
done
if [ -n "$PARALLEL_FAILED" ]; then
    cat "$PARALLEL_DIR"/*.log > "$OUTPUT_FILE"
    fail "these captures exited non-zero:$PARALLEL_FAILED"
else
    pass "all 12 concurrent captures exited 0"
fi

# And every one of them has to be in the baseline. A missing name is the silent loss coming back.
run_repo_cli baseline show
assert_exit 0
assert_output_contains "12 target(s) captured:"
for parallel_target in $PARALLEL_TARGETS; do
    assert_output_contains "$parallel_target:"
done

# With every target captured, nothing is left to do. This is what the loss used to break: a target
# whose record had been erased still counted as changed and ran again for nothing.
run_repo_cli targets
assert_exit 0
for parallel_target in $PARALLEL_TARGETS; do
    assert_output_lacks "$parallel_target"
done

scenario "39. A file that cannot be read says why, rather than only that it could not be read"

# chmod is the only way to make a real file unreadable, and it does nothing to root, so this one
# scenario is skipped there rather than failing for a reason that has nothing to do with the tool.
if [ "$(id -u)" = "0" ]; then
    echo -e "  ${YELLOW}SKIP${NC} running as root, where chmod cannot make a file unreadable"
else
    {
        echo "targets:"
        echo "  - name: unit"
        echo "    paths:"
        echo "      - src"
    } > "$REPO_DIR/what-changed.yaml"

    echo "locked" > "$REPO_DIR/src/locked.ts"
    chmod 000 "$REPO_DIR/src/locked.ts"

    run_repo_cli changes
    assert_exit 0
    assert_output_contains "src/locked.ts"
    assert_output_contains "permission denied"

    run_repo_cli changes --output json
    assert_exit 0
    assert_output_contains "\"reason\""
    assert_output_contains "permission denied"

    chmod 644 "$REPO_DIR/src/locked.ts"
    rm -f "$REPO_DIR/src/locked.ts"
fi

echo ""
echo -e "${BLUE}Throwaway directories left at $WORK_DIR and $REPO_DIR${NC}"

echo ""
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}FAIL: $FAIL_COUNT check(s) failed, $PASS_COUNT passed${NC}"
    exit 1
fi

echo -e "${GREEN}PASS: all $PASS_COUNT checks passed${NC}"
