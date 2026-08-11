# Development

How to build `what-changed` from source and run its tests. For what the tool does and how to use it, see the [README](../README.md). For the internals, see [HOW_IT_WORKS.md](HOW_IT_WORKS.md).

## Build it from source

Needs [mise](https://mise.jdx.dev/), which fetches the Zig version set in [`mise.toml`](../mise.toml).

```bash
git clone https://github.com/ashleydavis/what-changed.git
cd what-changed
mise install           # installs the pinned Zig
zig build release      # bin/x64/linux/what-changed
```

`zig build` on its own puts an unoptimised binary at `zig-out/bin/what-changed`.

## Cross-compiling

Zig cross-compiles without a toolchain per target:

```bash
zig build release -Dtarget=x86_64-linux     # > bin/x64/linux/what-changed
zig build release -Dtarget=x86_64-windows   # > bin/x64/win/what-changed.exe
zig build release -Dtarget=x86_64-macos     # > bin/x64/mac/what-changed
zig build release -Dtarget=aarch64-macos    # > bin/arm64/mac/what-changed
```

Those four are what a release publishes, and they are the same four the release workflow builds from a single Linux runner.

## Tests

The tests run against real temporary directories, real files and real hashing. Every function in the project has unit tests.

```bash
zig build test                        # every unit test, in both modules
zig build                             # compiles the CLI (unoptimised)
zig build release                     # the optimised binary the smoke tests drive
zig build perf                        # benchmarks, fails if a stage blows its budget
./scripts/smoke-tests.sh --binary     # checks against the real CLI process
./scripts/test-everything.sh          # runs only what changed, then moves the baseline
```

[`scripts/smoke-tests.sh`](../scripts/smoke-tests.sh) drives the compiled executable rather than the source, which is why it is run with `--binary`: what ships gets tested rather than trusted.

**No test creates or modifies a git repository except one `git init` on a fresh `mktemp -d`.** A banner in [`scripts/smoke-tests.sh`](../scripts/smoke-tests.sh) explains why that one is safe. Read it before adding any git command there.

## Performance

[performance.md](performance.md) records what a run costs and the budgets `zig build perf` enforces.
