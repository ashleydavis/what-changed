# Overhaul how JSON is built and read

## Overview

Every machine-readable output in this tool is assembled by hand, one `put` at a time, into a `std.json.Value` tree. `structuredReport`, `ChangedFile.toValue`, `baselineToValue`, `cacheToValue`, `file_hashes.toValue` and the three `cmd/*.zig` builders are all the same forty lines of `try object.put(allocator, "someKey", value.str(x))` repeated. The key names in those calls are the tool's public contract, and nothing checks them against anything: a typo renames a field in the output and every test still passes, because the tests assert the same string the code writes. The idiomatic Zig answer is to declare the contract as a type and let reflection do the writing. This plan introduces one comptime helper, `value.fromStruct`, plus a set of view structs that ARE the output contract, and converts every hand-built object to them. It deliberately does not touch the read path or the config parser, for reasons in the Notes.

## Issues

## Steps

1. In `src/lib/value.zig`, add `pub fn fromStruct(allocator: std.mem.Allocator, source: anytype) std.mem.Allocator.Error!Value`. It reflects over `@typeInfo(@TypeOf(source)).@"struct".fields` in declaration order and builds an `Object`, so insertion order stays the declaration order and the rendered bytes stay deterministic. Field name mapping: a Zig `snake_case` field name becomes a `camelCase` JSON key, computed at comptime by `fromStruct` itself. Field value mapping: `[]const u8` becomes a string, `bool` a bool, every integer type an integer via `@intCast` to `i64`, `f64` a float, a nested struct a recursive `fromStruct`, and a slice of structs an array of recursive `fromStruct`. Anything else is a comptime error naming the field, so an unsupported field type fails the build rather than rendering wrong. Add `pub fn camelCase(comptime name: []const u8) []const u8` beside it as a separate comptime function so the mapping rule can be unit tested on its own. Requires `zig build test` to compile and pass.

2. In `src/lib/changed_files.zig`, add `pub const ChangedFileView = struct { path: []const u8, kind: []const u8, hash: []const u8, previous_hash: []const u8 }` with a comment on the struct and every field saying these names are the tool's output contract. Add `pub fn toView(self: ChangedFile) ChangedFileView`, which fills `kind` from `self.kind.text()`. Rewrite `ChangedFile.toValue` to be `value.fromStruct(allocator, self.toView())` and `toValueArray` to build its array from `toView` results. Delete the hand-built `put` sequence. Requires `zig build test` to pass with the existing `changed_files.test.zig` assertions on the rendered keys unchanged.

3. In `src/lib/run.zig`, add three view structs above `structuredReport`, one per `ReportMode`, each commented as the output contract for that view: `TargetsView { targets: [][]const u8 }`, `FilesView { has_baseline: bool, file_count: i64, changed: []ChangedFileView }` and `SummaryView { has_baseline: bool, file_count: i64, targets: []TargetView, unwatched: []ChangedFileView }`, with `TargetView { name: []const u8, watched_paths: [][]const u8, applies_here: bool, changed: []ChangedFileView }`. Note that `FilesView.changed` and `SummaryView.unwatched` are named for the JSON key, not for the `ReportResult` field they come from, which is why they are separate types rather than `ReportResult` being rendered directly. Rewrite `structuredReport` to build the right view for the mode and return `value.fromStruct(allocator, view)`. Delete every `put` call in that function. Requires `zig build test` to pass.

4. In `src/lib/file_hashes.zig`, leave `toValue` as it is and add a comment saying why: its keys are file paths, not field names, so there is no struct to reflect over. Do the same in `src/lib/baseline_store.zig` for the `targets` half of `baselineToValue`. Rewrite only the outer object of `baselineToValue` through `fromStruct` with a `BaselineFileView { targets: Value, files: Value }` struct, which needs `fromStruct` to pass an already-built `Value` field through untouched: add that case to step 1's field mapping. Requires `zig build test` to pass and the baseline file to be byte-identical before and after, checked by capturing a baseline, saving the bytes, rebuilding and capturing again.

5. In `src/lib/file_hash.zig`, rewrite the inner record of `cacheToValue` through a `CacheRecordView { mtime_ms: f64, size: i64, hash: []const u8 }` struct, leaving the outer path-keyed object hand-built as in step 4. Requires `zig build test` to pass and the cache file to be byte-identical before and after.

6. In `src/cmd/version.zig`, `src/cmd/cache.zig` and `src/cmd/baseline.zig`, replace each hand-built object with a view struct declared in that file: `VersionView { version, commit_hash, build_date, is_pre_release }`, `CacheView { cache_dir, entry_count }`, `BaselineView { baseline_path, status, targets: []BaselineTargetView }` with `BaselineTargetView { name, file_count }`. Requires `zig build test` and `./scripts/smoke-tests.sh --binary` to pass with no change to any asserted key.

7. In `src/lib/value.zig`, delete `newArray` if step 3 removed its last caller, checked with `grep -rn 'newArray' src/`. It exists only to wrap `Array.init(allocator)`, and the same reasoning that removed `newObject` applies once nothing calls it.

8. Add `docs/OUTPUT.md` listing every JSON key the tool emits and the view struct that declares it, so the contract has one written home. Link it from `docs/HOW_IT_WORKS.md` only if that document's "would anyone act differently after reading this" test is met; otherwise link it from `README.md` beside the `--output` documentation.

## Unit Tests

In `src/lib/value.test.zig`:

- `camelCase` maps `has_baseline` to `hasBaseline`, `previous_hash` to `previousHash`, `mtime_ms` to `mtimeMs`, and leaves a name with no underscore alone.
- `camelCase` handles a trailing underscore and a doubled underscore without producing an empty segment or a stray capital.
- `fromStruct` renders a flat struct of a string, a bool and an integer as an object with camelCase keys, in declaration order, asserted by rendering it through `json.stringify` and comparing the whole text.
- `fromStruct` renders a nested struct as a nested object.
- `fromStruct` renders a slice of structs as an array of objects.
- `fromStruct` passes an already-built `Value` field through untouched.
- `fromStruct` keeps declaration order rather than sorting, asserted with fields whose names sort differently from their declaration order. This is what keeps two runs printing the same bytes.

In `src/lib/changed_files.test.zig`:

- `toView` fills `kind` from the enum's `text()`, checked for every one of the four kinds so a new kind cannot be added without a rendering.
- `toValue` still renders exactly `path`, `kind`, `hash` and `previousHash`, asserted on the rendered JSON text rather than by reading fields back.

In `src/lib/run.test.zig`:

- `structuredReport` in each of the three modes renders the same keys it renders today, asserted on the whole rendered JSON text so a renamed key fails.

In `src/lib/baseline_store.test.zig` and `src/lib/file_hash.test.zig`:

- `baselineToValue` and `cacheToValue` render byte-identical text to what they render before this change, captured as a literal expected string in the test.

In `src/cmd/version.test.zig`, `src/cmd/cache.test.zig` and `src/cmd/baseline.test.zig`:

- Each command's `--output json` renders the same keys as before, asserted on the rendered text.

## Smoke Tests

In `scripts/smoke-tests.sh`:

- `summary --output json` contains `hasBaseline`, `fileCount`, `targets`, `unwatched`, and within a target `name`, `watchedPaths`, `appliesHere` and `changed`.
- `changes --output json` contains `hasBaseline`, `fileCount` and `changed`, and a change object contains `path`, `kind`, `hash` and `previousHash`.
- `targets --output json` contains `targets` and nothing else.
- `version --output json` contains `version`, `commitHash`, `buildDate` and `isPreRelease`.
- `baseline show --output json` contains `baselinePath`, `status` and `targets`.
- `cache show --output json` contains `cacheDir` and `entryCount`.
- The baseline file written after this change is byte-identical to one written before it, for the same tree.

## Verify

- `zig build` compiles the CLI with no errors.
- `zig build test` passes, with the total count up by the number of tests added.
- `./scripts/smoke-tests.sh --binary` passes, with the check count higher than 152 by the number of assertions added.
- `zig build perf` reports every stage within budget. Rendering is not a measured stage, so this is a check that nothing else moved.
- `grep -rn 'try object.put(allocator, "' src/ | grep -v '\.test\.zig'` returns only the path-keyed maps in `file_hashes.zig`, `baseline_store.zig` and `file_hash.zig`. Every other hand-built object is gone.

## Notes

**The read path is deliberately left alone.** The idiomatic Zig answer for reading would be `std.json.parseFromSliceLeaky(BaselineFile, allocator, text, .{})`, parsing straight into a concrete type. That is wrong here. `cacheFromValue` and `file_hashes.fromValue` drop any record that is malformed and keep the rest, and `toBaseline` treats either half that is not an object as absent. The static parser cannot do that: one bad record fails the whole document. The project's decision is that a damaged cache costs a slow run and never a blocked one, and that a damaged baseline costs a full report rather than a crash. Static parsing would turn both into a hard failure. `config.zig` is left alone for a different reason: it parses input that may be malformed in any way at all and has to say exactly what was wrong with it, and the static parser's `error.UnknownField` carries no field name, no line and no value.

**Why not `std.json.Stringify.value` on the structs directly.** That is the idiomatic way to write JSON in Zig, and it would delete `fromStruct` entirely. It cannot be used because `--output yaml` renders the same object through this project's own `yaml.stringify`, which takes a `Value`. Writing straight to a JSON writer would leave the YAML path with nothing to render, and the two formats rendering the identical object is what stops them disagreeing. Keeping `Value` as the one intermediate is the cost of supporting both. The alternative, teaching the YAML renderer to reflect over `anytype` as well, is a second reflection-based renderer to write and maintain, which is a much larger change for no gain in the output.

**Why not `jsonStringify` hooks.** `std.json` lets a type declare `pub fn jsonStringify(self, jw: anytype) !void` to control its own rendering, which is the idiomatic escape hatch for renaming fields. It writes directly into a JSON writer, so it has the same problem as above: the YAML path never sees it.

**The camelCase rule is the risky part.** Deriving JSON keys from Zig field names means a renamed field silently renames a public key. That is why every step asserts on rendered text rather than on fields read back, and why the smoke tests name every key. If that still feels too implicit when the helper is written, the fallback is declaring the fields with their exact JSON names using Zig's `@"camelCase"` field syntax, which removes the rule entirely at the cost of uglier field access.

**Order first, everything else second.** Objects render in insertion order because `std.json.ObjectMap` is an array hash map, and `fromStruct` must iterate fields in declaration order to preserve that. Sorted or hashed order would make the rendered bytes depend on something other than the document, which is what the sorting in `file_hashes.toValue` and `baselineToValue` exists to prevent.

**Do step 1 and step 2 and then stop for review.** Step 2 is one small call site and proves the helper on real output. Converting all seven at once and finding the mapping rule wrong would mean unpicking the lot.
