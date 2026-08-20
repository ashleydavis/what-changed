const std = @import("std");
const wc = @import("what-changed");
const run = @import("run.zig");
const testing = std.testing;

test "buildFileTree writes the requested number of files, spread across directories" {
    var test_io = wc.files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try wc.files.TemporaryDir.create(io);
    defer temporary.destroy();

    const paths = try run.buildFileTree(io, allocator, temporary.path, 120);

    try testing.expectEqual(@as(usize, 120), paths.len);
    try testing.expectEqualStrings("packages/package-0/src/file-0.ts", paths[0]);
    try testing.expectEqualStrings("packages/package-2/src/file-19.ts", paths[119]);
    try testing.expect(temporary.has("packages/package-0/src/file-0.ts"));
    try testing.expect(temporary.has("packages/package-2/src/file-19.ts"));
}

test "buildFileTree gives every file different content, so hashing has real work to do" {
    var test_io = wc.files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try wc.files.TemporaryDir.create(io);
    defer temporary.destroy();

    const paths = try run.buildFileTree(io, allocator, temporary.path, 3);

    var cache: wc.file_hash.FileHashCache = .empty;
    var hashes = (try wc.file_hash.hashFiles(io, allocator, temporary.path, paths, &cache)).hashes;

    try testing.expect(!std.mem.eql(u8, hashes.get(paths[0]).?, hashes.get(paths[1]).?));
    try testing.expect(!std.mem.eql(u8, hashes.get(paths[1]).?, hashes.get(paths[2]).?));
}

test "buildFileTree writes files of the size the benchmark says it does" {
    var test_io = wc.files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try wc.files.TemporaryDir.create(io);
    defer temporary.destroy();

    const paths = try run.buildFileTree(io, allocator, temporary.path, 1);
    const stat = try wc.files.statFile(io, try wc.files.joinPath(allocator, &.{ temporary.path, paths[0] }));

    try testing.expectEqual(@as(u64, run.FILE_SIZE_BYTES + paths[0].len), stat.size);
}

test "elapsedMs measures forwards" {
    var test_io = wc.files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    const at = run.start(io);
    wc.files.sleepMs(io, 1);
    try testing.expect(run.elapsedMs(io, at) >= 1.0);
}

test "measurementFor finds a recorded result and reports a missing one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    run.results = .empty;
    try run.results.append(arena.allocator(), .{ .name = "hash", .file_count = 100, .milliseconds = 2.5 });

    try testing.expectEqual(@as(f64, 2.5), run.measurementFor("hash", 100).?);
    try testing.expect(run.measurementFor("hash", 1000) == null);
    try testing.expect(run.measurementFor("other", 100) == null);

    run.results = .empty;
}

test "stageNames lists each stage once, in the order first measured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    run.results = .empty;
    try run.results.append(allocator, .{ .name = "cold", .file_count = 100, .milliseconds = 1 });
    try run.results.append(allocator, .{ .name = "warm", .file_count = 100, .milliseconds = 1 });
    try run.results.append(allocator, .{ .name = "cold", .file_count = 1000, .milliseconds = 1 });

    const names = try run.stageNames(allocator);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("cold", names[0]);
    try testing.expectEqualStrings("warm", names[1]);

    run.results = .empty;
}

test "benchmarkSize measures every stage and stays within budget" {
    var test_io = wc.files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // Run at a tiny size, so the benchmark's own correctness is checked without the test suite
    // paying for a twenty-thousand-file tree.
    //
    run.results = .empty;
    var captured = std.Io.Writer.Allocating.init(allocator);
    run.out = .{ .writer = &captured.writer };

    try testing.expect(try run.benchmarkSize(io, allocator, 60));
    try testing.expectEqual(@as(usize, 4), run.results.items.len);

    for (run.results.items) |result| {
        try testing.expectEqual(@as(usize, 60), result.file_count);
        try testing.expect(result.milliseconds >= 0);
    }

    //
    // The warm run must be faster than the cold one. That is the whole claim the cache makes, and a
    // change that broke it would otherwise show up only as a slow build nobody traced back here.
    //
    try testing.expect(run.results.items[1].milliseconds < run.results.items[0].milliseconds);

    run.results = .empty;
}
