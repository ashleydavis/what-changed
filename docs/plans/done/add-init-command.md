# Add `what-changed init`

## Overview

Setting a project up by hand is two steps that are easy to get wrong: write a config, and add `.what-changed/` to `.gitignore`. Forgetting the second one is the worse of the two, because the tool lists untracked files, so an un-ignored `.what-changed/` shows up as a change to itself on every single run and every target looks affected forever. `what-changed init` does both, refuses to overwrite anything that already exists, and says what it did. It cannot guess a project's targets, so the config it writes is a starter template with two placeholder targets for the user to edit.

## Issues

## Steps

1. Create `src/cmd/init.zig` holding the command and its two halves. Declare `pub const STARTER_CONFIG: []const u8`, a YAML string matching the example in the README's "Getting started" section: an `always` list with `package.json`, an `ignore` list with `.md`, `.txt` and `.log`, and two targets named `compile` and `test` watching `src`. Declare `pub const GITIGNORE_ENTRY: []const u8 = ".what-changed/"`. Declare `pub const InitStep = enum { created, already_present }` so each half reports what it did as a value rather than only as printed text, which is what lets the unit tests assert on the outcome without parsing prose. Every declaration and every enum tag gets a comment, per `CLAUDE.md`.

2. In `src/cmd/init.zig`, add `pub fn writeStarterConfig(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8, fail: *Failure) wc.failure.Error!InitStep`. It checks every name in `wc.config.DEFAULT_CONFIG_NAMES` with `wc.files.fileExists` against `cwd`, and returns `.already_present` if any of them is there. Otherwise it writes `STARTER_CONFIG` to `what-changed.yaml` in `cwd` with `wc.files.writeFile`, turning a write error into a failure message through `fail.set` and `wc.files.describeError`, and returns `.created`. It must never overwrite: the existence check is the whole safety of this step. Requires `zig build test` to compile and pass before the step is complete.

3. In `src/cmd/init.zig`, add `pub fn addGitignoreEntry(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8, fail: *Failure) wc.failure.Error!InitStep`. It reads `.gitignore` in `cwd` with `wc.files.readFile`. A read failure means there is no usable `.gitignore`, so it writes one containing `GITIGNORE_ENTRY` and a trailing newline, and returns `.created`. When the file reads, it splits the contents on `\n`, trims each line of whitespace and a trailing `\r`, and returns `.already_present` if any line equals `.what-changed/` or `.what-changed`, since git honours both spellings. Otherwise it appends: a newline first when the existing contents do not already end in one, then the entry and a newline, written back with `wc.files.writeFile`. Requires `zig build test` to compile and pass before the step is complete.

4. In `src/cmd/init.zig`, add `pub fn initCommand(context: *const Context) wc.failure.Error!u8`. It calls `writeStarterConfig` and then `addGitignoreEntry`, both with `context.io`, `context.allocator`, `context.cwd` and `context.fail`, and prints one line per step through `context.out.line`: what was written, or that it was already there and was left alone. When the config was created it prints a closing line telling the user to edit the targets. It returns 0 in every case, including when both were already present, because finding the project already set up is a successful answer to "set this project up" and not a tool failure. Requires `zig build test` to compile and pass before the step is complete.

5. In `src/cmd/init.zig`, add `pub fn buildInitCommand(context: *const Context) *Command` following the pattern in `src/cmd/version.zig`: `Command.init(context.allocator, "init")` with a description, and `.action(context, action)`. Add the private `fn action(invocation: *commander.Invocation) anyerror!void` that casts `invocation.context` and sets `invocation.exit_code`. Give the command no `--config` option and no `--output` option: `--config` means "read this config" everywhere else in the tool and would mean "write here" on this command, and `init` is an action like `baseline capture`, which has no `--output` either. Add the `test { _ = @import("init.test.zig"); }` block at the bottom, per `CLAUDE.md`.

6. In `src/main.zig`, add `const init_cmd = @import("cmd/init.zig");` beside the other command imports and register it with `program.addCommand(init_cmd.buildInitCommand(context));` in `buildProgram`. Put it first among the commands, before `summary`, since it is the first thing a new user runs. Check whether `HELP_EXAMPLES` should gain an `init` line and add one if the other commands are represented there.

7. Create `src/cmd/init.test.zig` with the unit tests listed below, driven through `harness.Scenario` the way `src/cmd/baseline.test.zig` is. Call through the module, as `init.writeStarterConfig(...)` rather than a bare call. Requires `zig build test` to pass.

8. Add smoke test scenarios to `scripts/smoke-tests.sh`, in the section that runs outside any git repository, since `init` never calls git. Do not add any git command to that script. Requires `./scripts/smoke-tests.sh --binary` to pass.

9. Update `README.md`: add `what-changed init` to the Commands table, and rewrite the "Getting started" section so step 1 is running `init` and editing the targets it wrote, with the hand-written config and the manual `.gitignore` line kept as the "or do it by hand" alternative.

## Unit Tests

In `src/cmd/init.test.zig`:

- `writeStarterConfig` writes `what-changed.yaml` when the directory has no config, and returns `.created`.
- `writeStarterConfig` returns `.already_present` and leaves the file untouched when `what-changed.yaml` exists, asserting the original contents survive byte for byte.
- `writeStarterConfig` also returns `.already_present` for an existing `what-changed.yml` and for an existing `what-changed.json`, so the check covers every name in `DEFAULT_CONFIG_NAMES`.
- The config `writeStarterConfig` writes loads cleanly through `wc.config.loadConfig` and yields the two expected target names. This is what stops the template drifting into something the parser rejects.
- `addGitignoreEntry` creates `.gitignore` holding the entry when there is no `.gitignore`, and returns `.created`.
- `addGitignoreEntry` appends the entry when `.gitignore` exists without it, and leaves the existing lines in place.
- `addGitignoreEntry` inserts a newline before the entry when the existing `.gitignore` does not end in one, so the entry never lands on the end of somebody else's line.
- `addGitignoreEntry` returns `.already_present` for an existing `.what-changed/` line, and leaves the file byte for byte unchanged.
- `addGitignoreEntry` also returns `.already_present` for `.what-changed` without the trailing slash, and for a line with surrounding whitespace.
- `initCommand` returns 0 and prints a line naming each of the two files on a fresh project.
- `initCommand` returns 0 and says both were already there when run on a project that is already set up.
- `initCommand` is idempotent: running it twice leaves both files byte for byte identical to what the first run produced.

## Smoke Tests

In `scripts/smoke-tests.sh`, outside the git repository section:

- `init` in an empty directory exits 0, prints something naming `what-changed.yaml`, and both `what-changed.yaml` and `.gitignore` exist afterwards.
- `.gitignore` contains `.what-changed/` after `init`.
- Running `init` a second time exits 0 and mentions that the files are already there.
- `init` does not overwrite an existing config: write a recognisable config first, run `init`, and assert the recognisable contents are still there.
- `--help` lists `init` among the subcommands.

## Verify

- `zig build` compiles the CLI with no errors.
- `zig build test` passes, and the total test count has gone up by the number of tests added. A `.test.zig` file that nothing imports runs silently never, so the count moving is what proves the new file is wired in.
- `./scripts/smoke-tests.sh --binary` passes, with the check count higher than 152 by the number of assertions added.
- `zig build perf` still reports every stage within budget.
- Manual check in a throwaway directory: `what-changed init` in an empty `git init` repository, then `what-changed summary`, which should report every file as new rather than reporting `.what-changed/` as a change to itself.

## Notes

Writing `.gitignore` is the first time this tool modifies a file the user owns. Everything else it writes lives under `.what-changed/`. That is acceptable here because `init` is explicitly asked for and does exactly what its name says, but it is why the append is conservative: it never rewrites an existing line, never reorders anything, and never touches the file at all when the entry is already there.

`init` writes to `context.cwd` rather than searching for a project root. It is a bootstrap command, run before there is a config to locate a root with, so the working directory is the only sensible answer. This also keeps it testable through `harness.Scenario`, which already supplies `cwd`.

The starter config cannot know the project's targets, so it writes placeholders. That is worth doing anyway: the `.gitignore` line is the step people forget, and forgetting it makes the tool report itself as changed on every run.

Open question: whether `init` should also accept a `--force` flag to overwrite an existing config. Left out on purpose for now, because the failure it would cause is silent destruction of a config someone had tuned, and deleting the file by hand before rerunning is one obvious command.
