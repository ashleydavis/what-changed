# Claude instructions for what-changed

## Rules

- You (Claude) wrote this entire repo and are responsible for everything in it. Never uses these excuses:
- "It's pre existing code"
- "I didn't write it"
- "It happened before this session"

## Git in test scripts

The marked `git init` in `scripts/smoke-tests.sh` is the only git command in the tests that may change state. Never add another: a previous `git add -A` there hit the real repository and overwrote its branch pointer and index.

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

## Tests

Tests never live in the file they test. `src/lib/file_hash.zig` is tested by `src/lib/file_hash.test.zig`, beside it. Not idiomatic Zig, and deliberate: with tests inline, a diff of a code file does not say whether the code changed or only its tests did.

Nothing imports a `.test.zig` file, so the code file has to name it at the bottom, and that block is the only test wiring a code file holds:

```zig
test {
    _ = @import("file_hash.test.zig");
}
```

Leave it out and the tests silently never run, while `zig build test` still passes. Check the test count moved when you add a test file. Each of these blocks counts as one test of its own.

Call through the module, `file_hash.hashFile(...)` rather than a bare `hashFile(...)`.

Tests only reach `pub` declarations. Where a test needs something private, make it `pub` and say in its comment that the tests are why, as `READ_BUFFER_BYTES` does. Never copy the value into the test file: a copy keeps passing after the original changes.

Fixtures live in the test file that owns them and other test files import it, as `file_hashes.test.zig` exports `fromPairs`. Never put a fixture in a code file.

## Done means

`zig build test`, `./scripts/smoke-tests.sh --binary` and `zig build perf` all pass. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
