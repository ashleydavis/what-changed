# what-changed: quick reference for AI agents

`what-changed` tells you which build/test targets need to run, based on which files changed since each target last passed. Use it to skip work that doesn't need to be done.

## Requirements

- `git` on the PATH. The project must be a git repository: file discovery is `git ls-files --cached --others --exclude-standard`, so `.gitignore` decides what is seen.
- The binary. Install with [mise](https://mise.jdx.dev/) by adding to `mise.toml`, then `mise install`:

  ```toml
  [tools]
  "github:ashleydavis/what-changed" = "0.0.6"   # pin an exact release, never "latest"
  ```

  Or download a platform archive from https://github.com/ashleydavis/what-changed/releases, extract, `chmod +x what-changed`, put it on the PATH.

## Set up a project

From the project root:

```bash
what-changed init
```

Writes `what-changed.yaml` with placeholder targets and adds `.what-changed/` to `.gitignore`. Neither is overwritten, so it is safe to re-run. Exit code is 0 either way.

Then replace the placeholder targets with the project's real ones. One target per thing you would run:

```yaml
always:          # optional: paths that fall under every target
  - package.json
  - package-lock.json

ignore:          # optional: extensions excluded entirely, leading dot, case-insensitive
  - .md
  - .txt
  - .log

targets:         # required, non-empty
  - name: compile
    paths:       # required, non-empty; repo-relative files or directories
      - src
  - name: test
    paths:
      - src
      - test
  - name: ios
    paths:
      - apps/ios
    platforms:   # optional: linux, darwin, win32. Defaults to all
      - darwin
```

Config file is `what-changed.yaml`, `.yml` or `.json`, first found wins. Paths inside it are relative to the config file's directory. Other fields: `cacheDir` (default `.what-changed/cache`), `baselinePath` (default `.what-changed/baseline.json`); both must be gitignored.

## The two operations

**Ask what to run:**

```bash
what-changed targets
```

Prints affected target names, one per line, nothing if there is nothing to run. Targets excluded by `platforms` are never printed. With no baseline recorded, every runnable target is printed.

`what-changed targets list` prints every target that can run on this machine, changed or not. Use it for a "run everything" option such as `--force`.

**Record a pass:**

```bash
what-changed baseline capture test
```

Records the files that `test` watches as its baseline, meaning "this target passed against these files". This is the only thing that moves the baseline forward. With no target names, it captures every target.

Capture one target only after that target actually passed. Chain with `&&` so a failure never captures.

Put that chain inside the target's own command, not in the script that calls it. Then the baseline is recorded however the command was started: by hand, by the script below, by a pre-commit hook, by CI. In a `package.json`:

```json
{
    "scripts": {
        "build": "tsc && what-changed baseline capture compile",
        "test": "jest && what-changed baseline capture test"
    }
}
```

## Driving it from a script

Each target's own command records its baseline, so this script only decides what to run:

```bash
set -e

run_target() {
    case "$1" in
        compile)  npm run build ;;
        test)     npm test ;;
        e2e)      npm run e2e ;;
        *)        echo "Unknown target \"$1\"." >&2; return 1 ;;
    esac
}

TARGETS=()
while IFS= read -r LINE; do
    [ -n "$LINE" ] && TARGETS+=("$LINE")
done <<< "$(what-changed targets)"

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "Nothing to do."
    exit 0
fi

for TARGET_NAME in "${TARGETS[@]}"; do
    echo "Running: $TARGET_NAME"
    run_target "$TARGET_NAME"
done
```

Working examples: [`scripts/test-everything.sh`](../scripts/test-everything.sh) and [`examples/example-project/`](../examples/example-project/).

## Running it on every commit (pre-commit hook)

The usual reason to set this up: a hook that runs the project's driver script, so tests happen before anything is committed and only the changed targets cost time. Refuse the commit when the script fails.

`.githooks/pre-commit`:

```bash
#!/usr/bin/env bash
set -uo pipefail

REPO_DIR="$(git rev-parse --show-toplevel)"

# Git exports these to hooks. Tests that run git in throwaway fixtures (init, add, commit) would
# otherwise act on this repository's index.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_PREFIX

cd "$REPO_DIR"

if ! ./scripts/test-everything.sh; then
    echo "pre-commit FAILED. Commit anyway with: git commit --no-verify" >&2
    exit 1
fi
```

Make it executable (`chmod +x`). The file must be named exactly `pre-commit`, with no extension.

Git only runs hooks from the clone's own hooks directory, which is not version controlled, so a checked-in `.githooks/` does nothing until each clone enables it. Check the hook in and add a script that every clone runs once. Two ways to enable it:

- Point git at the checked-in directory: `git config core.hooksPath .githooks` (relative, so it also works in worktrees). This changes git configuration, so an agent must not run it unless the human asked for it.
- Symlink it: `ln -sfn "$(pwd)/.githooks/pre-commit" "$(git rev-parse --git-common-dir)/hooks/pre-commit"`. No configuration changes.

Bypass one commit with `git commit --no-verify`. A change that no target watches (for example a docs-only change) runs nothing and the commit goes straight through.

Working examples: [`.githooks/pre-commit`](../.githooks/pre-commit) and [`scripts/install-hooks.sh`](../scripts/install-hooks.sh).

## The rest of the commands

Run `what-changed --help`, and `--help` on any subcommand (`what-changed baseline capture --help`). That is the tool describing itself, so it cannot be out of date.

Only `baseline capture` and `baseline reset` change what a later report says. Every other command is repeatable and gives the same answer each time.

Repeatable does not mean it writes nothing. `summary`, `changes` and `targets` each refresh the file hash cache as a side effect, so do not treat them as read-only in a sandbox or a read-only checkout. Nothing in the cache affects the answer, only how fast it arrives.

## Machine-readable output

`summary`, `changes`, `targets` and the `show` commands take `--output text|json|yaml`. `json` and `yaml` carry identical fields.

```bash
what-changed targets --output json
```

```json
{ "targets": ["compile", "test"] }
```

`changes --output json`:

```json
{
  "hasBaseline": true,
  "fileCount": 79,
  "changed": [
    { "path": "src/main.zig", "kind": "modified", "hash": "eb81...", "previousHash": "14bb...", "reason": "" }
  ]
}
```

`summary --output json` is the same, with `changed` nested inside each entry of a `targets` array, alongside `name`, `watchedPaths` and `appliesHere` (false when `platforms` excludes it here).

`kind` is `added`, `modified`, `deleted` or `unreadable`. In text output those are `A`, `M`, `D`, `U`. `reason` carries the read error for `unreadable`. An unreadable file counts as changed and keeps counting as changed until it can be read.

## Exit codes

Exit 0 means it ran and reported, whether or not anything changed. Exit 1 means the tool itself failed: bad config, unknown option, git missing or failing.

**Changes are not signalled by the exit code.** Read the target names `what-changed targets` prints. No names means nothing to run, which also happens when files changed but no target watches them.

## Gotchas

- Targets match by path, not by imports. Any change under a watched path runs that target, so it errs towards running too much.
- Changes outside the repo are invisible: installed dependencies, environment variables, credentials, SDKs. Watch the lockfile via `always` to cover dependencies.
- Never capture a baseline for a target you did not run. That marks it up to date when it is not, and the work it would have caught is silently skipped from then on.
- `.what-changed/` must be gitignored. Un-ignored, the tool lists its own output as changed on every run and every target looks affected forever.
- A file watched by no target is reported separately rather than dropped, usually meaning the config is missing something.
