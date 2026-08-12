const std = @import("std");
const value = @import("value.zig");
const files = @import("files.zig");
const failure = @import("failure.zig");
const cache_store = @import("cache_store.zig");
const file_hashes_module = @import("file_hashes.zig");

const Value = value.Value;
const Failure = failure.Failure;

//
// A map of repository-relative path to content hash. Re-exported here because everything that
// stores hashes reaches for it through this module.
//
pub const FileHashes = file_hashes_module.FileHashes;

//
// Each target's recorded file hashes, keyed by target name.
//
pub const TargetBaselines = std.StringArrayHashMapUnmanaged(FileHashes);

//
// What each target saw the last time it was captured.
//
// Per target rather than one snapshot of the whole tree, because targets pass at different moments.
// A single tree-wide baseline can only be recorded when everything has passed together: recording it
// after one suite would mark every other suite as up to date without them having run. That failure
// is silent and it lets a broken commit through, which makes it the worst one this tool can have.
//
pub const Baseline = struct {
    //
    // For each target, the hashes of the files it watched when it was last captured. A target absent
    // from here has never been captured, so everything under it counts as changed.
    //
    targets: TargetBaselines,

    //
    // Every file's hash at the most recent capture of any kind. Used only to decide whether a file
    // that no target watches has changed, since such a file has no target record to compare against.
    //
    files: FileHashes,
};

//
// The baseline is stored on its own, in its own file, deliberately apart from the file hash cache.
//
// They are not the same kind of thing. The file hash cache exists so the tool does not redo work,
// and throwing it away costs one slow run. The baseline is the answer to "changed since when", and
// throwing it away changes what the tool reports. Keeping them in one directory invited exactly the
// mistake of clearing one and losing the other.
//

//
// Loads the baseline. A missing file, or JSON that will not parse or is not a plain object, reads as
// no baseline at all rather than as an error, so a damaged file costs a full report and never a
// crash.
//
// A file written by an older version, which held a flat path-to-hash map rather than this structure,
// also reads as no baseline. Everything then counts as changed, which is the safe direction: the
// first run after an upgrade does the work rather than skipping it.
//
pub fn loadBaseline(io: std.Io, allocator: std.mem.Allocator, baseline_path: []const u8) std.mem.Allocator.Error!Baseline {
    return toBaseline(allocator, try cache_store.readJsonObject(io, allocator, baseline_path));
}

//
// Reads a parsed JSON object as a baseline, treating either half that is not a plain object as
// absent.
//
pub fn toBaseline(allocator: std.mem.Allocator, parsed: Value) std.mem.Allocator.Error!Baseline {
    var targets: TargetBaselines = .empty;

    if (value.get(parsed, "targets")) |raw_targets| {
        if (value.isPlainObject(raw_targets)) {
            var walker = raw_targets.object.iterator();
            while (walker.next()) |entry| {
                try targets.put(allocator, entry.key_ptr.*, try file_hashes_module.fromValue(allocator, entry.value_ptr.*));
            }
        }
    }

    const recorded_files = if (value.get(parsed, "files")) |raw_files|
        try file_hashes_module.fromValue(allocator, raw_files)
    else
        FileHashes.empty;

    return .{ .targets = targets, .files = recorded_files };
}

//
// Renders a baseline as the JSON object it is stored as.
//
pub fn baselineToValue(allocator: std.mem.Allocator, baseline: *const Baseline) std.mem.Allocator.Error!Value {
    //
    // Target names are sorted so that two runs recording the same thing write byte-identical files,
    // whatever order the config happened to list the targets in.
    //
    const names = try allocator.dupe([]const u8, baseline.targets.keys());
    std.mem.sort([]const u8, names, {}, file_hashes_module.lessThanPath);

    var targets = value.newObject(allocator);
    for (names) |name| {
        const recorded = baseline.targets.get(name).?;
        try targets.put(allocator, name, try file_hashes_module.toValue(allocator, &recorded));
    }

    var object = value.newObject(allocator);
    try object.put(allocator, "targets", .{ .object = targets });
    try object.put(allocator, "files", try file_hashes_module.toValue(allocator, &baseline.files));
    return .{ .object = object };
}

//
// Returns a copy of the baseline with the named targets' records replaced, leaving every other
// target's record exactly as it was.
//
// This is what makes a per-target capture safe. Capturing one target must not touch another's
// record, because the other has not been re-run and nothing new is known about it.
//
pub fn withCapturedTargets(allocator: std.mem.Allocator, baseline: *const Baseline, captured: *const TargetBaselines, recorded_files: FileHashes) std.mem.Allocator.Error!Baseline {
    var targets: TargetBaselines = .empty;

    var existing = baseline.targets.iterator();
    while (existing.next()) |entry| {
        try targets.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    var replacing = captured.iterator();
    while (replacing.next()) |entry| {
        try targets.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    return .{ .targets = targets, .files = recorded_files };
}

//
// What a capture is about to write, so the change applied under the lock has everything it needs.
//
const Capture = struct {
    captured: *const TargetBaselines,
    files: FileHashes,
};

//
// Merges a capture into whatever the baseline file currently holds.
//
// This runs inside the lock, on contents read inside the lock, which is what makes a concurrent
// capture safe: the merge starts from what the other writer left, not from what this process read
// before waiting.
//
fn applyCapture(capture: Capture, allocator: std.mem.Allocator, current: Value) std.mem.Allocator.Error!Value {
    const existing = try toBaseline(allocator, current);
    const merged = try withCapturedTargets(allocator, &existing, capture.captured, capture.files);
    return baselineToValue(allocator, &merged);
}

//
// Records the named targets' hashes into the baseline, leaving every other target's record alone.
//
// This is the only way a capture reaches the file. Several processes capture at once, because a
// parallel suite captures each target as that target passes, and the read and the write have to be
// one indivisible step: two captures that both read the same baseline and then both write it back
// would each keep only their own target, and whichever wrote second would discard the other's.
//
pub fn captureTargets(io: std.Io, allocator: std.mem.Allocator, baseline_path: []const u8, captured: *const TargetBaselines, recorded_files: FileHashes, fail: *Failure) failure.Error!void {
    try cache_store.updateJsonFile(io, allocator, baseline_path, Capture{ .captured = captured, .files = recorded_files }, applyCapture, fail);
}

//
// Records a baseline, creating the directory above it if it is not there yet.
//
pub fn saveBaseline(io: std.Io, allocator: std.mem.Allocator, baseline_path: []const u8, baseline: *const Baseline) !void {
    try cache_store.writeJsonFile(io, allocator, baseline_path, try baselineToValue(allocator, baseline));
}

//
// Forgets the baseline, so the next report treats every file as new.
//
// An empty baseline is written rather than the file being deleted, for the same reason the cache
// reset writes rather than deletes: everything that reads it treats empty and absent alike, and a
// write cannot go wrong the way a delete of a computed path can.
//
pub fn baselineReset(io: std.Io, allocator: std.mem.Allocator, baseline_path: []const u8) !void {
    const empty = Baseline{ .targets = .empty, .files = .empty };
    try saveBaseline(io, allocator, baseline_path, &empty);
}

const testing = std.testing;

//
// Builds a target baseline map from pairs of name and file hashes, so a test case is one line.
//
fn baselinesFor(allocator: std.mem.Allocator, entries: []const struct { []const u8, []const [2][]const u8 }) !TargetBaselines {
    var targets: TargetBaselines = .empty;
    for (entries) |entry| {
        try targets.put(allocator, entry[0], try file_hashes_module.fromPairs(allocator, entry[1]));
    }
    return targets;
}

test "toBaseline reads both halves of a recorded baseline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try @import("json.zig").parse(allocator,
        \\{
        \\  "targets": { "unit": { "src/a.ts": "hash-a" } },
        \\  "files": { "src/a.ts": "hash-a", "README.md": "hash-r" }
        \\}
    );

    var baseline = try toBaseline(allocator, parsed);
    try testing.expectEqual(@as(usize, 1), baseline.targets.count());
    try testing.expectEqualStrings("hash-a", baseline.targets.get("unit").?.get("src/a.ts").?);
    try testing.expectEqual(@as(usize, 2), baseline.files.count());
}

test "toBaseline treats a half that is not an object as absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json = @import("json.zig");

    var no_targets = try toBaseline(allocator, try json.parse(allocator, "{\"targets\": [], \"files\": {\"a\": \"1\"}}"));
    try testing.expectEqual(@as(usize, 0), no_targets.targets.count());
    try testing.expectEqual(@as(usize, 1), no_targets.files.count());

    var no_files = try toBaseline(allocator, try json.parse(allocator, "{\"targets\": {\"unit\": {}}, \"files\": 7}"));
    try testing.expectEqual(@as(usize, 1), no_files.targets.count());
    try testing.expectEqual(@as(usize, 0), no_files.files.count());
}

test "toBaseline reads an old flat file as no baseline at all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // What an older version wrote: a flat path-to-hash map with neither half of the current
    // structure. Reading it as empty means everything counts as changed, which is the safe
    // direction after an upgrade.
    //
    const parsed = try @import("json.zig").parse(allocator, "{\"src/a.ts\": \"hash-a\"}");
    var baseline = try toBaseline(allocator, parsed);

    try testing.expectEqual(@as(usize, 0), baseline.targets.count());
    try testing.expectEqual(@as(usize, 0), baseline.files.count());
}

test "toBaseline of an empty object is an empty baseline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var baseline = try toBaseline(allocator, .{ .object = value.newObject(allocator) });
    try testing.expectEqual(@as(usize, 0), baseline.targets.count());
    try testing.expectEqual(@as(usize, 0), baseline.files.count());
}

test "baselineToValue renders both halves, with the target names sorted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const baseline = Baseline{
        .targets = try baselinesFor(allocator, &.{
            .{ "unit", &.{.{ "src/a.ts", "1" }} },
            .{ "docs", &.{.{ "docs/g.md", "2" }} },
        }),
        .files = try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "1" }}),
    };

    const rendered = try baselineToValue(allocator, &baseline);
    const targets = value.get(rendered, "targets").?;
    try testing.expectEqualStrings("docs", targets.object.keys()[0]);
    try testing.expectEqualStrings("unit", targets.object.keys()[1]);
    try testing.expectEqualStrings("1", value.get(value.get(targets, "unit").?, "src/a.ts").?.string);
    try testing.expectEqual(@as(usize, 1), value.get(rendered, "files").?.object.count());
}

test "a baseline survives a round trip through a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const baseline = Baseline{
        .targets = try baselinesFor(allocator, &.{.{ "unit", &.{ .{ "src/a.ts", "1" }, .{ "src/b.ts", "2" } } }}),
        .files = try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "1" }}),
    };

    var round_tripped = try toBaseline(allocator, try baselineToValue(allocator, &baseline));
    try testing.expectEqual(@as(usize, 2), round_tripped.targets.get("unit").?.count());
    try testing.expectEqualStrings("2", round_tripped.targets.get("unit").?.get("src/b.ts").?);
    try testing.expectEqual(@as(usize, 1), round_tripped.files.count());
}

test "withCapturedTargets replaces the named targets and leaves the others" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const baseline = Baseline{
        .targets = try baselinesFor(allocator, &.{
            .{ "unit", &.{.{ "src/a.ts", "old" }} },
            .{ "docs", &.{.{ "docs/g.md", "kept" }} },
        }),
        .files = try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "old" }}),
    };

    const captured = try baselinesFor(allocator, &.{.{ "unit", &.{.{ "src/a.ts", "new" }} }});
    const updated = try withCapturedTargets(allocator, &baseline, &captured, try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "new" }}));

    try testing.expectEqualStrings("new", updated.targets.get("unit").?.get("src/a.ts").?);
    //
    // The target that was not captured keeps exactly what it had. This is the rule the per-target
    // baseline exists for: nothing new is known about a suite that did not run.
    //
    try testing.expectEqualStrings("kept", updated.targets.get("docs").?.get("docs/g.md").?);
    try testing.expectEqualStrings("new", updated.files.get("src/a.ts").?);
}

test "withCapturedTargets adds a target that was never captured before" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const baseline = Baseline{ .targets = .empty, .files = .empty };
    const captured = try baselinesFor(allocator, &.{.{ "new-target", &.{.{ "src/a.ts", "1" }} }});

    const updated = try withCapturedTargets(allocator, &baseline, &captured, .empty);
    try testing.expectEqual(@as(usize, 1), updated.targets.count());
    try testing.expectEqualStrings("1", updated.targets.get("new-target").?.get("src/a.ts").?);
}

test "loadBaseline reads what saveBaseline wrote" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const path = try temporary.join(allocator, ".what-changed/baseline.json");

    const baseline = Baseline{
        .targets = try baselinesFor(allocator, &.{.{ "unit", &.{.{ "src/a.ts", "1" }} }}),
        .files = try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "1" }}),
    };
    try saveBaseline(io, allocator, path, &baseline);

    var loaded = try loadBaseline(io, allocator, path);
    try testing.expectEqualStrings("1", loaded.targets.get("unit").?.get("src/a.ts").?);
}

test "loadBaseline of a missing or damaged file is an empty baseline" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("damaged.json", "{ not json");

    var missing = try loadBaseline(io, allocator, try temporary.join(allocator, "gone.json"));
    try testing.expectEqual(@as(usize, 0), missing.targets.count());

    var damaged = try loadBaseline(io, allocator, try temporary.join(allocator, "damaged.json"));
    try testing.expectEqual(@as(usize, 0), damaged.targets.count());
}

test "captureTargets records a target without touching the others" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const path = try temporary.join(allocator, "baseline.json");

    var fail = Failure.init(allocator);

    const first = try baselinesFor(allocator, &.{.{ "unit", &.{.{ "src/a.ts", "1" }} }});
    try captureTargets(io, allocator, path, &first, try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "1" }}), &fail);

    const second = try baselinesFor(allocator, &.{.{ "docs", &.{.{ "docs/g.md", "2" }} }});
    try captureTargets(io, allocator, path, &second, try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "1" }}), &fail);

    //
    // Both are there. The second capture read what the first wrote and added to it, which is what
    // stops one target's capture erasing another's.
    //
    var loaded = try loadBaseline(io, allocator, path);
    try testing.expectEqual(@as(usize, 2), loaded.targets.count());
    try testing.expectEqualStrings("1", loaded.targets.get("unit").?.get("src/a.ts").?);
    try testing.expectEqualStrings("2", loaded.targets.get("docs").?.get("docs/g.md").?);
}

test "captureTargets replaces a target's record when it is captured again" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const path = try temporary.join(allocator, "baseline.json");

    var fail = Failure.init(allocator);

    const before = try baselinesFor(allocator, &.{.{ "unit", &.{ .{ "src/a.ts", "1" }, .{ "src/gone.ts", "2" } } }});
    try captureTargets(io, allocator, path, &before, .empty, &fail);

    const after = try baselinesFor(allocator, &.{.{ "unit", &.{.{ "src/a.ts", "changed" }} }});
    try captureTargets(io, allocator, path, &after, .empty, &fail);

    var loaded = try loadBaseline(io, allocator, path);
    try testing.expectEqual(@as(usize, 1), loaded.targets.get("unit").?.count());
    try testing.expectEqualStrings("changed", loaded.targets.get("unit").?.get("src/a.ts").?);
}

test "baselineReset writes an empty baseline rather than deleting the file" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const path = try temporary.join(allocator, "baseline.json");

    const baseline = Baseline{
        .targets = try baselinesFor(allocator, &.{.{ "unit", &.{.{ "src/a.ts", "1" }} }}),
        .files = .empty,
    };
    try saveBaseline(io, allocator, path, &baseline);

    try baselineReset(io, allocator, path);

    try testing.expect(files.fileExists(io, path));
    var loaded = try loadBaseline(io, allocator, path);
    try testing.expectEqual(@as(usize, 0), loaded.targets.count());
    try testing.expectEqual(@as(usize, 0), loaded.files.count());
}
