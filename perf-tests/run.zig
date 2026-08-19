const std = @import("std");
const wc = @import("what-changed");

//
// The performance benchmarks.
//
// The stages a check is made of, at four tree sizes, so how the cost grows with a project is
// visible rather than one number from one machine.
//

//
// The tree sizes each benchmark is run at. The largest is well past any real repository, so how the
// curve grows is visible rather than just one number.
//
const TREE_SIZES = [_]usize{ 100, 1000, 5000, 20000 };

//
// Bytes written into each generated file. Small on purpose: this measures the tool's own cost, and a
// large payload would only measure the filesystem's read throughput.
//
const FILE_SIZE_BYTES = 512;

//
// The slowest a single warm check is allowed to be, in milliseconds per file. A warm check is one
// `stat` and a map lookup, so anything approaching a millisecond per file means something is wrong.
//
// Nowhere near what a warm check actually costs. It is there to catch a change that makes the warm
// path read files again, which shows up as a jump towards the cold numbers, not to police small
// variations between machines.
//
const WARM_BUDGET_MS_PER_FILE = 0.15;

//
// One measured result, ready to be printed as a row.
//
const BenchmarkResult = struct {
    //
    // What was measured.
    //
    name: []const u8,

    //
    // How many files the tree held.
    //
    file_count: usize,

    //
    // How long the measured work took, in milliseconds.
    //
    milliseconds: f64,
};

//
// Every result gathered so far, printed as one table at the end.
//
var results: std.ArrayList(BenchmarkResult) = .empty;

//
// Where the benchmark's own output goes.
//
var out: wc.output.Output = undefined;

//
// Starts a measurement.
//
// The "awake" clock, which counts forwards while the machine is running and is not affected by the
// system clock being adjusted. Measuring against the wall clock would report a negative duration
// the moment NTP nudged it mid-run.
//
fn start(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

//
// Finishes a measurement, in milliseconds.
//
fn elapsedMs(io: std.Io, from: i96) f64 {
    const now = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    return @as(f64, @floatFromInt(now - from)) / std.time.ns_per_ms;
}

//
// Records a measurement and prints it as it happens, so a long run shows progress.
//
fn record(allocator: std.mem.Allocator, name: []const u8, file_count: usize, milliseconds: f64) !void {
    try results.append(allocator, .{ .name = name, .file_count = file_count, .milliseconds = milliseconds });
    out.line("  {s} at {d} files: {d:.1}ms", .{ name, file_count, milliseconds });
}

//
// Writes a tree of files spread across directories, laid out like a real project rather than one
// flat directory, and returns their relative paths.
//
fn buildFileTree(io: std.Io, allocator: std.mem.Allocator, root_dir: []const u8, file_count: usize) ![][]const u8 {
    const files_per_directory = 50;
    const directory_count = (file_count + files_per_directory - 1) / files_per_directory;

    var relative_paths: std.ArrayList([]const u8) = .empty;
    const content = try allocator.alloc(u8, FILE_SIZE_BYTES);
    @memset(content, 'x');

    var directory_index: usize = 0;
    while (directory_index < directory_count) : (directory_index += 1) {
        const directory = try std.fmt.allocPrint(allocator, "packages/package-{d}/src", .{directory_index});
        try wc.files.makeDirPath(io, try wc.files.joinPath(allocator, &.{ root_dir, directory }));

        var file_index: usize = 0;
        while (file_index < files_per_directory and relative_paths.items.len < file_count) : (file_index += 1) {
            const relative_path = try std.fmt.allocPrint(allocator, "{s}/file-{d}.ts", .{ directory, file_index });

            //
            // The path is written into the file, so no two files share content and the hashing has
            // as much to do as it would on a real tree.
            //
            const body = try std.mem.concat(allocator, u8, &.{ content, relative_path });
            try wc.files.writeFile(io, try wc.files.joinPath(allocator, &.{ root_dir, relative_path }), body);

            try relative_paths.append(allocator, relative_path);
        }
    }

    return relative_paths.toOwnedSlice(allocator);
}

//
// Measures the stages that decide how long a check takes: hashing with a cold cache, hashing with a
// warm one, and the changed-file diff.
//
fn benchmarkSize(io: std.Io, allocator: std.mem.Allocator, file_count: usize) !bool {
    var temporary = try wc.files.TemporaryDir.create(io);
    defer temporary.destroy();

    var within_budget = true;

    const relative_paths = try buildFileTree(io, allocator, temporary.path, file_count);

    var cold_cache: wc.file_hash.FileHashCache = .empty;
    var at = start(io);
    _ = try wc.file_hash.hashFiles(io, allocator, temporary.path, relative_paths, &cold_cache);
    try record(allocator, "hash (cold, reads every file)", file_count, elapsedMs(io, at));

    at = start(io);
    var hashes = try wc.file_hash.hashFiles(io, allocator, temporary.path, relative_paths, &cold_cache);
    const warm_ms = elapsedMs(io, at);
    try record(allocator, "hash (warm, stat only)", file_count, warm_ms);

    const per_file_ms = warm_ms / @as(f64, @floatFromInt(file_count));
    if (per_file_ms > WARM_BUDGET_MS_PER_FILE) {
        out.line("  BUDGET EXCEEDED: warm hashing took {d:.4}ms per file, budget is {d}ms", .{ per_file_ms, WARM_BUDGET_MS_PER_FILE });
        within_budget = false;
    }

    var baseline = try wc.changed_files.toFileHashes(allocator, &hashes);

    at = start(io);
    std.mem.doNotOptimizeAway(try wc.changed_files.diffFileHashes(allocator, &hashes, &baseline));
    try record(allocator, "diff files (nothing changed)", file_count, elapsedMs(io, at));

    var one_changed = try hashes.clone(allocator);
    try one_changed.put(allocator, relative_paths[0], "changed");

    at = start(io);
    std.mem.doNotOptimizeAway(try wc.changed_files.diffFileHashes(allocator, &one_changed, &baseline));
    try record(allocator, "diff files (one changed)", file_count, elapsedMs(io, at));

    return within_budget;
}

//
// Every distinct stage name, in the order they were first measured.
//
fn stageNames(allocator: std.mem.Allocator) ![][]const u8 {
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (results.items) |result| {
        try names.put(allocator, result.name, {});
    }
    return allocator.dupe([]const u8, names.keys());
}

//
// The measurement for one stage at one size, or null when there is none.
//
fn measurementFor(name: []const u8, file_count: usize) ?f64 {
    for (results.items) |result| {
        if (result.file_count == file_count and std.mem.eql(u8, result.name, name)) {
            return result.milliseconds;
        }
    }
    return null;
}

//
// Prints every measurement as one markdown table, so the numbers can be pasted straight into the
// docs.
//
fn printTable(allocator: std.mem.Allocator) !void {
    const names = try stageNames(allocator);

    out.blank();
    try printHeader();
    for (names) |name| {
        out.writer.print("| {s} |", .{name}) catch {};
        for (TREE_SIZES) |size| {
            if (measurementFor(name, size)) |milliseconds| {
                out.writer.print(" {d:.1}ms |", .{milliseconds}) catch {};
            } else {
                out.writer.print("  |", .{}) catch {};
            }
        }
        out.blank();
    }

    out.blank();
    try printHeader();
    for (names) |name| {
        out.writer.print("| {s} (per file) |", .{name}) catch {};
        for (TREE_SIZES) |size| {
            if (measurementFor(name, size)) |milliseconds| {
                out.writer.print(" {d:.2}us |", .{milliseconds / @as(f64, @floatFromInt(size)) * 1000}) catch {};
            } else {
                out.writer.print("  |", .{}) catch {};
            }
        }
        out.blank();
    }
}

//
// Prints the two header rows a markdown table needs.
//
fn printHeader() !void {
    out.writer.print("| Stage |", .{}) catch {};
    for (TREE_SIZES) |size| {
        out.writer.print(" {d} files |", .{size}) catch {};
    }
    out.blank();

    out.writer.print("| --- |", .{}) catch {};
    for (TREE_SIZES) |_| {
        out.writer.print(" --- |", .{}) catch {};
    }
    out.blank();
}

//
// Runs every benchmark at every size and exits non-zero if any of them blew its budget.
//
pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();

    var buffer: [64 * 1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &buffer);
    out = .{ .writer = &stdout_file.interface };

    out.line("what-changed performance benchmarks", .{});
    out.line("File size: {d} bytes. Warm budget: {d}ms per file.", .{ FILE_SIZE_BYTES, WARM_BUDGET_MS_PER_FILE });
    out.blank();

    var all_within_budget = true;
    for (TREE_SIZES) |file_count| {
        out.line("{d} files:", .{file_count});
        const within_budget = try benchmarkSize(init.io, allocator, file_count);
        all_within_budget = all_within_budget and within_budget;
        out.blank();
    }

    try printTable(allocator);

    out.blank();
    if (!all_within_budget) {
        out.line("FAIL: at least one stage exceeded its budget.", .{});
        stdout_file.interface.flush() catch {};
        return 1;
    }
    out.line("PASS: every stage within budget.", .{});

    stdout_file.interface.flush() catch {};
    return 0;
}

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

    const paths = try buildFileTree(io, allocator, temporary.path, 120);

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

    const paths = try buildFileTree(io, allocator, temporary.path, 3);

    var cache: wc.file_hash.FileHashCache = .empty;
    var hashes = try wc.file_hash.hashFiles(io, allocator, temporary.path, paths, &cache);

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

    const paths = try buildFileTree(io, allocator, temporary.path, 1);
    const stat = try wc.files.statFile(io, try wc.files.joinPath(allocator, &.{ temporary.path, paths[0] }));

    try testing.expectEqual(@as(u64, FILE_SIZE_BYTES + paths[0].len), stat.size);
}

test "elapsedMs measures forwards" {
    var test_io = wc.files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    const at = start(io);
    wc.files.sleepMs(io, 1);
    try testing.expect(elapsedMs(io, at) >= 1.0);
}

test "measurementFor finds a recorded result and reports a missing one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    results = .empty;
    try results.append(arena.allocator(), .{ .name = "hash", .file_count = 100, .milliseconds = 2.5 });

    try testing.expectEqual(@as(f64, 2.5), measurementFor("hash", 100).?);
    try testing.expect(measurementFor("hash", 1000) == null);
    try testing.expect(measurementFor("other", 100) == null);

    results = .empty;
}

test "stageNames lists each stage once, in the order first measured" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    results = .empty;
    try results.append(allocator, .{ .name = "cold", .file_count = 100, .milliseconds = 1 });
    try results.append(allocator, .{ .name = "warm", .file_count = 100, .milliseconds = 1 });
    try results.append(allocator, .{ .name = "cold", .file_count = 1000, .milliseconds = 1 });

    const names = try stageNames(allocator);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("cold", names[0]);
    try testing.expectEqualStrings("warm", names[1]);

    results = .empty;
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
    results = .empty;
    var captured = std.Io.Writer.Allocating.init(allocator);
    out = .{ .writer = &captured.writer };

    try testing.expect(try benchmarkSize(io, allocator, 60));
    try testing.expectEqual(@as(usize, 4), results.items.len);

    for (results.items) |result| {
        try testing.expectEqual(@as(usize, 60), result.file_count);
        try testing.expect(result.milliseconds >= 0);
    }

    //
    // The warm run must be faster than the cold one. That is the whole claim the cache makes, and a
    // change that broke it would otherwise show up only as a slow build nobody traced back here.
    //
    try testing.expect(results.items[1].milliseconds < results.items[0].milliseconds);

    results = .empty;
}
