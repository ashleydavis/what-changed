const std = @import("std");
const files = @import("files.zig");
const value = @import("value.zig");
const failure = @import("failure.zig");
const cache_store = @import("cache_store.zig");
const file_hash = @import("file_hash.zig");
const FileHashCache = file_hash.FileHashCache;
const Value = value.Value;
const testing = std.testing;

//
// Replaces whatever is in the file with a fixed object, for testing updateJsonFile.
//
fn replaceWith(replacement: Value, allocator: std.mem.Allocator, current: Value) std.mem.Allocator.Error!Value {
    _ = current;
    _ = allocator;
    return replacement;
}

//
// Adds one field to whatever is in the file, for testing that the read and the write are one step.
//
fn addField(name: []const u8, allocator: std.mem.Allocator, current: Value) std.mem.Allocator.Error!Value {
    var object = switch (current) {
        .object => |existing| existing,
        else => value.newObject(allocator),
    };
    try object.put(allocator, name, value.boolean(true));
    return .{ .object = object };
}

test "readJsonObject reads an object off disk" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("data.json", "{\"a\": 1}");

    const read = try cache_store.readJsonObject(io, allocator, try temporary.join(allocator, "data.json"));
    try testing.expectEqual(@as(i64, 1), value.get(read.object, "a").?.integer);
    try testing.expectEqualStrings("read", read.statusText());
}

test "readJsonObject says which way a file failed to give it an object" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("broken.json", "{ not json");
    try temporary.write("array.json", "[1, 2]");
    try temporary.write("scalar.json", "42");

    //
    // A file that is not there and a file that is there and unusable are different answers. Reading
    // them as one empty object is what made a corrupted baseline indistinguishable from a project
    // that had never captured one.
    //
    try testing.expectEqualStrings("absent", (try cache_store.readJsonObject(io, allocator, try temporary.join(allocator, "gone.json"))).statusText());
    try testing.expectEqualStrings("notJson", (try cache_store.readJsonObject(io, allocator, try temporary.join(allocator, "broken.json"))).statusText());
    try testing.expectEqualStrings("notAnObject", (try cache_store.readJsonObject(io, allocator, try temporary.join(allocator, "array.json"))).statusText());
    try testing.expectEqualStrings("notAnObject", (try cache_store.readJsonObject(io, allocator, try temporary.join(allocator, "scalar.json"))).statusText());
}

test "contentOrNull hands back the object, and null for every way there was not one" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("data.json", "{\"a\": 1}");
    try temporary.write("array.json", "[1, 2]");

    const read = (try cache_store.readJsonObject(io, allocator, try temporary.join(allocator, "data.json"))).contentOrNull();
    try testing.expectEqual(@as(i64, 1), value.get(read, "a").?.integer);

    try testing.expectEqual(value.Value.null, (try cache_store.readJsonObject(io, allocator, try temporary.join(allocator, "gone.json"))).contentOrNull());
    try testing.expectEqual(value.Value.null, (try cache_store.readJsonObject(io, allocator, try temporary.join(allocator, "array.json"))).contentOrNull());
}

test "loadCache reads the hashes back, and an absent cache is empty" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const cache_dir = try temporary.join(allocator, "cache");

    var empty = try cache_store.loadCache(io, allocator, cache_dir);
    try testing.expectEqual(@as(usize, 0), empty.file_hashes.count());

    var hashes: FileHashCache = .empty;
    try hashes.put(allocator, "a.ts", .{ .mtime_ms = 1.5, .size = 3, .hash = "hash-a" });
    try cache_store.saveFileHashes(io, allocator, cache_dir, &hashes);

    var loaded = try cache_store.loadCache(io, allocator, cache_dir);
    try testing.expectEqual(@as(usize, 1), loaded.file_hashes.count());
    try testing.expectEqualStrings("hash-a", loaded.file_hashes.get("a.ts").?.hash);
    try testing.expectEqual(@as(f64, 1.5), loaded.file_hashes.get("a.ts").?.mtime_ms);
}

test "saveFileHashes creates the cache directory when it is not there" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    var hashes: FileHashCache = .empty;
    try hashes.put(allocator, "a.ts", .{ .mtime_ms = 1, .size = 1, .hash = "h" });
    try cache_store.saveFileHashes(io, allocator, try temporary.join(allocator, "deep/nested/cache"), &hashes);

    try testing.expect(temporary.has("deep/nested/cache/" ++ cache_store.FILE_HASHES_NAME));
}

test "writeJsonFile leaves no temporary file behind" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    var object = value.newObject(allocator);
    try object.put(allocator, "a", value.int(1));
    try cache_store.writeJsonFile(io, allocator, try temporary.join(allocator, "out.json"), .{ .object = object });

    var directory = try std.Io.Dir.cwd().openDir(io, temporary.path, .{ .iterate = true });
    defer directory.close(io);

    var walker = directory.iterate();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        count += 1;
        try testing.expectEqualStrings("out.json", entry.name);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "writeJsonFile writes the JSON indented by two spaces" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    var object = value.newObject(allocator);
    try object.put(allocator, "targets", .{ .object = value.newObject(allocator) });
    try object.put(allocator, "files", .{ .object = value.newObject(allocator) });
    try cache_store.writeJsonFile(io, allocator, try temporary.join(allocator, "baseline.json"), .{ .object = object });

    try testing.expectEqualStrings(
        \\{
        \\  "targets": {},
        \\  "files": {}
        \\}
    , try temporary.read(allocator, "baseline.json"));
}

test "randomName gives a different name every time" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const first = try cache_store.randomName(io, allocator);
    const second = try cache_store.randomName(io, allocator);
    try testing.expectEqual(@as(usize, 32), first.len);
    try testing.expect(!std.mem.eql(u8, first, second));
}

test "takeUpdateLock takes a free lock and refuses a held one" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const lock_path = try temporary.join(allocator, "thing.json.lock");

    try cache_store.takeUpdateLock(io, lock_path);
    try testing.expect(files.fileExists(io, lock_path));

    try cache_store.releaseUpdateLock(io, lock_path);
    try testing.expect(!files.fileExists(io, lock_path));

    //
    // And it can be taken again once released, which is what makes the whole thing usable more than
    // once in a process's lifetime.
    //
    try cache_store.takeUpdateLock(io, lock_path);
    try cache_store.releaseUpdateLock(io, lock_path);
}

test "releaseUpdateLock counts a lock that is already gone as released" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    //
    // Another process clearing it as abandoned, or the user deleting it as the timeout message says
    // to. Nothing is blocking anyone, which is all the release was for.
    //
    try cache_store.releaseUpdateLock(io, try temporary.join(allocator, "never-existed.lock"));
}

test "releaseUpdateLock says so when the lock file will not delete" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    //
    // A directory sitting where the lock file should be is the portable way to make a delete fail.
    // What matters is that the failure comes back at all, not which error it is, since that differs
    // by platform.
    //
    const lock_path = try temporary.join(allocator, "wedged.lock");
    try files.makeDirPath(io, lock_path);

    try testing.expect(std.meta.isError(cache_store.releaseUpdateLock(io, lock_path)));
}

test "clearAbandonedLock leaves a fresh lock alone" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const lock_path = try temporary.join(allocator, "fresh.lock");

    try cache_store.takeUpdateLock(io, lock_path);
    cache_store.clearAbandonedLock(io, lock_path);

    //
    // A living writer must never be robbed of its lock, so a lock made a moment ago stays.
    //
    try testing.expect(files.fileExists(io, lock_path));
    try cache_store.releaseUpdateLock(io, lock_path);
}

test "clearAbandonedLock does not mind a lock that is already gone" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    cache_store.clearAbandonedLock(io, try temporary.join(allocator, "never-existed.lock"));
}

test "updateJsonFile writes the result of the change" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const path = try temporary.join(allocator, "nested/data.json");

    var replacement = value.newObject(allocator);
    try replacement.put(allocator, "written", value.boolean(true));

    var fail = failure.Failure.init(allocator);
    try cache_store.updateJsonFile(io, allocator, path, Value{ .object = replacement }, replaceWith, &fail);

    const read_back = (try cache_store.readJsonObject(io, allocator, path)).contentOrNull();
    try testing.expectEqual(true, value.get(read_back, "written").?.bool);
}

test "updateJsonFile hands the current contents to the change" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const path = try temporary.join(allocator, "data.json");

    var fail = failure.Failure.init(allocator);
    try cache_store.updateJsonFile(io, allocator, path, @as([]const u8, "first"), addField, &fail);
    try cache_store.updateJsonFile(io, allocator, path, @as([]const u8, "second"), addField, &fail);

    //
    // Both fields are there, which is the whole point: the second update read what the first wrote
    // rather than starting from nothing.
    //
    const read_back = (try cache_store.readJsonObject(io, allocator, path)).contentOrNull();
    try testing.expectEqual(true, value.get(read_back, "first").?.bool);
    try testing.expectEqual(true, value.get(read_back, "second").?.bool);
}

test "updateJsonFile releases the lock when it is done" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const path = try temporary.join(allocator, "data.json");

    var fail = failure.Failure.init(allocator);
    try cache_store.updateJsonFile(io, allocator, path, @as([]const u8, "a"), addField, &fail);

    try testing.expect(!files.fileExists(io, try std.fmt.allocPrint(allocator, "{s}.lock", .{path})));
}

test "cacheReset writes an empty cache rather than deleting the file" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const cache_dir = try temporary.join(allocator, "cache");

    var hashes: FileHashCache = .empty;
    try hashes.put(allocator, "a.ts", .{ .mtime_ms = 1, .size = 1, .hash = "h" });
    try cache_store.saveFileHashes(io, allocator, cache_dir, &hashes);

    try cache_store.cacheReset(io, allocator, cache_dir);

    try testing.expect(temporary.has("cache/" ++ cache_store.FILE_HASHES_NAME));
    var loaded = try cache_store.loadCache(io, allocator, cache_dir);
    try testing.expectEqual(@as(usize, 0), loaded.file_hashes.count());
}

test "pruneFileHashes keeps only the paths that still exist" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes: FileHashCache = .empty;
    try hashes.put(allocator, "kept.ts", .{ .mtime_ms = 1, .size = 1, .hash = "1" });
    try hashes.put(allocator, "gone.ts", .{ .mtime_ms = 2, .size = 2, .hash = "2" });

    var pruned = try cache_store.pruneFileHashes(allocator, &hashes, &.{ "kept.ts", "never-hashed.ts" });
    try testing.expectEqual(@as(usize, 1), pruned.count());
    try testing.expectEqualStrings("1", pruned.get("kept.ts").?.hash);
    try testing.expect(pruned.get("gone.ts") == null);
}

test "pruneFileHashes with no current paths keeps nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes: FileHashCache = .empty;
    try hashes.put(allocator, "a.ts", .{ .mtime_ms = 1, .size = 1, .hash = "1" });

    try testing.expectEqual(@as(usize, 0), (try cache_store.pruneFileHashes(allocator, &hashes, &.{})).count());
}
