# what-changed

Reports which files have changed since a recorded baseline and which of your project's targets those changes fall under.

## What's it for?

It prevents unnecessary rebuilds and retests of parts of the project that have not changed since they were last built or tested.

Most projects run everything on every change. It hurts most in a pre-commit hook. A hook that runs the whole test suite makes every commit cost the whole test suite, even just for README or documentation changes that don't really need to run tests.

This project answers one question: since the point you last recorded as good, which files changed and which build/test targets does that invalidate? What you do with the answer is up to you. Run the affected tests, build the affected packages, deploy the affected services, or whatever you want.

It is built to be driven from a script that asks what changed, runs that, and records each target's baseline as that target passes. [`scripts/test-everything.sh`](scripts/test-everything.sh) in this repository is the test script that this project uses on itself.

## Why use it?

**You only build and test what changed.** The baseline is the state of the project at your last successful build or test. It reports which files differ from that baseline and which targets they fall under, so you run only those targets.

**It fits your existing build script.** It prints a list of target names and exits. Your script reads that list and runs those targets.

**It is fast.** A warm check reads no file it has already seen: it stats each one and compares the modification time and size against what it recorded. See [docs/performance.md](docs/performance.md) for what that costs.

**It reports files that no target watches.** A changed file that no target watches gets its own section in the output instead of being dropped. That is usually a gap in the config.

## When not to use it

**Your build tool already does this.** Nx, Turborepo and Bazel select affected targets from a real dependency graph. If you use one of those, use its own mechanism.

**You need import-level accuracy.** Targets are matched by path, not by what imports what. Any change under a watched path runs that target, so it errs towards running too much.

**What decides your work lives outside the working tree.** A new SDK, a changed environment variable or a rotated credential are all invisible to it. Installed dependencies are invisible too, though watching the lockfile covers that in practice.

**The work is already cheap.** If what you want to skip is quick anyway, skipping it saves nothing and you have added a moving part.

## What it looks like

It reports the changed files grouped under the targets they affect.

```bash
$ what-changed summary
Changed since the baseline:

  compile: 2 changed
    M  a5e4d212f14f3cc1  src/parser/lexer.ts
    A  0f15384d18789b1e  src/parser/new.ts
  test: 2 changed
    M  a5e4d212f14f3cc1  src/parser/lexer.ts
    A  0f15384d18789b1e  src/parser/new.ts
  e2e: unchanged

  Watched by no target: 1 changed
    M  3b1f90ac77e21d04  tools/stray.ts

3 changed, 2196 file(s) checked.
```

Note two things in that output. A file lands under every target that watches it, so one change can affect several targets. A changed file that **no** target watches is listed separately, because that is usually a gap in the config.

For how it decides what changed, and why the recorded state is arranged the way it is, see [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md). For what it costs, see [docs/performance.md](docs/performance.md). To build it yourself, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Install

The easiest way to install is with [mise](https://mise.jdx.dev/) and a `mise.toml` for your project:

```toml
[tools]
"github:ashleydavis/what-changed" = "latest"
```

Then run `mise install`. 

Set a particular version instead of `latest`. Find the list of versions at the [releases page](https://github.com/ashleydavis/what-changed/releases).

Without mise, download the archive for your platform from the [releases page](https://github.com/ashleydavis/what-changed/releases), extract it and move the binary to your PATH:

```bash
tar -xzf what-changed-linux-x64.tar.gz
chmod +x what-changed
```

`what-changed` is a single self-contained executable. It needs `git` on the PATH, and the project it runs against must be a git repository.

## Getting started

1. Set the project up from its root:

   ```bash
   what-changed init
   ```

   That writes a starter `what-changed.yaml` and adds `.what-changed/` to your `.gitignore`. Neither is overwritten: a config that is already there is left exactly as it is, and so is a `.gitignore` that already ignores `.what-changed/`.

2. Edit the targets in the config it wrote. It cannot know what your project builds, so the two it writes are placeholders. A target names a build or test step and the paths whose content decides whether that step has to run again.

   ```yaml
   always:
     - package.json
     - package-lock.json

   ignore:
     - .md
     - .txt
     - .log

   targets:
     - name: compile
       paths:
         - src

     - name: test
       paths:
         - src
         - test
   ```

   YAML and JSON both work. [examples/configs/](examples/configs/) has examples of both formats, and [examples/example-project/](examples/example-project/) is a small working project with the whole thing wired up.

3. Ask what changed:

   ```bash
   what-changed summary
   ```

   With no baseline recorded yet every target is reported, because nothing can be called unchanged.

4. Wire it into your build or test script. After a target's build or test passes, capture the baseline for that target:

   ```bash
   what-changed baseline capture test
   ```

   Capturing the baseline is the only thing that moves it. It claims "this target passed against these files".

   Chain it after your build or tests with `&&` so a failing build or test suite never captures the baseline:

   ```bash
   npm test && what-changed baseline capture test
   ```

## Commands

| Command | What it does |
| --- | --- |
| `what-changed` | Prints the usage text |
| `what-changed init` | Write a starter config and add `.what-changed/` to `.gitignore`. Neither is overwritten |
| `what-changed summary` | The changed files, grouped under the targets they fall under |
| `what-changed changes` | The changed files as a flat list |
| `what-changed targets` | Just the affected target names, one per line, for a script to read |
| `what-changed targets list` | Every target that can run on this platform, regardless of what changed |
| `what-changed baseline capture [targets...]` | Record what the named targets watch as their baseline. With no names, every target. Aliases: `update`, `set` |
| `what-changed baseline reset` | Forget the baseline, so everything reads as new |
| `what-changed baseline show` | Where the baseline is and what is in it |
| `what-changed cache capture` | Refresh the file hash cache. Alias: `update` |
| `what-changed cache reset` | Empty the file hash cache. The baseline is untouched |
| `what-changed cache show` | Where the cache is and how much is in it |
| `what-changed version` | The version, and the commit and date it was built from. Also `-v` / `--version` |

Every subcommand that reads a config takes `--config <path>`. Without it the tool looks for `what-changed.yaml`, then `.yml`, then `.json` and uses the first it finds. `init` and `version` take no `--config`: neither of them reads one.

### Output formats

Every reporting command takes `--output text|json|yaml`, defaulting to `text`.

`text` is for a person reading a terminal. `json` and `yaml` render the same object, so both give the same answer and you pick whichever your tooling already reads.

```bash
$ what-changed targets --output json
{
  "targets": [
    "compile",
    "test"
  ]
}
```

### Reading the output

`M` is modified, `A` added, `D` deleted, `U` unreadable. A deleted or unreadable file shows the hash it used to have.

`U` means the file is there and could not be read, a permission problem most of the time. It counts as changed, because a file nobody can read cannot be called unchanged, and it will keep counting as changed on every run until it can be read again. It is reported as its own kind so that it does not read as a deletion.

`what-changed targets` prints nothing when nothing changed. With no baseline recorded it names every target, because nothing can be called unchanged yet.

Only `baseline capture` and `cache capture` write anything. Every other command can be run as often as you like and reports the same answer each time.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | It ran and reported, whether or not anything changed |
| 1 | The tool itself failed: bad config, unknown option, git missing or failing |

"Something changed" is **not** an error, so the exit code never tells you whether there is work to do. Read that from the target names `what-changed targets` prints and run the ones it names. Naming no targets means there is nothing to run, which also happens when files changed but no target watches them.

## Driving it from a "test everything" script

This is your project's "test everything" script. It asks `what-changed targets` which targets have changes since the last successful test run and runs tests only for those targets:

```bash
set -e

# You implement this. It turns a target name from your config into the command that builds or tests it, and it must exit non-zero when that command fails.
run_target() {
    case "$1" in
        compile)  npm run build ;;
        test)     npm test ;;
        e2e)      npx playwright test ;;
        *)        echo "Unknown target \"$1\"." >&2; return 1 ;;
    esac
}

TARGETS=()
while IFS= read -r LINE; do
    if [ -n "$LINE" ]; then
        TARGETS+=("$LINE")
    fi
done <<< "$(what-changed targets)"

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "Nothing to do."
    exit 0
fi

# Nothing captures a baseline here. Each target's own command does that as its last step, so it
# happens however the target was started.
for TARGET_NAME in "${TARGETS[@]}"; do
    echo "Running: $TARGET_NAME"
    run_target "$TARGET_NAME"
done
```

Two examples of that script live in this repository: 
- [`scripts/test-everything.sh`](scripts/test-everything.sh): which this project runs on itself from its pre-commit hook
- [`examples/example-project/scripts/test-everything.sh`](examples/example-project/scripts/test-everything.sh): part of the example Node.js project that demonstrates how to use what-changed.

Each target captures its own baseline as the last step of its own command. In `package.json`:

```json
{
    "scripts": {
        "test": "node --test && what-changed baseline capture test",
        "e2e": "playwright test && what-changed baseline capture e2e"
    }
}
```

Now any run of `npm test` that passes captures the baseline for the `test` target, whether you started it yourself, from the test everything script, from a pre-commit hook or from CI. 

Capture the baseline for one target at a time, right after that target's own build or test passed. That way you can run just one of your targets and capture only that one and the targets you did not run are still reported as needing to run.

## Running it from a Git pre-commit hook

You can use what-changed in your Git pre-commit hook to efficiently prevent broken code from being committed.

1. Write the hook at [`.githooks/pre-commit`](.githooks/pre-commit) and make it executable:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   ./scripts/test-everything.sh
   ```

2. Point git at that directory:

   ```bash
   git config core.hooksPath .githooks
   ```

   Git only reads hooks from the clone's own configuration, which is not version controlled, so this is once per clone and nothing does it for you. Wrap it in a script so nobody has to remember it.

Runnable examples of installling a Git pre-commit hook are available here:

- The Node.js [example project](examples/example-project/), the smaller one to read first:
  - [`.githooks/pre-commit`](examples/example-project/.githooks/pre-commit): the hook itself
  - [`scripts/install-hooks.sh`](examples/example-project/scripts/install-hooks.sh): step 2, wrapped in a script
  - [A walkthrough](examples/example-project/README.md#installing-the-pre-commit-hook) of what both do
- This project, which uses the same arrangement on itself:
  - [`.githooks/pre-commit`](.githooks/pre-commit): the hook itself
  - [`scripts/install-hooks.sh`](scripts/install-hooks.sh): step 2, wrapped in a script

## The config file

The config lives at the root of your project as `what-changed.yaml`, `.yml` or `.json`. 

```yaml
always: # optional
  - package.json
  - package-lock.json

ignore: # optional
  - .md
  - .txt
  - .log

targets:
  - name: compile
    paths:
      - src

  - name: mobile
    paths:
      - mobile
    platforms:
      - linux
      - darwin
```

Examples in this repo:

- [`what-changed.yaml`](what-changed.yaml): what this project uses on itself
- [`examples/example-project/what-changed.yaml`](examples/example-project/what-changed.yaml): the smallest useful config, one target
- [`examples/configs/`](examples/configs/): the same config in [YAML](examples/configs/what-changed.yaml) and [JSON](examples/configs/what-changed.json), with every field commented


## Config file reference

| Field | Meaning |
| --- | --- |
| `cacheDir` | Where the file hash cache is kept, relative to the config file. Defaults to `.what-changed/cache`. Must be gitignored. |
| `baselinePath` | Where the baseline is recorded, relative to the config file. Defaults to `.what-changed/baseline.json`. Must be gitignored. |
| `always` | Paths that fall under every target, for things affecting the whole project. Defaults to empty. |
| `ignore` | Extensions left out of the file list entirely, each with its leading dot, matched case-insensitively. Defaults to empty. |
| `targets` | One entry per thing you would want to run. Required, must not be empty. |
| `targets[].name` | The name printed and listed by `targets`. Must be unique. |
| `targets[].paths` | Repository-relative files or directories. Required, must not be empty. |
| `targets[].platforms` | Platform names this target can run on: `linux`, `darwin`, `win32`. Defaults to every platform. See [Platform filtering](#platform-filtering). |

Paths in the config file are relative to the directory that contains the config file.

## Platform filtering

Some targets need a toolchain that only exists on one operating system. An iOS build needs Xcode, an Android test run needs an emulator. `platforms` says where a target can run:

```yaml
targets:
  - name: ios
    paths:
      - apps/ios-frontend
    platforms:
      - darwin
```

On platforms other than MacOS the `ios` target is automatically excluded.

`what-changed summary` reports excluded targets as `wrong-platform` rather than `unchanged`, because the target was affected, but it could not run on this platform:

```
  unit: 1 changed
    M  a5e4d212f14f3cc1  apps/ios-frontend/App.swift
  ios: wrong-platform
```

`what-changed targets list` names every target that can run on this platform, regardless of what changed. 

## Development

To build it from source, cross-compile it or run its tests, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

MIT. See [LICENSE](LICENSE).
