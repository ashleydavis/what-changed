# Example project

A Node.js project with one function and one test, wired up so the tests run only when something they depend on has changed.

It is deliberately tiny. Everything here that is not `src/greet.js` or `test/greet.test.js` is the wiring, and that wiring is the point.

## What's in it

| File | What it is |
| --- | --- |
| [`src/greet.js`](src/greet.js) | The "application": one function |
| [`test/greet.test.js`](test/greet.test.js) | One test, run by Node's built-in test runner |
| [`what-changed.yaml`](what-changed.yaml) | Which files decide whether the tests need to run |
| [`scripts/test-everything.sh`](scripts/test-everything.sh) | Asks what changed and runs only that |
| [`.githooks/pre-commit`](.githooks/pre-commit) | Runs the above before every commit |
| [`scripts/install-hooks.sh`](scripts/install-hooks.sh) | Points git at that hook, once per clone |
| [`mise.toml`](mise.toml) | Fetches Node and what-changed |
| [`.gitignore`](.gitignore) | Ignores `.what-changed/`, which is required |

No packages to install. The tests run on `node --test`, and `mise install` gets Node and the what-changed binary.

## Try it

This has to be inside a git repository, because that is how what-changed enumerates files. Copy it somewhere and initialise one:

```bash
cp -r example-project /tmp/example && cd /tmp/example
git init
mise install                 # Node, and the what-changed binary
./scripts/install-hooks.sh   # optional: run the tests before every commit
```

Then run it four times and watch what it decides:

```bash
./scripts/test-everything.sh   # nothing recorded yet, so the tests run and the baseline is recorded
./scripts/test-everything.sh   # nothing changed: the tests are skipped

echo "notes" > NOTES.md
./scripts/test-everything.sh   # still skipped, because .md is in the ignore list

sed -i 's/Hello/Hi/' src/greet.js
./scripts/test-everything.sh   # src changed, so the tests run again, and this time they fail
```

That last run is worth watching. The test fails, and because `scripts/test-everything.sh` uses `set -e` the script stops before it captures the baseline, so the baseline is **not** moved. Fix the change and run again and the tests pass and the baseline moves on.

## The two pieces that matter

**The config says what each target depends on.** One target here, `test`, watching `src` and `test`, plus `package.json` through `always`. Anything else in the project could change and the tests would still be skipped.

**The baseline is captured by the target's own command, not by the runner.** In `package.json`:

```json
"test": "node --test && what-changed baseline capture test"
```

The `&&` is what makes it honest: a failing suite never captures the baseline. Capturing the baseline is a claim that the suite passed against those exact files, and capturing before checking would mark a broken tree as tested.

Putting it there rather than in `scripts/test-everything.sh` means nobody has to remember it. Run `npm test` by hand, let the hook run it, or call it from CI, and the baseline moves the same way every time. A runner that captured the baseline on the target's behalf would only work when the target was started through that runner.

## Scaling it up

Add a target per thing you would want to run separately, and a branch in `scripts/test-everything.sh` to run it:

```yaml
targets:
  - name: lint
    paths:
      - src
      - test

  - name: test
    paths:
      - src
      - test

  - name: build
    paths:
      - src
```

Each records its own baseline as it passes, so a run where the linter passes and the tests fail leaves the linter marked up to date and the tests still needing to run.

See [`../configs/`](../configs/) for every config field, and the [main README](../../README.md) for the commands.

## Installing the pre-commit hook

[`.githooks/pre-commit`](.githooks/pre-commit) runs `scripts/test-everything.sh` before every commit, so a commit under `src` or `test` runs the suite and is refused if it fails, and a commit touching only the README runs nothing and goes straight through.

Install it with:

```bash
./scripts/install-hooks.sh
```

That runs `git config core.hooksPath .githooks`, pointing git at the hooks directory that comes with the project. Check it took with:

```bash
git config --get core.hooksPath   # prints .githooks
```

Git only reads hooks from the clone's own configuration, which is not version controlled, so this is once per clone and nothing does it for you. Anyone who clones the project has to run it themselves.

Bypass the hook for a single commit with `git commit --no-verify`. Remove it with `git config --unset core.hooksPath`.
