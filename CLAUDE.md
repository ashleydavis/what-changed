# Claude instructions for what-changed

## Comments

Every top-level declaration in a `.zig` file gets a comment above it, `pub` or not: functions, `const`, `var`, and every struct, enum, union and error set. Every struct field gets one too.

Say what it is for and why it is needed. Do not restate the type.

The style is `//` lines fenced by a blank `//` above and below, immediately before the declaration. Not `///`, and not a trailing comment on the same line.

```zig
//
// Where the file hash cache lives, resolved against `root_dir`.
//
// Resolved once here so a run cannot read one cache and write another.
//
cache_dir: []const u8,
```

## Done means

`zig build test`, `./scripts/smoke-tests.sh --binary` and `zig build perf` all pass. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
