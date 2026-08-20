const std = @import("std");
const value = @import("value.zig");
const files = @import("files.zig");
const baseline_store = @import("baseline_store.zig");
const failure = @import("failure.zig");
const file_hashes_test = @import("file_hashes.test.zig");
const Failure = failure.Failure;
const testing = std.testing;

//
// Builds a target baseline map from pairs of name and file hashes, so a test case is one line.
//
fn baselinesFor(allocator: std.mem.Allocator, entries: []const struct { []const u8, []const [2][]const u8 }) !baseline_store.TargetBaselines {
    var targets: baseline_store.TargetBaselines = .empty;
    for (entries) |entry| {
        try targets.put(allocator, entry[0], try file_hashes_test.fromPairs(allocator, entry[1]));
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

    var baseline = try baseline_store.toBaseline(allocator, parsed);
    try testing.expectEqual(@as(usize, 1), baseline.targets.count());
    try testing.expectEqualStrings("hash-a", baseline.targets.get("unit").?.get("src/a.ts").?);
    try testing.expectEqual(@as(usize, 2), baseline.files.count());
}

test "toBaseline treats a half that is not an object as absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json = @import("json.zig");

    var no_targets = try baseline_store.toBaseline(allocator, try json.parse(allocator, "{\"targets\": [], \"files\": {\"a\": \"1\"}}"));
    try testing.expectEqual(@as(usize, 0), no_targets.targets.count());
    try testing.expectEqual(@as(usize, 1), no_targets.files.count());

    var no_files = try baseline_store.toBaseline(allocator, try json.parse(allocator, "{\"targets\": {\"unit\": {}}, \"files\": 7}"));
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
    var baseline = try baseline_store.toBaseline(allocator, parsed);

    try testing.expectEqual(@as(usize, 0), baseline.targets.count());
    try testing.expectEqual(@as(usize, 0), baseline.files.count());
}

test "toBaseline of an empty object is an empty baseline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var baseline = try baseline_store.toBaseline(allocator, .{ .object = .empty });
    try testing.expectEqual(@as(usize, 0), baseline.targets.count());
    try testing.expectEqual(@as(usize, 0), baseline.files.count());
}

test "baselineToValue renders both halves, with the target names sorted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const baseline = baseline_store.Baseline{
        .targets = try baselinesFor(allocator, &.{
            .{ "unit", &.{.{ "src/a.ts", "1" }} },
            .{ "docs", &.{.{ "docs/g.md", "2" }} },
        }),
        .files = try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "1" }}),
    };

    const rendered = try baseline_store.baselineToValue(allocator, &baseline);
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

    const baseline = baseline_store.Baseline{
        .targets = try baselinesFor(allocator, &.{.{ "unit", &.{ .{ "src/a.ts", "1" }, .{ "src/b.ts", "2" } } }}),
        .files = try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "1" }}),
    };

    var round_tripped = try baseline_store.toBaseline(allocator, try baseline_store.baselineToValue(allocator, &baseline));
    try testing.expectEqual(@as(usize, 2), round_tripped.targets.get("unit").?.count());
    try testing.expectEqualStrings("2", round_tripped.targets.get("unit").?.get("src/b.ts").?);
    try testing.expectEqual(@as(usize, 1), round_tripped.files.count());
}

test "withCapturedTargets replaces the named targets and leaves the others" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const baseline = baseline_store.Baseline{
        .targets = try baselinesFor(allocator, &.{
            .{ "unit", &.{.{ "src/a.ts", "old" }} },
            .{ "docs", &.{.{ "docs/g.md", "kept" }} },
        }),
        .files = try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "old" }}),
    };

    const captured = try baselinesFor(allocator, &.{.{ "unit", &.{.{ "src/a.ts", "new" }} }});
    const updated = try baseline_store.withCapturedTargets(allocator, &baseline, &captured, try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "new" }}));

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

    const baseline = baseline_store.Baseline{ .targets = .empty, .files = .empty };
    const captured = try baselinesFor(allocator, &.{.{ "new-target", &.{.{ "src/a.ts", "1" }} }});

    const updated = try baseline_store.withCapturedTargets(allocator, &baseline, &captured, .empty);
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

    const baseline = baseline_store.Baseline{
        .targets = try baselinesFor(allocator, &.{.{ "unit", &.{.{ "src/a.ts", "1" }} }}),
        .files = try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "1" }}),
    };
    try baseline_store.saveBaseline(io, allocator, path, &baseline);

    var loaded = (try baseline_store.loadBaseline(io, allocator, path)).baseline;
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

    const missing = try baseline_store.loadBaseline(io, allocator, try temporary.join(allocator, "gone.json"));
    try testing.expectEqual(@as(usize, 0), missing.baseline.targets.count());

    const damaged = try baseline_store.loadBaseline(io, allocator, try temporary.join(allocator, "damaged.json"));
    try testing.expectEqual(@as(usize, 0), damaged.baseline.targets.count());

    //
    // Both empty, and the caller can still tell them apart. That is the difference between "nothing
    // has been captured" and "something was captured and the file holding it is broken".
    //
    try testing.expectEqualStrings("absent", missing.source.statusText());
    try testing.expectEqualStrings("notJson", damaged.source.statusText());
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
    try baseline_store.captureTargets(io, allocator, path, &first, try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "1" }}), &fail);

    const second = try baselinesFor(allocator, &.{.{ "docs", &.{.{ "docs/g.md", "2" }} }});
    try baseline_store.captureTargets(io, allocator, path, &second, try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "1" }}), &fail);

    //
    // Both are there. The second capture read what the first wrote and added to it, which is what
    // stops one target's capture erasing another's.
    //
    var loaded = (try baseline_store.loadBaseline(io, allocator, path)).baseline;
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
    try baseline_store.captureTargets(io, allocator, path, &before, .empty, &fail);

    const after = try baselinesFor(allocator, &.{.{ "unit", &.{.{ "src/a.ts", "changed" }} }});
    try baseline_store.captureTargets(io, allocator, path, &after, .empty, &fail);

    var loaded = (try baseline_store.loadBaseline(io, allocator, path)).baseline;
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

    const baseline = baseline_store.Baseline{
        .targets = try baselinesFor(allocator, &.{.{ "unit", &.{.{ "src/a.ts", "1" }} }}),
        .files = .empty,
    };
    try baseline_store.saveBaseline(io, allocator, path, &baseline);

    try baseline_store.baselineReset(io, allocator, path);

    try testing.expect(files.fileExists(io, path));
    var loaded = (try baseline_store.loadBaseline(io, allocator, path)).baseline;
    try testing.expectEqual(@as(usize, 0), loaded.targets.count());
    try testing.expectEqual(@as(usize, 0), loaded.files.count());
}
